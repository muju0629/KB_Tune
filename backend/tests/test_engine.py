"""엔진·평가 회귀 테스트. `pytest` 로 실행.

LLM/네트워크 없이 순수 알고리즘만 검증한다(키 불필요).
"""
from app.data import (DAYS_IN_MONTH, PROFILE, TRANSACTIONS_THIS_MONTH,
                      UPCOMING_EVENTS)
from app.engine import build_plan
from app.engine.budget import remaining_weeks
from app.engine.probability import (expected_remaining_spend,
                                    probability_analytic, spend_sigma)
from app.eval.groundedness import check, extract_amounts

# 골든 케이스 — (방향, 후보반영, 기대 사용가능액, 기대 확률).
# 시드 고정 몬테카를로라 실행마다 같은 값이 나온다. 숫자가 바뀌면 회귀로 잡힌다.
# σ 를 상수 100,000 에서 일정·남은일수 기반 계산으로 바꾸면서 확률이 변했다.
# 옛 값 (88/81/74) 은 σ 가 우연히 이 날짜에 맞았던 결과다 — 월초에는 2.4배
# 과소, 월말에는 3.8배 과대였다. app/engine/probability.py:spend_sigma 참조.
GOLDEN = [
    ("reduce", False, 47_720, 97),
    ("maintain", False, 62_000, 86),
    ("increase", False, 80_360, 72),
    ("maintain", True, 62_000, 86),  # 미확정 후보가 없어 결과가 같아야 함
]


def test_golden_all_pass():
    for direction, include, exp_avail, exp_prob in GOLDEN:
        p = PROFILE.model_copy(update={"direction": direction})
        r = build_plan(p, today=22, include_candidate=include)
        tag = f"{direction}{'+후보' if include else ''}"
        assert r.weekly_available == exp_avail, f"{tag}: 가용 {r.weekly_available:,}"
        assert r.probability == exp_prob, f"{tag}: 확률 {r.probability}%"


def test_weekly_available_and_probability():
    r = build_plan(PROFILE, today=22)
    assert r.weekly_available == 62_000
    assert r.probability == 86
    assert r.disposable_month == 965_000
    assert r.remaining_budget == 204_000
    assert r.committed_this_week == 40_000


def test_direction_changes_outputs():
    reduce = build_plan(PROFILE.model_copy(update={"direction": "reduce"}), 22)
    increase = build_plan(PROFILE.model_copy(update={"direction": "increase"}), 22)
    assert reduce.weekly_available == 47_720 and reduce.probability == 97
    assert increase.weekly_available == 80_360 and increase.probability == 72


def test_8월_통산일은_현재_달_일자로_계산한다():
    assert remaining_weeks(32, DAYS_IN_MONTH) == 5   # 8월 1일
    assert remaining_weeks(62, DAYS_IN_MONTH) == 1  # 8월 31일
    start = expected_remaining_spend(PROFILE, [], 32, DAYS_IN_MONTH, False)
    end = expected_remaining_spend(PROFILE, [], 62, DAYS_IN_MONTH, False)
    assert start == 31 * 7_500
    assert end == 7_500


def test_8월_계획에_7월_지출을_현재_지출로_재사용하지_않는다():
    august = build_plan(PROFILE, today=40)
    assert august.variable_spent_to_date == 0
    assert august.remaining_budget == august.disposable_month
    assert august.month_estimate_low == 0
    assert august.month_estimate_high == 0
    assert august.estimate_basis == "8월에 등록된 지출 일정 없음"


def test_calendar_estimate_range_and_no_fake_candidate():
    r = build_plan(PROFILE, today=22)
    assert r.month_estimate_low == 801_000
    assert r.month_estimate_high == 801_000
    assert r.month_end_remaining_low == 164_000
    assert r.month_end_remaining_high == 164_000
    assert not r.risk.has_risk
    assert r.adjustments == []
    assert build_plan(PROFILE, today=22, include_candidate=True).weekly_available == 62_000


def test_calendar_inputs_match_visible_schedule():
    assert sum(t.amount for t in TRANSACTIONS_THIS_MONTH) == 761_000
    assert sum(e.amount for e in UPCOMING_EVENTS) == 40_000
    assert sum(e.amount for e in UPCOMING_EVENTS if 22 <= e.day <= 26) == 40_000


def test_monte_carlo_matches_analytic():
    """시드 고정 MC가 정규근사와 ±2%p 이내 → 모델 신뢰성."""
    mu = expected_remaining_spend(PROFILE, UPCOMING_EVENTS, 22, DAYS_IN_MONTH, False)
    sigma = spend_sigma(UPCOMING_EVENTS, 22, DAYS_IN_MONTH, PROFILE.direction, False)
    r = build_plan(PROFILE, 22)
    analytic = probability_analytic(mu, sigma, r.remaining_budget)
    assert abs(r.probability - analytic) <= 2


def test_sigma_는_남은_일수에_반응한다():
    """σ 를 상수로 두면 월초와 월말의 불확실성이 같아진다. 그게 옛 결함이었다."""
    early = spend_sigma(UPCOMING_EVENTS, 1, DAYS_IN_MONTH, "maintain", False)
    mid = spend_sigma(UPCOMING_EVENTS, 15, DAYS_IN_MONTH, "maintain", False)
    late = spend_sigma(UPCOMING_EVENTS, 29, DAYS_IN_MONTH, "maintain", False)
    assert early > mid > late, f"{early:,.0f} / {mid:,.0f} / {late:,.0f}"
    assert late < 50_000, "월말 3일 남았는데 불확실성이 여전히 크다"

    # 소비방향이 커지면 재량지출도 커지므로 σ 도 커진다
    assert (spend_sigma(UPCOMING_EVENTS, 22, DAYS_IN_MONTH, "increase", False)
            > spend_sigma(UPCOMING_EVENTS, 22, DAYS_IN_MONTH, "reduce", False))


def test_deterministic():
    """같은 입력 → 항상 같은 출력(재현성)."""
    a = build_plan(PROFILE, 22)
    b = build_plan(PROFILE, 22)
    assert a.weekly_available == b.weekly_available
    assert a.probability == b.probability


def test_groundedness_extract():
    nums = extract_amounts("이번 주 약 62,000원이고 목표 확률은 81%예요. 월말에는 164,000원이 남을 수 있어요.")
    assert {62_000, 81, 164_000} <= nums


def test_groundedness_flags_hallucination():
    ok, bad = check("목표 확률은 99%까지 올라가요", allowed={67})
    assert not ok and 99 in bad
