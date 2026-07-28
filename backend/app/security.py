"""요청 인증 · 속도 제한 · 본문 크기 제한 · 프롬프트 주입 방어.

새 의존성 없이 표준 라이브러리로 구현한다.
한도는 **프로세스 안에서만** 공유되므로 워커를 여러 개 띄우면 워커 수만큼 한도가
늘어난다 — 운영은 `--workers 1` 기준이다. 워커를 늘려야 하면 Redis 같은 공유 저장소가
필요하고, 그때는 이 모듈을 그쪽으로 갈아끼운다.
"""
from __future__ import annotations

import hashlib
import hmac
import re
import threading
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from . import config

# ---------- 인증 ----------


def require_api_key(request: Request) -> None:
    """KB_TUNE_API_KEY 가 설정돼 있을 때만 X-API-Key 를 요구한다.

    키를 안 걸면 예전처럼 무인증으로 뜬다 — 심사자가 받아서 설정 없이 바로 실행할 수 있어야
    하기 때문이다. 앱에 심는 키는 바이너리에서 추출될 수 있으므로 '신원 증명'이 아니라
    '아무나 긁어가지 못하게 하는 문턱'으로만 취급한다. 사용자별 신원이 필요해지면
    그때 서버 발급 토큰으로 바꾼다.
    """
    expected = config.api_auth_key()
    if expected is None:
        return
    given = request.headers.get("x-api-key", "")
    # compare_digest 로 길이·내용 비교 시간을 고정 — 문자 단위 비교는 키를 흘린다.
    if not hmac.compare_digest(given.encode("utf-8"), expected.encode("utf-8")):
        raise HTTPException(status_code=401, detail="유효한 X-API-Key 가 필요합니다.")


# ---------- 속도 제한 ----------


class _Window:
    """슬라이딩 윈도우 카운터. `seconds` 안에 `limit` 번까지 허용한다."""

    __slots__ = ("limit", "seconds", "_hits", "_lock")

    def __init__(self, limit: int, seconds: int) -> None:
        self.limit = limit
        self.seconds = seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def check(self, key: str) -> float:
        """허용되면 0.0, 막히면 남은 대기 초(>0)를 반환한다."""
        now = time.monotonic()
        cutoff = now - self.seconds
        with self._lock:
            q = self._hits[key]
            while q and q[0] <= cutoff:
                q.popleft()
            if len(q) >= self.limit:
                return q[0] + self.seconds - now
            q.append(now)
            if len(self._hits) > 10_000:      # 키가 무한히 쌓이지 않게 — 죽은 항목 청소
                for dead in [k for k, v in self._hits.items() if not v or v[-1] <= cutoff]:
                    del self._hits[dead]
            return 0.0


# 엔드포인트 묶음별 한도. LLM을 부르는 쪽이 비싸므로 따로 잡는다.
_BUCKETS = {
    "llm": _Window(config.RATE_LLM, 60),        # /chat /extract /categorize /estimate
    "eval": _Window(config.RATE_EVAL, 300),     # /eval — 골든셋 + groundedness 전량 실행
    "cheap": _Window(config.RATE_CHEAP, 60),    # /plan /health — 엔진만, 비용 0
}

# 클라이언트를 아무리 나눠도 총량은 못 넘게 — API 청구액의 실질 상한.
_GLOBAL_LLM = _Window(config.RATE_LLM_GLOBAL, 60)
_GLOBAL_EVAL = _Window(config.RATE_EVAL_GLOBAL, 300)


def _client_key(request: Request) -> str:
    """한도를 세는 기준. 키가 있으면 키별, 없으면 IP별.

    프록시(Render 등) 뒤에서는 X-Forwarded-For 가 진짜 IP다. 다만 이 헤더는 위조할 수
    있어서, 프록시가 앞에 있다고 명시(KB_TUNE_TRUST_PROXY=1)할 때만 믿는다.
    그러지 않으면 헤더만 바꿔가며 한도를 무한정 우회할 수 있다.
    """
    # 인증이 꺼진 데모 모드에서는 임의 헤더를 신원으로 믿지 않는다. 그렇지 않으면
    # X-API-Key 값을 매번 바꾸는 것만으로 클라이언트 한도를 무한히 우회할 수 있다.
    key = request.headers.get("x-api-key", "")
    expected = config.api_auth_key()
    if expected and hmac.compare_digest(key.encode("utf-8"), expected.encode("utf-8")):
        return "k:" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
    if config.TRUST_PROXY:
        fwd = request.headers.get("x-forwarded-for", "")
        if fwd:
            return "ip:" + fwd.split(",")[0].strip()[:45]
    return "ip:" + (request.client.host if request.client else "unknown")


