"""Groundedness 검사 — LLM 응답이 엔진이 계산한 숫자만 인용하는지 검증.

LLM이 지어낸(=화이트리스트에 없는) 금액/확률이 있으면 ungrounded로 판정하고,
호출부는 안전하게 템플릿 응답으로 폴백한다. = 'AI 결과의 정확도 보증 장치'.
"""
from __future__ import annotations

import re


def extract_amounts(text: str) -> set[int]:
    nums: set[int] = set()
    # "4만원" / "4만" → 40,000
    for m in re.finditer(r"(\d[\d,]*)\s*만원?", text):
        nums.add(int(m.group(1).replace(",", "")) * 10_000)
    # "52,000원" / "52000원" → 52,000
    for m in re.finditer(r"(\d[\d,]{2,})\s*원", text):
        nums.add(int(m.group(1).replace(",", "")))
    # "78%" → 78
    for m in re.finditer(r"(\d{1,3})\s*%", text):
        nums.add(int(m.group(1)))
    return nums


def check(text: str, allowed: set[int], tol: int = 0) -> tuple[bool, list[int]]:
    found = extract_amounts(text)
    ungrounded = sorted(n for n in found if not any(abs(n - a) <= tol for a in allowed))
    return (len(ungrounded) == 0, ungrounded)
