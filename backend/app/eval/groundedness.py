"""Groundedness 검사 — LLM 응답의 숫자가 우리가 준 데이터에서 나온 것인지 검증.

허용 명단에 없는 금액/확률은 '지어낸 값'으로 본다. 다만 판정 결과를 쓰는 방식은
호출부가 정한다 — 응답 전체를 버릴 수도 있고(coach), 문제 숫자에만 표시를 붙일
수도 있다(chat). = 'AI 결과의 정확도 보증 장치'.
"""
from __future__ import annotations

import re

# 숫자를 읽는 규칙과, 매치에서 실제 값을 뽑는 함수를 함께 둔다.
# extract_amounts 와 annotate 가 같은 규칙을 봐야 "검사에선 걸렸는데 표시가 안 되는"
# 어긋남이 생기지 않는다.
_PATTERNS: tuple[tuple[re.Pattern[str], object], ...] = (
    # "4만원" / "4만" → 40,000
    (re.compile(r"(\d[\d,]*)\s*만원?"), lambda m: int(m.group(1).replace(",", "")) * 10_000),
    # "52,000원" / "52000원" → 52,000
    (re.compile(r"(\d[\d,]{2,})\s*원"), lambda m: int(m.group(1).replace(",", ""))),
    # "75%" → 75
    (re.compile(r"(\d{1,3})\s*%"), lambda m: int(m.group(1))),
)


def _spans(text: str) -> list[tuple[int, int, int]]:
    """(시작, 끝, 값) 목록. 다른 매치에 완전히 포함된 건 버린다."""
    found: list[tuple[int, int, int]] = []
    for pattern, value_of in _PATTERNS:
        for m in pattern.finditer(text):
            found.append((m.start(), m.end(), value_of(m)))
    found.sort(key=lambda s: (s[0], -(s[1] - s[0])))
    kept: list[tuple[int, int, int]] = []
    for span in found:
        if any(k[0] <= span[0] and span[1] <= k[1] for k in kept):
            continue
        kept.append(span)
    return kept


def extract_amounts(text: str) -> set[int]:
    return {value for _s, _e, value in _spans(text)}


def expand_roundings(allowed: set[int]) -> set[int]:
    """반올림한 표현도 허용한다 — 118,500원을 '약 12만원'이라고 말하는 건 지어낸 게 아니다.

    허용 오차(tol)를 넓게 잡는 대신 반올림 값 자체를 명단에 넣는다. tol 을 5,000 으로
    두면 542,630 이 허용됐다는 이유로 545,000 같은 없는 숫자까지 통과하는데,
    반올림 값만 더하면 '약 54만원'은 통과하고 545,000원은 여전히 걸린다.
    확률(0~100)은 만원 단위로 반올림하면 0이 되므로 금액 구간만 넓힌다.
    """
    out = set(allowed)
    for value in allowed:
        if value < 10_000:
            continue
        for unit in (1_000, 10_000):
            out.add(round(value / unit) * unit)
            out.add((value // unit) * unit)
    return out


def check(text: str, allowed: set[int], tol: int = 0) -> tuple[bool, list[int]]:
    found = extract_amounts(text)
    ungrounded = sorted(n for n in found if not _grounded(n, allowed, tol))
    return (len(ungrounded) == 0, ungrounded)


def annotate(text: str, allowed: set[int], tol: int = 0,
             marker: str = "(확인 필요)") -> tuple[str, list[int]]:
    """근거 없는 숫자 뒤에만 표시를 붙인 문장을 돌려준다.

    응답 전체를 버리면 맞는 문장 세 개가 틀린 숫자 하나 때문에 같이 사라진다.
    사용자에게는 나머지를 보여주되, 어느 숫자를 못 믿는지는 분명히 밝힌다.
    """
    bad: list[int] = []
    # 뒤에서부터 끼워 넣어야 앞쪽 위치가 밀리지 않는다.
    for start, end, value in sorted(_spans(text), key=lambda s: s[0], reverse=True):
        if _grounded(value, allowed, tol):
            continue
        bad.append(value)
        text = f"{text[:end]} {marker}{text[end:]}"
    return text, sorted(set(bad))


def _grounded(value: int, allowed: set[int], tol: int) -> bool:
    if value in allowed:
        return True
    return any(abs(value - a) <= tol for a in allowed) if tol else False
