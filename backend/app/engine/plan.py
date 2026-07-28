"""엔진 오케스트레이션 — 프로필/거래/일정 → PlanResult (모든 숫자의 단일 출처)."""
from __future__ import annotations

from ..data import (DAYS_IN_MONTH, TRANSACTIONS_THIS_MONTH, UPCOMING_EVENTS)
from ..models import PlanResult, Profile
from . import analysis, budget, probability, risk


def _estimate_bounds(txns, events) -> tuple[int, int]:
    low = sum(t.amount if t.estimate_low is None else t.estimate_low for t in txns)
    high = sum(t.amount if t.estimate_high is None else t.estimate_high for t in txns)
    low += sum(e.amount if e.estimate_low is None else e.estimate_low for e in events)
    high += sum(e.amount if e.estimate_high is None else e.estimate_high for e in events)
    return low, high


def _month_context(today: int):
    """통산일이 가리키는 달의 데이터만 고른다.

    서버 시드에는 확인된 7월 데이터만 있다. 8월 요청에 7월 소비를 현재 소비인 것처럼
    재사용하지 않고, 등록된 8월 데이터가 없으면 빈 달로 계산한다.
    """
    month_index = (today - 1) // DAYS_IN_MONTH
    month = 7 + month_index
    start = month_index * DAYS_IN_MONTH + 1
    end = start + DAYS_IN_MONTH - 1
    txns = [t for t in TRANSACTIONS_THIS_MONTH if t.month == month]
    events = [e for e in UPCOMING_EVENTS if start <= e.day <= end]
    return month, txns, events


def build_plan(profile: Profile, today: int = 22, include_candidate: bool = False) -> PlanResult:
    month, txns, events = _month_context(today)

    b = budget.weekly_available(profile, txns, events, today, DAYS_IN_MONTH, include_candidate)
    prob = probability.goal_probability(
        profile, events, today, DAYS_IN_MONTH, b["remaining_budget"], include_candidate
    )
    spend_analysis = analysis.analyze()
    risk_assessment = risk.assess_risk(profile, txns, events, today, DAYS_IN_MONTH, b["remaining_budget"])
    adjustments = risk.generate_adjustments(profile, txns, events, today, DAYS_IN_MONTH, b["remaining_budget"])

    protected = "·".join(profile.protected_categories)
    protected_summary = f"{protected} 일정 우선" if protected else "우선할 일정 미설정"
    month_low, month_high = _estimate_bounds(txns, events)
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
        estimate_basis=(f"{month}월 캘린더 일정과 일정 유형별 보수적 예상액"
                        if txns or events else f"{month}월에 등록된 지출 일정 없음"),
        protected_summary=protected_summary,
        analysis=spend_analysis,
        risk=risk_assessment,
        adjustments=adjustments,
        grounded_numbers=sorted(grounded),
    )
