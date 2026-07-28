"""예산 엔진 — 결정론적 계산. LLM 없이 순수 규칙으로 이번 주 사용 가능액을 구한다.

핵심 식:
    가처분(월) = 수입 − 고정비 − 저축목표
    남은예산   = 가처분 − 이번달 지금까지 가변지출
    주예산     = 남은예산 / 남은주수 × (소비방향 계수)
    사용가능액 = 주예산 − 이번 주 확정 지출
"""
from __future__ import annotations

import math

from ..models import PlannedEvent, Profile, Transaction

# 소비 방향별 이번 주 지출 허용 계수(위험 성향). maintain=1.0 기준.
DIRECTION_WEEKLY = {"reduce": 0.86, "maintain": 1.00, "increase": 1.18}

# 월 첫날 요일 오프셋(2026-07-01 = 수요일 → 월=0 기준 2)
FIRST_WEEKDAY_OFFSET = 2


def disposable_month(profile: Profile) -> int:
    fixed = sum(f.amount for f in profile.fixed_costs)
    return profile.monthly_income - fixed - profile.savings_goal


def variable_spent_to_date(txns: list[Transaction]) -> int:
    return sum(t.amount for t in txns)


def weekday(day: int) -> int:
    """해당 월 날짜 → 요일 인덱스(월=0 … 일=6)."""
    return (FIRST_WEEKDAY_OFFSET + day - 1) % 7


def week_bounds(today: int) -> tuple[int, int]:
    """오늘이 속한 주의 (시작일, 종료일)."""
    start = today - weekday(today)
    return start, start + 6


def remaining_weeks(today: int, days_in_month: int) -> int:
    # 앱은 7/1=1, 8/1=32인 통산일을 보낸다. 월말 31에서 통산일을 바로
    # 빼면 8월에는 음수가 되므로, 현재 달의 일자로 먼저 정규화한다.
    day_of_month = (today - 1) % days_in_month + 1
    days_left = days_in_month - day_of_month + 1
    return max(1, math.ceil(days_left / 7))


def committed_this_week(events: list[PlannedEvent], today: int, include_candidate: bool) -> int:
    """이번 주(오늘~일요일)의 확정 지출 합. 후보 일정은 include_candidate일 때만 포함."""
    _, end = week_bounds(today)
    total = 0
    for e in events:
        if e.day < today or e.day > end:
            continue
        if not e.confirmed and not include_candidate:
            continue
        total += e.amount
    return total


def weekly_available(profile: Profile, txns: list[Transaction], events: list[PlannedEvent],
                     today: int, days_in_month: int, include_candidate: bool = False) -> dict:
    disp = disposable_month(profile)
    spent = variable_spent_to_date(txns)
    remaining_budget = disp - spent
    weeks = remaining_weeks(today, days_in_month)
    weekly_base = remaining_budget / weeks
    factor = DIRECTION_WEEKLY[profile.direction]
    committed = committed_this_week(events, today, include_candidate)
    available = int(round(weekly_base * factor)) - committed
    return {
        "disposable_month": disp,
        "variable_spent_to_date": spent,
        "remaining_budget": remaining_budget,
        "remaining_weeks": weeks,
        "weekly_budget": int(round(weekly_base * factor)),
        "committed_this_week": committed,
        "weekly_available": available,
    }
