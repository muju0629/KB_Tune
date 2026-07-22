"""엔진 오케스트레이션 — 프로필/거래/일정 → PlanResult (모든 숫자의 단일 출처)."""
from __future__ import annotations

from ..data import (DAYS_IN_MONTH, TRANSACTIONS_THIS_MONTH, UPCOMING_EVENTS)
from ..models import PlanResult, Profile
from . import analysis, budget, probability, risk


def _estimate_bounds() -> tuple[int, int]:
    low = sum(t.amount if t.estimate_low is None else t.estimate_low
              for t in TRANSACTIONS_THIS_MONTH)
    high = sum(t.amount if t.estimate_high is None else t.estimate_high
               for t in TRANSACTIONS_THIS_MONTH)
    low += sum(e.amount if e.estimate_low is None else e.estimate_low for e in UPCOMING_EVENTS)
    high += sum(e.amount if e.estimate_high is None else e.estimate_high for e in UPCOMING_EVENTS)
    return low, high


def build_plan(profile: Profile, today: int = 22, include_candidate: bool = False) -> PlanResult:
    txns = TRANSACTIONS_THIS_MONTH
    events = UPCOMING_EVENTS

    b = budget.weekly_available(profile, txns, events, today, DAYS_IN_MONTH, include_candidate)
    prob = probability.goal_probability(
        profile, events, today, DAYS_IN_MONTH, b["remaining_budget"], include_candidate
    )
    spend_analysis = analysis.analyze()
    risk_assessment = risk.assess_risk(profile, txns, events, today, DAYS_IN_MONTH, b["remaining_budget"])
    adjustments = risk.generate_adjustments(profile, txns, events, today, DAYS_IN_MONTH, b["remaining_budget"])

    protected = "·".join(profile.protected_categories)
    protected_summary = f"{protected} 일정 우선" if protected else "우선할 일정 미설정"
    month_low, month_high = _estimate_bounds()
    month_end_low = b["disposable_month"] - month_high
    month_end_high = b["disposable_month"] - month_low

    # LLM/평가가 인용해도 되는 숫자 화이트리스트
    grounded: set[int] = {
        b["weekly_available"], b["weekly_budget"], b["remaining_budget"],
        b["disposable_month"], b["variable_spent_to_date"], b["committed_this_week"],
        prob, profile.savings_goal, profile.monthly_income,
        month_low, month_high, month_end_low, month_end_high,
    }
    grounded |= {c.monthly_avg for c in spend_analysis.categories}
    for a in adjustments:
        grounded |= {a.weekly_available, a.probability}
    if risk_assessment.has_risk:
        grounded |= {
            risk_assessment.amount or 0,
            risk_assessment.probability_now or 0,
            risk_assessment.probability_if_added or 0,
        }

    return PlanResult(
        direction=profile.direction,
        disposable_month=b["disposable_month"],
        variable_spent_to_date=b["variable_spent_to_date"],
        remaining_budget=b["remaining_budget"],
        remaining_weeks=b["remaining_weeks"],
        weekly_budget=b["weekly_budget"],
        committed_this_week=b["committed_this_week"],
        weekly_available=b["weekly_available"],
        probability=prob,
        savings_goal=profile.savings_goal,
        month_estimate_low=month_low,
        month_estimate_high=month_high,
        month_end_remaining_low=month_end_low,
        month_end_remaining_high=month_end_high,
        estimate_basis="7월 캘린더 일정과 일정 유형별 보수적 예상액",
        protected_summary=protected_summary,
        analysis=spend_analysis,
        risk=risk_assessment,
        adjustments=adjustments,
        grounded_numbers=sorted(grounded),
    )
