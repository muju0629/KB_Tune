"""AI 기능 ① — 일정 제목 → 예상 지출 추정.

제품 핵심 루프("일정 추가할 때마다 예상 지출 계산")의 실제 구현.
1차: 키워드 규칙으로 카테고리 판정 → 사용자 과거 '건당 평균'으로 개인화
2차(선택): LLM이 세상 지식으로 카테고리·금액 추정
어느 경우든 **엔진이 과거 분포(low~high)로 클램프**해서 말도 안 되는 값을 차단한다.
"""
from __future__ import annotations

from ..models import EstimateResult, Transaction

# 카테고리 판정 키워드 + 과거 데이터가 없을 때의 기본 금액(원)
EVENT_RULES: list[tuple[str, list[str], int]] = [
    ("경조사", ["결혼", "축의", "돌잔치", "장례", "부의", "청첩"], 150_000),
    ("여행", ["여행", "MT", "엠티", "워크샵", "워크숍", "숙박", "펜션"], 200_000),
    ("술·모임", ["회식", "술", "2차", "뒤풀이", "동아리", "모임", "파티", "생일"], 30_000),
    ("여가", ["영화", "공연", "전시", "콘서트", "페스티벌", "노래방", "볼링"], 15_000),
    ("카페", ["카페", "커피", "스터디", "팀플", "과제"], 8_000),
    ("외식", ["점심", "저녁", "식사", "밥", "맛집", "회", "고기", "런치", "디너"], 15_000),
    ("쇼핑", ["쇼핑", "구매", "교재", "옷", "선물"], 40_000),
]

CLAMP_MULTIPLIER = 2.5  # 과거 최대치의 이 배수를 넘는 추정은 신뢰하지 않음


def _history_stats(txns: list[Transaction], category: str) -> tuple[int, int, int, int]:
    """(건당 평균, 하한, 상한, 건수) — 과거 같은 카테고리 지출 분포."""
    amounts = [t.amount for t in txns if t.category == category]
    if not amounts:
        return 0, 0, 0, 0
    avg = sum(amounts) // len(amounts)
    return avg, min(amounts), max(amounts), len(amounts)


def match_rule(title: str) -> tuple[str | None, int]:
    t = title.replace(" ", "")
    for cat, keys, default in EVENT_RULES:
        if any(k in t for k in keys):
            return cat, default
    return None, 0


def estimate_event_cost(title: str, txns: list[Transaction], use_llm: bool = False) -> EstimateResult:
    cat, default_amount = match_rule(title)
    method = "rule"
    llm_raw: int | None = None

    # 규칙이 못 잡으면 LLM에게 물어본다(선택). 실패하면 '기타'.
    if cat is None:
        if use_llm:
            guess = _llm_estimate(title)
            if guess:
                cat, llm_raw = guess["category"], int(guess["amount"])
                default_amount = llm_raw
                method = "llm"
        if cat is None:
            cat, default_amount, method = "기타", 20_000, "fallback"

    avg, lo, hi, n = _history_stats(txns, cat)

    if n >= 2:
        # 과거 이력이 있으면 개인화: 건당 평균을 기준값으로
        amount = avg if method != "llm" else int((avg + default_amount) / 2)
        low, high = lo, hi
        basis = f"지난 3개월 ‘{cat}’ {n}건 평균 {avg:,}원 기준이에요."
        confidence = 0.85 if method == "rule" else 0.7
    else:
        amount = default_amount
        low, high = int(amount * 0.6), int(amount * 1.6)
        basis = f"과거 이력이 적어 일반적인 ‘{cat}’ 지출로 잡았어요."
        confidence = 0.5

    # 엔진 최종 검증: 과거 최대치의 CLAMP_MULTIPLIER 배를 넘으면 잘라낸다
    if hi > 0:
        ceiling = int(hi * CLAMP_MULTIPLIER)
        if amount > ceiling:
            amount = ceiling
            basis += " (과거 범위를 크게 벗어나 상한으로 보정했어요)"
            confidence = min(confidence, 0.5)

    amount = max(0, int(round(amount / 500)) * 500)  # 500원 단위 정리

    return EstimateResult(
        title=title, category=cat, amount=amount,
        low=low or int(amount * 0.6), high=high or int(amount * 1.6),
        confidence=round(confidence, 2), basis=basis, method=method, llm_raw=llm_raw,
    )


def _llm_estimate(title: str) -> dict | None:
    """세상 지식이 필요한 제목만 LLM에. 반환 {category, amount}."""
    from .. import config
    if config.llm_backend() != "claude":
        return None
    try:
        import json

        import anthropic
        from .categorize import CATEGORIES
        client = anthropic.Anthropic()
        prompt = (
            f"한국 대학생 기준으로 아래 일정에 보통 얼마를 쓰는지 추정해줘.\n"
            f"카테고리는 [{', '.join(CATEGORIES)}] 중 하나.\n"
            f'JSON만 출력: {{"category":"...","amount":정수원}}\n\n일정: {title}'
        )
        r = client.messages.create(model=config.CLAUDE_MODEL, max_tokens=200,
                                   messages=[{"role": "user", "content": prompt}])
        text = "".join(b.text for b in r.content if b.type == "text")
        s, e = text.find("{"), text.rfind("}")
        obj = json.loads(text[s:e + 1])
        from .categorize import CATEGORIES as C
        if obj.get("category") in C and isinstance(obj.get("amount"), (int, float)):
            return {"category": obj["category"], "amount": int(obj["amount"])}
    except Exception:
        return None
    return None
