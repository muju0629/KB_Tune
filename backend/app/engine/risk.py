"""위험 일정 탐지 + 조정안 생성. (결정론적)

위험 = 미확정 후보 일정을 반영했을 때 목표 확률이 크게 떨어지는 경우.
조정안 = 후보 유지/이동/축소 각각의 사용가능액·확률을 같은 축으로 계산해 비교 가능하게.
"""
from __future__ import annotations

from ..models import Adjustment, PlannedEvent, Profile, RiskAssessment
from . import budget, probability

RISK_DROP_THRESHOLD = 10  # 확률이 이만큼(%p) 이상 떨어지면 위험


def candidate_event(events: list[PlannedEvent], today: int) -> PlannedEvent | None:
    _, end = budget.week_bounds(today)
    for e in events:
        if not e.confirmed and today <= e.day <= end:
            return e
    return None


def assess_risk(profile: Profile, txns, events: list[PlannedEvent], today: int,
                days_in_month: int, remaining_budget: int) -> RiskAssessment:
    cand = candidate_event(events, today)
    if cand is None:
        return RiskAssessment(has_risk=False)

    prob_now = probability.goal_probability(profile, events, today, days_in_month,
                                            remaining_budget, include_candidate=False)
    prob_if = probability.goal_probability(profile, events, today, days_in_month,
                                           remaining_budget, include_candidate=True)
    avail_now = budget.weekly_available(profile, txns, events, today, days_in_month, False)["weekly_available"]
    avail_if = avail_now - cand.amount

    has_risk = (prob_now - prob_if) >= RISK_DROP_THRESHOLD
    summary = (
        f"‘{cand.title}’ {cand.amount:,}원을 쓰면 이번 주 남는 금액이 "
        f"{avail_now:,} → {max(avail_if, 0):,}원이 되고, 목표 확률이 "
        f"{prob_now}% → {prob_if}%로 떨어져요."
    )
    return RiskAssessment(
        has_risk=has_risk,
        event_title=cand.title,
        amount=cand.amount,
        over_by=avail_now - avail_if,
        probability_if_added=prob_if,
        probability_now=prob_now,
        summary=summary,
    )


def generate_adjustments(profile: Profile, txns, events: list[PlannedEvent], today: int,
                         days_in_month: int, remaining_budget: int) -> list[Adjustment]:
    cand = candidate_event(events, today)
    if cand is None:
        return []

    base_avail = budget.weekly_available(profile, txns, events, today, days_in_month, False)["weekly_available"]
    prob_move = probability.goal_probability(profile, events, today, days_in_month, remaining_budget, False)
    prob_keep = probability.goal_probability(profile, events, today, days_in_month, remaining_budget, True)

    # 1차만(후보 지출의 약 40%로 축소)
    half = int(round(cand.amount * 0.4 / 1000)) * 1000
    prob_half = _prob_with_extra(profile, events, today, days_in_month, remaining_budget, half)

    return [
        Adjustment(
            id="move", title=f"‘{cand.title}’를 다음 주로",
            detail="모임은 지키고 이번 주 계획을 그대로 유지해요",
            weekly_available=base_avail, probability=prob_move, protects_user=True,
        ),
        Adjustment(
            id="half", title=f"2차 대신 1차까지만 ({half:,}원)",
            detail="모임엔 참여하되 지출을 줄여요",
            weekly_available=base_avail - half, probability=prob_half, protects_user=True,
        ),
        Adjustment(
            id="keep", title="그대로 쓰기",
            detail="지금 계획대로 두면 목표 확률이 낮아져요",
            weekly_available=base_avail - cand.amount, probability=prob_keep, protects_user=True,
        ),
    ]


def _prob_with_extra(profile, events, today, days_in_month, remaining_budget, extra: int) -> int:
    mu = probability.expected_remaining_spend(profile, events, today, days_in_month, False) + extra
    sigma = probability.spend_sigma(events, today, days_in_month, profile.direction, False,
                                    extra=extra)
    return probability.probability_mc(mu, sigma, remaining_budget)
