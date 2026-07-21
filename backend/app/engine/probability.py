"""적금 목표 달성 확률 — 몬테카를로 시뮬레이션.

'이번 달 가변지출이 가처분 예산을 넘지 않을 확률' = 저축 목표를 지킬 확률.
남은 지출 = 확정된 미래 일정 + 재량 지출(과거 패턴 기반 확률변수).
시드를 고정해 재현 가능(=평가 가능)하게 만든다.
"""
from __future__ import annotations

import math
import random

from ..models import PlannedEvent, Profile

# 소비 방향별 재량지출 배수(위험 성향).
DIRECTION_DISCRETIONARY = {"reduce": 0.60, "maintain": 1.00, "increase": 1.35}

DISCRETIONARY_DAILY = 5_500   # 과거 3개월 소액 재량지출 일평균(엔진 추정)
SPEND_SIGMA = 80_000          # 월 가변지출의 표준편차(과거 변동성)
SIM_N = 20_000
SIM_SEED = 42                 # 재현성 고정


def committed_future(events: list[PlannedEvent], today: int, include_candidate: bool) -> int:
    total = 0
    for e in events:
        if e.day < today:
            continue
        if not e.confirmed and not include_candidate:
            continue
        total += e.amount
    return total


def expected_remaining_spend(profile: Profile, events: list[PlannedEvent], today: int,
                             days_in_month: int, include_candidate: bool) -> int:
    days_left = days_in_month - today + 1
    discretionary = DISCRETIONARY_DAILY * days_left * DIRECTION_DISCRETIONARY[profile.direction]
    return int(committed_future(events, today, include_candidate) + discretionary)


def probability_mc(mu: int, sigma: int, remaining_budget: int,
                   n: int = SIM_N, seed: int = SIM_SEED) -> int:
    """P(남은지출 ≤ 남은예산). 시드 고정 → 실행마다 동일."""
    rng = random.Random(seed)
    success = 0
    for _ in range(n):
        draw = max(0.0, rng.gauss(mu, sigma))
        if draw <= remaining_budget:
            success += 1
    return round(success / n * 100)


def probability_analytic(mu: int, sigma: int, remaining_budget: int) -> int:
    """정규 CDF 근사(평가/교차검증용). MC와 근사 일치해야 함."""
    z = (remaining_budget - mu) / sigma
    cdf = 0.5 * (1 + math.erf(z / math.sqrt(2)))
    return round(cdf * 100)


def goal_probability(profile: Profile, events: list[PlannedEvent], today: int,
                     days_in_month: int, remaining_budget: int, include_candidate: bool = False) -> int:
    mu = expected_remaining_spend(profile, events, today, days_in_month, include_candidate)
    return probability_mc(mu, SPEND_SIGMA, remaining_budget)
