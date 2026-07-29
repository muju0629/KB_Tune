"""웹 검색으로 금액 찾기 — 공개 통계에도 개인 이력에도 없는 일정용.

여행처럼 공표 통계에 대응 항목이 없는 일정이 있다. 그런 건 규칙에 박아 둔 20,000원
대신 웹에서 찾아본다. 다만 이 통로는 질의가 모델 제공자를 거쳐 검색 엔진까지 나가므로
**사용자가 켰을 때만** 부른다.

들어오는 건 검색어 한 줄뿐이다(SearchRequest). 앱이 코드에 정의된 말로만 조립해서
보내므로 일정 제목 원문은 여기 도달하지 않는다.

검색 결과의 금액은 엔진이 다시 검증한다 — 범위를 벗어나거나 근거 문서가 없으면 버린다.
"""
from __future__ import annotations

import logging
import math

from .. import config
from ..models import SearchCostResult

log = logging.getLogger(__name__)

# 국내 소비 일정 한 건에 이보다 크거나 작은 금액이 나오면 질의를 잘못 이해한 것으로 본다.
MIN_AMOUNT = 1_000
MAX_AMOUNT = 5_000_000

UNAVAILABLE = SearchCostResult(
    amount=None, low=None, high=None, method="unavailable",
    basis="지금은 웹에서 찾지 못했어요. 금액을 직접 넣어 주세요.",
)

PROMPT = (
    "아래 검색어로 웹을 찾아 한국 기준 1인당 평균 비용을 알려줘.\n"
    "여러 출처의 값이 다르면 대표값 하나와 흔한 범위를 잡아줘.\n"
    "찾지 못하면 amount 를 null 로 둬. 추측해서 채우지 마.\n"
    'JSON만 출력: {"amount":정수원,"low":정수원,"high":정수원,"basis":"한 문장 근거"}\n\n'
    "검색어: {query}"
)


def search_cost(query: str) -> SearchCostResult:
    """검색어 → 1인 기준 금액. 실패하면 method='unavailable'."""
    backend = config.llm_backend()
    if backend in ("offline", "local"):
        # 로컬 모델에는 웹 검색 도구가 없다. 켜져 있어도 이 기능은 못 한다.
        return UNAVAILABLE

    try:
        obj, sources = _search(backend, query)
    except Exception as exc:
        # 조용히 삼키면 "웹에서 못 찾았어요"만 보이고 원인을 알 수 없다.
        # 검색어는 코드가 만든 말뿐이라 로그에 남겨도 개인 정보가 아니다.
        log.warning("검색 실패 (%s): %s — %r", backend, query, exc)
        return UNAVAILABLE

    if not isinstance(obj, dict):
        return UNAVAILABLE

    amount = _valid_won(obj.get("amount"))
    if amount is None:
        return UNAVAILABLE

    low = _valid_won(obj.get("low")) or int(amount * 0.6)
    high = _valid_won(obj.get("high")) or int(amount * 1.6)
    low, high = min(low, amount), max(high, amount)

    basis = str(obj.get("basis") or "").strip()[:200] or "웹에서 찾은 평균 비용이에요."
    if not sources:
        # 근거 문서를 못 대면 모델이 지어낸 숫자와 구분할 수 없다.
        log.warning("검색은 됐지만 출처가 없어 버림: %s (금액 %s)", query, amount)
        return UNAVAILABLE

    return SearchCostResult(amount=amount, low=low, high=high, method="web",
                        basis=basis, sources=sources[:3])


def _valid_won(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value):
        return None
    amount = int(value)
    return amount if MIN_AMOUNT <= amount <= MAX_AMOUNT else None


def _search(backend: str, query: str) -> tuple[object, list[str]]:
    """(파싱한 JSON, 출처 목록). 제공자마다 웹 검색 도구 이름이 달라 여기서 흡수한다."""
    from .complete import _first_json_object

    prompt = PROMPT.replace("{query}", query)

    if backend == "claude":
        import anthropic
        r = anthropic.Anthropic().messages.create(
            model=config.CLAUDE_MODEL, max_tokens=1_000,
            tools=[{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}],
            messages=[{"role": "user", "content": prompt}],
        )
        text = "".join(b.text for b in r.content if b.type == "text")
        sources = [
            c.get("title") or c.get("url", "")
            for b in r.content if b.type == "text"
            for c in (getattr(b, "citations", None) or [])
            if isinstance(c, dict)
        ]
        return _first_json_object(text), [s for s in sources if s]

    # openai — Responses API 의 web_search 도구. 호출·파싱은 websearch 와 같은 것을 쓴다.
    from .. import websearch
    payload = websearch.responses_call(prompt, timeout=45)
    if payload is None:
        raise RuntimeError("Responses API 호출 실패")
    return _first_json_object(websearch.answer_of(payload)), websearch.sources_of(payload)
