"""엔진 오케스트레이션 — 프로필/거래/일정 → PlanResult (모든 숫자의 단일 출처)."""
from __future__ import annotations

from ..data import (DAYS_IN_MONTH, TRANSACTIONS_THIS_MONTH, UPCOMING_EVENTS)
from ..models import PlanResult, Profile
from . import analysis, budget, probability, risk


def build_plan(profile: Profile, today: int = 21, include_candidate: bool = False) -> PlanResult:
    txns = TRANSACTIONS_THIS_MONTH
    events = UPCOMING_EVENTS

    b = budget.weekly_available(profile, txns, events, today, DAYS_IN_MONTH, include_candidate)
    prob = probability.goal_probability(
        profile, events, today, DAYS_IN_MONTH, b["remaining_budget"], include_candidate
    )
    spend_analysis = analysis.analyze()
    risk_assessment = risk.assess_risk(profile, txns, events, today, DAYS_IN_MONTH, b["remaining_budget"])
    adjustments = risk.generate_adjustments(profile, txns, events, today, DAYS_IN_MONTH, b["remaining_budget"])

    protected = "·".join(profile.protected_categories) or "지키고 싶은 소비"
    protected_summary = f"{protected}은(는) 포기하지 않기"

    # LLM/평가가 인용해도 되는 숫자 화이트리스트
    grounded: set[int] = {
        b["weekly_available"], b["weekly_budget"], b["remaining_budget"],
        b["disposable_month"], b["variable_spent_to_date"], b["committed_this_week"],
        prob, profile.savings_goal, profile.monthly_income,
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
        protected_summary=protected_summary,
        analysis=spend_analysis,
        risk=risk_assessment,
        adjustments=adjustments,
        grounded_numbers=sorted(grounded),
    )
