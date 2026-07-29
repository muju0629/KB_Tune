"""공개 통계 기준 금액(baseline) 저장소.

일정 이력이 하나도 없는 사람에게도 금액을 제시하기 위한 값이다. 성제의 7월 캘린더
같은 남의 소비 이력이 아니라 공개 통계에서 온다 — 출처와 기준 시점이 행마다 붙는다.

읽는 순서는 Firestore → 번들 JSON 이다. Firestore 가 없거나 못 붙어도 서비스는
그대로 뜬다(LLM 키가 없어도 다 도는 것과 같은 원칙). 표는 20KB 남짓이고 분기마다
한 번 바뀌므로 프로세스 메모리에 통째로 캐시한다.

이 표에는 공개 통계만 있다. 사용자 데이터는 여기에 쓰지도 읽지도 않는다.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

BUNDLED = Path(__file__).resolve().parent.parent / "data" / "baseline_prices.json"
PROJECT = os.getenv("KB_TUNE_GCP_PROJECT", "kb-tune")
COLLECTION = "baseline"
DOCUMENT = "current"

_cache: dict[str, Any] | None = None


def _from_firestore() -> dict | None:
    if os.getenv("KB_TUNE_BASELINE_SOURCE", "").lower() == "bundled":
        return None
    try:
        from google.cloud import firestore
    except ImportError:
        return None
    try:
        doc = (firestore.Client(project=PROJECT)
               .collection(COLLECTION).document(DOCUMENT).get())
    except Exception as exc:                      # 자격증명 없음·네트워크 등
        log.info("baseline: Firestore 를 못 읽어 번들로 간다 (%s)", type(exc).__name__)
        return None
    return doc.to_dict() if doc.exists else None


def table() -> dict[str, Any]:
    """기준 금액 표 전체. 첫 호출에서만 읽고 이후는 메모리 캐시."""
    global _cache
    if _cache is None:
        _cache = _from_firestore() or json.loads(BUNDLED.read_text(encoding="utf-8"))
    return _cache


def for_category(category: str, age_bucket: str | None = None) -> dict | None:
    """카테고리의 기준 금액. 없으면 None — 부르는 쪽이 기존 규칙으로 넘어간다.

    반환 {amount, low, high, basis, source}. age_bucket("20"·"30"·"40"·"50")을 주면
    그 연령대의 결제 배수를 곱한다. 업무·학업·경조사처럼 대응하는 공개 통계가 없는
    카테고리는 애초에 표에 없어서 None 이 나간다.
    """
    row = next((e for e in table().get("events", []) if e["category"] == category), None)
    if row is None:
        return None

    amount, low, high = row["amount"], row["low"], row["high"]
    factor = (row.get("age_factors") or {}).get(age_bucket) if age_bucket else None
    note = ""

    if factor:
        amount, low, high = (round(v * factor) for v in (amount, low, high))
        note = f"{age_bucket}대는 같은 업종에서 평균의 {factor:.2f}배를 써서 그만큼 반영했어요. "

    return {"amount": amount, "low": low, "high": high,
            "basis": row["basis"], "age_note": note, "source": row["source"]}


def for_title(title: str) -> dict | None:
    """제목에 품목 이름이 그대로 있으면 그 단가. 카테고리 평균보다 정확하다.

    '점심'보다 '자장면'이 붙은 제목이 드물어 자주 걸리진 않지만, 걸리면 근거가
    '자장면 전국 평균 7,211원'까지 구체적으로 나온다.
    """
    compact = title.replace(" ", "")
    for row in table().get("items", []):
        # 표시 이름과 검색어가 다르다 — '삼겹살200g'은 제목에 그대로 나올 리 없다.
        if any(k.replace(" ", "") in compact for k in row.get("keywords", [row["name"]])):
            return {"amount": row["amount"], "low": row["low"], "high": row["high"],
                    "basis": f"{row['name']} 평균 {row['amount']:,}원", "age_note": "",
                    "source": row["source"]}
    return None


def monthly() -> dict[str, Any]:
    """1인가구 비목별 월평균 소비지출. 일정이 하나도 없을 때의 월 예산 뼈대."""
    return table()["monthly"]
