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


def _client_key(request: Request) -> str:
    """한도를 세는 기준. 키가 있으면 키별, 없으면 IP별.

    프록시(Render 등) 뒤에서는 X-Forwarded-For 가 진짜 IP다. 다만 이 헤더는 위조할 수
    있어서, 프록시가 앞에 있다고 명시(KB_TUNE_TRUST_PROXY=1)할 때만 믿는다.
    그러지 않으면 헤더만 바꿔가며 한도를 무한정 우회할 수 있다.
    """
    key = request.headers.get("x-api-key")
    if key:
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