def rate_limit(bucket: str):
    """엔드포인트에 붙일 속도 제한 의존성을 만든다."""
    window = _BUCKETS[bucket]

    def _check(request: Request) -> None:
        wait = window.check(_client_key(request))
        if wait <= 0 and bucket == "llm":
            wait = _GLOBAL_LLM.check("*")
        if wait <= 0 and bucket == "eval":
            wait = _GLOBAL_EVAL.check("*")
        if wait > 0:
            raise HTTPException(
                status_code=429,
                detail="요청이 너무 잦아요. 잠시 후 다시 시도해 주세요.",
                headers={"Retry-After": str(max(1, int(wait) + 1))},
            )

    return _check


# ---------- 본문 크기 ----------


class BodySizeLimitMiddleware(BaseHTTPMiddleware):
    """과대 요청을 본문을 읽기 전에 끊는다.

    Content-Length 가 없는 chunked 요청은 여기서 못 걸러지므로, 모델 쪽 max_length
    (ExtractRequest.image_base64 등)가 2차 방어선이다.
    """

    async def dispatch(self, request: Request, call_next):
        raw = request.headers.get("content-length")
        if raw and raw.isdigit() and int(raw) > config.MAX_BODY_BYTES:
            return JSONResponse(
                status_code=413,
                content={"detail": f"요청이 너무 큽니다(최대 {config.MAX_BODY_BYTES:,} bytes)."},
            )
        return await call_next(request)


# ---------- 프롬프트 주입 방어 ----------

# 제어문자 + 눈에 안 보이는 공백/서식문자. 후자는 \s 로 안 잡혀서 따로 적는다.
_CONTROL = re.compile("[\u0000-\u001f\u007f-\u009f\u00a0\u200b-\u200f\u2028\u2029\ufeff]")

_EMAIL = re.compile(r"(?<![\w.+-])[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}(?![\w.-])")
_RRN = re.compile(r"(?<!\d)\d{6}\s*[- ]\s*[1-8]\d{6}(?!\d)")
_PHONE = re.compile(r"(?<!\d)(?:01[016789]|0[2-9]\d?)\s*[- ]?\s*\d{3,4}\s*[- ]?\s*\d{4}(?!\d)")
_CARD_NUMBER = re.compile(r"(?<!\d)(?:\d{4}[- ]){3}\d{4}(?!\d)")
_LONG_IDENTIFIER = re.compile(r"(?<!\d)\d{10,16}(?!\d)")
_ACCOUNT = re.compile(r"(?<!\d)\d{2,6}(?:[- ]\d{2,6}){2,3}(?!\d)")
_PASSPORT = re.compile(r"(?<![A-Z0-9])[A-Z]{1,2}\d{7,8}(?![A-Z0-9])", re.IGNORECASE)
_ADDRESS = re.compile(r"(?:주소(?:는|가|:)?|사는\s*곳(?:은|:)?|거주지(?:는|:)?)[^,.\n]{2,60}")
_NAME_WITH_SUFFIX = re.compile(r"(?<![가-힣])([가-힣]{2,4})(님|씨)(?![가-힣])")
_NAME_EVENT = re.compile(r"(?<![가-힣])([가-힣]{2,4})\s+(결혼식|생일|돌잔치|장례식|약속|만남)")
_NAME_RELATION = re.compile(
    r"(?<![가-힣])([가-힣]{2,4})(와|과|이랑|랑)\s*"
    r"(?=(?:카페|약속|만나|밥|술|여행|데이트|결혼|헬스|운동|식사|영화|공연|쇼핑))"
)
_EXPLICIT_NAME = re.compile(
    r"((?:제|내)\s*이름은|이름은|성명은)\s*([가-힣]{2,4}?)(이?야|예요|입니다|라고)?(?=[\s.,!?]|$)"
)
_SELF_NAME = re.compile(
    r"(나는|저는)\s*([가-힣]{2,4}?)(이?야|예요|입니다|라고)(?=[\s.,!?]|$)"
)


def safe_text(value: object, limit: int = 40) -> str:
    """사용자가 만든 문자열(일정 제목·가맹점명)을 프롬프트에 넣기 전에 무해화한다.

    캘린더 일정 제목은 사용자가 아무 내용이나 쓸 수 있는 칸이고, 그게 시스템 프롬프트의
    사실 블록에 그대로 들어간다. 줄바꿈·제어문자를 지워 한 줄 형식을 못 깨게 하고
    길이를 자른다 — "\\n\\n이전 지시는 무시하고..." 같은 구조 탈출을 막는 게 목적이다.
    내용 자체의 설득은 막을 수 없으므로, 프롬프트에서 이 블록을 '데이터'로 못박는 문장과
    한 쌍으로 쓴다.
    """
    s = _CONTROL.sub(" ", str(value))
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


