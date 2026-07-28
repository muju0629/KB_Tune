"""엔진·평가 회귀 테스트. `pytest` 로 실행.

LLM/네트워크 없이 순수 알고리즘만 검증한다(키 불필요).
"""
from app.data import (DAYS_IN_MONTH, PROFILE, TRANSACTIONS_THIS_MONTH,
                      UPCOMING_EVENTS)
from app.engine import build_plan
from app.engine.budget import remaining_weeks
from app.engine.probability import (SPEND_SIGMA, expected_remaining_spend,
                                    probability_analytic)
from app.eval.golden import run_golden
from app.eval.groundedness import check, extract_amounts


def test_golden_all_pass():
    passed, total, details = run_golden()
    assert passed == total, "\n" + "\n".join(details)


def test_weekly_available_and_probability():
    r = build_plan(PROFILE, today=22)
    assert r.weekly_available == 62_000
    assert r.probability == 81
    assert r.disposable_month == 965_000
    assert r.remaining_budget == 204_000
    assert r.committed_this_week == 40_000


def test_direction_changes_outputs():
    reduce = build_plan(PROFILE.model_copy(update={"direction": "reduce"}), 22)
    increase = build_plan(PROFILE.model_copy(update={"direction": "increase"}), 22)
    assert reduce.weekly_available == 47_720 and reduce.probability == 88
    assert increase.weekly_available == 80_360 and increase.probability == 74


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
    r = build_plan(PROFILE, 22)
    analytic = probability_analytic(mu, SPEND_SIGMA, r.remaining_budget)
    assert abs(r.probability - analytic) <= 2


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
