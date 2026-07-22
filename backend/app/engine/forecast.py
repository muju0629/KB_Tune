"""AI 기능 ④ — 7월 캘린더의 반복 일정으로 다음 달 지출을 예측한다.

에이전트를 '물어보면 답하는' 것에서 '먼저 알려주는' 것으로 바꾸는 기능.
패턴 탐지·금액 계산은 전부 결정론(검증 가능), 문장만 LLM이 다듬을 수 있다.

설계 주의: 반복은 두 층위로 나타난다.
  - 습관(카테고리): 출근·연구처럼 반복되는 일정은 카테고리로 묶어야 주기가 보인다
  - 고정(일정명):   같은 제목이 반복되면 그 이름으로 특정한다
따라서 카테고리로 묶어 주기를 잡고, 한 가맹점이 지배적이면 그 이름을 쓴다.
예상 금액은 '카테고리 월 합계 평균'이라 주기×평균 반올림 오차가 없다.
"""
from __future__ import annotations

from collections import Counter
from statistics import mean, pstdev

from ..models import ForecastResult, PredictedEvent, RecurringPattern, Transaction

MONTHS = 1               # 현재 제공된 캘린더 범위(2026년 7월)
DOMINANT_RATIO = 0.66    # 한 가맹점이 이 비율 이상이면 '고정 지출'로 이름 붙임


def _cadence(occurrences: int) -> tuple[str, int] | None:
    """월평균 발생 횟수 → (주기 라벨, 월 횟수). 규칙성이 없으면 None."""
    per_month = occurrences / MONTHS
    if per_month >= 3.5:
        return "weekly", 4
    if per_month >= 1.7:
        return "biweekly", 2
    if per_month >= 0.9:
        return "monthly", 1
    return None


def detect_patterns(txns: list[Transaction]) -> list[RecurringPattern]:
    by_cat: dict[str, list[Transaction]] = {}
    for t in txns:
        by_cat.setdefault(t.category, []).append(t)

    patterns: list[RecurringPattern] = []
    for cat, items in by_cat.items():
        res = _cadence(len(items))
        if res is None:
            continue
        cadence, _times = res

        # 지배적 일정명이 있으면(예: 인포스탁 인턴) 그 이름을 쓴다
        counts = Counter(t.merchant for t in items if t.merchant)
        merchant = None
        if counts:
            top, n = counts.most_common(1)[0]
            if n / len(items) >= DOMINANT_RATIO:
                merchant = top

        days = sorted(t.day for t in items)
        # 매월 반복은 발생 일자가 몰릴수록 신뢰도가 높다
        if cadence == "monthly":
            spread = pstdev(days) if len(days) > 1 else 0
            conf = 0.9 if spread <= 2 else (0.7 if spread <= 5 else 0.5)
        else:
            conf = 0.8 if cadence == "weekly" else 0.75

        patterns.append(RecurringPattern(
            category=cat, merchant=merchant, cadence=cadence,
            typical_day=int(round(mean(days))),
            avg_amount=int(mean(t.amount for t in items)),
            occurrences=len(items), confidence=round(conf, 2),
        ))

    # 월 예상 지출이 큰 순 → 사용자에게 중요한 것부터
    return sorted(patterns, key=lambda p: -_monthly_total(txns, p.category))


def _monthly_total(txns: list[Transaction], category: str) -> int:
    """해당 카테고리의 월 평균 합계(정확값)."""
    return sum(t.amount for t in txns if t.category == category) // MONTHS


def _title_for(p: RecurringPattern) -> str:
    if p.merchant:
        return p.merchant
    label = {"weekly": "매주", "biweekly": "격주", "monthly": "매월"}[p.cadence]
    return f"{label} {p.category}"


def forecast_next_month(txns: list[Transaction], disposable_month: int,
                        month_label: str = "2026년 8월") -> ForecastResult:
    patterns = detect_patterns(txns)

    events: list[PredictedEvent] = []
    by_category: dict[str, int] = {}

    for p in patterns:
        monthly = _monthly_total(txns, p.category)
        by_category[p.category] = monthly

        cadence_ko = {"weekly": "매주", "biweekly": "격주", "monthly": "매월"}[p.cadence]
        reason = f"7월 캘린더에서 {p.occurrences}회({cadence_ko}) 확인됐어요"
        if p.cadence == "monthly":
            reason += f" · 보통 {p.typical_day}일"
        reason += "."

        events.append(PredictedEvent(
            title=_title_for(p), category=p.category, day=p.typical_day,
            amount=monthly,                      # 그 카테고리의 다음 달 예상 합계
            confidence=p.confidence, reason=reason,
        ))

    predicted_total = sum(by_category.values())
    over = max(0, predicted_total - disposable_month)

    if over > 0:
        verdict = (f"지금 패턴대로면 다음 달 예상 지출은 {predicted_total:,}원으로 "
                   f"가처분 {disposable_month:,}원을 {over:,}원 넘겨요.")
    else:
        verdict = (f"지금 패턴대로면 다음 달 예상 지출은 {predicted_total:,}원이고 "
                   f"{disposable_month - predicted_total:,}원 여유가 있어요.")

    return ForecastResult(
        month_label=month_label,
        predicted_events=sorted(events, key=lambda e: e.day),
        predicted_total=predicted_total,
        by_category=dict(sorted(by_category.items(), key=lambda kv: -kv[1])),
        disposable_month=disposable_month,
        over_budget_by=over,
        verdict=verdict,
        patterns=patterns,
    )