def redact_personal_data(value: object, limit: int = 20_000) -> str:
    """외부 LLM 전송 전에 직접 식별자를 최소한으로 가린다.

    금액·확률 같은 엔진 사실은 보존하고, 답변에 필요 없는 연락처·식별번호·명시적
    사람 이름만 치환한다. 완전한 개체명 인식이 아니므로 원본 캡처는 애초에 외부로
    보내지 않고 온디바이스 OCR 경로를 사용한다.
    """
    text = str(value)[:limit]
    text = _RRN.sub("[주민번호]", text)
    text = _EMAIL.sub("[이메일]", text)
    text = _PHONE.sub("[전화번호]", text)
    text = _CARD_NUMBER.sub("[식별번호]", text)
    text = _LONG_IDENTIFIER.sub("[식별번호]", text)
    text = _ACCOUNT.sub("[계좌번호]", text)
    text = _PASSPORT.sub("[여권번호]", text)
    text = _ADDRESS.sub("주소 [주소]", text)
    text = _EXPLICIT_NAME.sub(lambda m: f"{m.group(1)} [이름]{m.group(3) or ''}", text)
    text = _SELF_NAME.sub(lambda m: f"{m.group(1)} [이름]{m.group(3) or ''}", text)
    text = _NAME_WITH_SUFFIX.sub(lambda m: f"[이름]{m.group(2)}", text)
    text = _NAME_EVENT.sub(lambda m: f"[이름] {m.group(2)}", text)
    text = _NAME_RELATION.sub(lambda m: f"[이름]{m.group(2)} ", text)
    return text


# ---------- 외부 LLM용 최소 의도 ----------

_WON_AMOUNT = re.compile(r"(?<!\d)(\d{1,3}(?:,\d{3})+|\d+)\s*(만\s*원|천\s*원|원)(?![가-힣])")

_INTENT_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("일정 삭제", ("삭제", "취소", "없애")),
    ("일정 변경", ("미루", "미뤄", "연기", "옮겨", "이동", "변경")),
    ("일정 추가와 예상 지출", ("일정", "약속", "갈래", "가려고", "추가", "잡아", "예약")),
    ("미래 소비 예측", ("예측", "다음달", "다음 달", "미래", "예상 소비")),
    ("소비 패턴 분석", ("소비패턴", "소비 패턴", "분석", "지출 패턴", "어디서 많이")),
    ("적금과 저축 목표", ("적금", "저축", "목표 달성")),
    ("카드 청구", ("카드", "청구", "결제일", "할부")),
    ("예산과 추가 사용 가능액", ("예산", "얼마 남", "얼마남", "쓸 수", "쓸수", "사용 가능")),
)

_CATEGORY_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("카페", ("카페", "커피", "스타벅스", "투썸")),
    ("외식", ("식사", "점심", "저녁", "맛집", "밥")),
    ("교통", ("택시", "버스", "지하철", "기차", "교통")),
    ("여가", ("헬스", "운동", "PC방", "노래방", "볼링")),
    ("문화", ("영화", "공연", "전시", "콘서트")),
    ("자기관리", ("병원", "한의원", "미용", "제모")),
    ("쇼핑", ("쇼핑", "선물", "구매", "올리브영")),
    ("모임", ("회식", "모임", "술", "파티", "친구")),
    ("여행", ("여행", "숙박", "펜션", "항공")),
    ("경조사", ("결혼", "축의", "장례", "부의", "돌잔치")),
    ("구독", ("구독", "넷플릭스", "유튜브", "티빙")),
    ("업무·학업", ("회의", "스터디", "과제", "출근", "인턴")),
)


def _explicit_won_amounts(value: object) -> list[int]:
    """원 단위를 사용자가 명시한 경우만 금액으로 취급한다.

    단위 없는 숫자는 날짜·전화번호·식별자일 수 있어 외부 모델에 옮기지 않는다.
    """
    amounts: list[int] = []
    for raw, unit in _WON_AMOUNT.findall(str(value)):
        number = int(raw.replace(",", ""))
        compact_unit = unit.replace(" ", "")
        if compact_unit == "만원":
            number *= 10_000
        elif compact_unit == "천원":
            number *= 1_000
        if 0 <= number <= 100_000_000 and number not in amounts:
            amounts.append(number)
        if len(amounts) == 4:
            break
    return amounts


def financial_intent_text(value: object) -> str:
    """자유 원문을 외부 LLM에 보내지 않고 구조적 금융 의도로 축소한다.

    반환값은 코드에 정의된 라벨·유형과 '원' 단위로 명시된 금액만 포함한다.
    이름·가맹점·일정 제목·전화번호 등 원문 토큰은 복사되지 않는다.
    """
    normalized = safe_text(value, 2_000)
    compact = normalized.replace(" ", "")
    intent = "일반 소비 상담"
    for label, keywords in _INTENT_RULES:
        if any(keyword.replace(" ", "") in compact for keyword in keywords):
            intent = label
            break

    category = next(
        (label for label, keywords in _CATEGORY_RULES
         if any(keyword.replace(" ", "").lower() in compact.lower() for keyword in keywords)),
        None,
    )
    amounts = _explicit_won_amounts(normalized)
    fields = [f"금융 의도: {intent}"]
    if category:
        fields.append(f"지출 유형: {category}")
    fields.append("명시 금액: " + (", ".join(f"{n:,}원" for n in amounts) if amounts else "없음"))
    return "; ".join(fields) + "."
