"""적금 목표 달성 확률 — 몬테카를로 시뮬레이션.

'이번 달 가변지출이 가처분 예산을 넘지 않을 확률' = 저축 목표를 지킬 확률.
남은 지출 = 확정된 미래 일정 + 재량 지출(캘린더 밖 지출 완충치).
시드를 고정해 재현 가능(=평가 가능)하게 만든다.
"""
from __future__ import annotations

import math
import random

from ..models import PlannedEvent, Profile

# 소비 방향별 재량지출 배수(위험 성향).
DIRECTION_DISCRETIONARY = {"reduce": 0.60, "maintain": 1.00, "increase": 1.35}

DISCRETIONARY_DAILY = 7_500   # 일정 밖 소액 지출에 둔 하루 완충액(데모 가정)
SIM_N = 20_000
SIM_SEED = 42                 # 재현성 고정

# σ 는 더 이상 상수가 아니다. 상수로 두면 일정 2건인 사람과 20건인 사람이
# 같은 불확실성을 갖는다 — 남은 지출이 적을수록 오차도 작아야 하는데 그렇지 않았다.
# 아래 세 값에서 σ 를 계산한다. iOS BudgetEngine 이 같은 식을 쓴다.
AMOUNT_LOG_SD = 0.40          # 건당 금액의 로그 표준편차
DISCRETIONARY_RATE = 1.0      # 일정 밖 지출 발생률(건/일)
RATE_CV = 1.0                 # 그 발생률 자체의 불확실성

# 모델이 담지 못하는 예외 지출(갑작스런 대형 결제)이 있어 확률에 상한을 둔다.
# 계산상 99.9% 가 나와도 "확실합니다"로 표시하지 않는다.
MAX_CONFIDENCE = 97

# AMOUNT_LOG_SD 는 AI Hub 117 카드 승인매출 5,000명 분산분해에서 얻은
# 개인 내부 로그분산 0.159 → sd 0.40 이다. tools/forecast_bench/mpp.py fit_prior 참조.
#
# RATE_CV = 1.0 은 "일정에 없는 지출이 얼마나 날지 사실상 모른다"를 뜻한다
# (표준편차 = 평균). 낮게 잡으면 예산이 넉넉한 달에 확률이 전부 상한에 붙어
# 소비방향을 바꿔도 숫자가 안 움직인다. 실사용자 커버리지를 측정할 수 있게 되면
# 캘리브레이션할 첫 번째 값이 이것이다 — 지금은 근거 없는 확신보다 무지를 택했다.


def spend_sigma(events: list[PlannedEvent], today: int, days_in_month: int,
                direction: str, include_candidate: bool, extra: int = 0) -> float:
    """남은 지출의 표준편차. 확정 일정의 금액 오차 + 일정 밖 지출의 발생 불확실성.

        Var = Σ 일정금액² · (exp(s²) − 1)                  ← 금액 추정 오차
            + E[X]² · (t · exp(s²) + t² · CV²)             ← 복합 포아송 + 발생률 오차

    둘째 항의 t² 이 핵심이다. 발생률 자체가 불확실하면 기간이 길어질 때
    분산이 기간에 비례가 아니라 제곱으로 커진다 — 월초 예측이 월말 예측보다
    훨씬 불확실한 이유가 여기서 나온다.
    """
    cv2 = math.expm1(AMOUNT_LOG_SD ** 2)
    sum_sq = sum(e.amount ** 2
                 for e in events
                 if e.day >= today and (e.confirmed or include_candidate))
    sum_sq += extra ** 2      # 검토 중인 일정도 금액 오차를 갖는다
    var = sum_sq * cv2

    day_of_month = (today - 1) % days_in_month + 1
    days_left = days_in_month - day_of_month + 1
    per_event = DISCRETIONARY_DAILY * DIRECTION_DISCRETIONARY[direction] / DISCRETIONARY_RATE
    t = DISCRETIONARY_RATE * days_left
    var += per_event ** 2 * (t * math.exp(AMOUNT_LOG_SD ** 2) + t ** 2 * RATE_CV ** 2)

    return math.sqrt(var)


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
    # today는 두 달 통산일일 수 있다(8/1=32). 현재 달의 일자로 환산해야
    # 남은 날이 음수가 되어 재량지출이 확률을 거꾸로 올리는 일이 없다.
    day_of_month = (today - 1) % days_in_month + 1
    days_left = days_in_month - day_of_month + 1
    discretionary = DISCRETIONARY_DAILY * days_left * DIRECTION_DISCRETIONARY[profile.direction]
    return int(committed_future(events, today, include_candidate) + discretionary)


def probability_mc(mu: int, sigma: float, remaining_budget: int,
                   n: int = SIM_N, seed: int = SIM_SEED) -> int:
    """P(남은지출 ≤ 남은예산). 시드 고정 → 실행마다 동일."""
    rng = random.Random(seed)
    success = 0
    for _ in range(n):
        draw = max(0.0, rng.gauss(mu, sigma))
        if draw <= remaining_budget:
            success += 1
    return min(round(success / n * 100), MAX_CONFIDENCE)


def probability_analytic(mu: int, sigma: float, remaining_budget: int) -> int:
    """정규 CDF 근사(평가/교차검증용). MC와 근사 일치해야 함."""
    z = (remaining_budget - mu) / sigma
    cdf = 0.5 * (1 + math.erf(z / math.sqrt(2)))
    return min(round(cdf * 100), MAX_CONFIDENCE)


def goal_probability(profile: Profile, events: list[PlannedEvent], today: int,
                     days_in_month: int, remaining_budget: int, include_candidate: bool = False) -> int:
    mu = expected_remaining_spend(profile, events, today, days_in_month, include_candidate)
    sigma = spend_sigma(events, today, days_in_month, profile.direction, include_candidate)
    return probability_mc(mu, sigma, remaining_budget)
