"""엔진·평가 회귀 테스트. `pytest` 로 실행.

LLM/네트워크 없이 순수 알고리즘만 검증한다(키 불필요).
"""
from app.data import DAYS_IN_MONTH, PROFILE, UPCOMING_EVENTS
from app.engine import build_plan
from app.engine.probability import (SPEND_SIGMA, expected_remaining_spend,
                                    probability_analytic)
from app.eval.golden import run_golden
from app.eval.groundedness import check, extract_amounts


def test_golden_all_pass():
    passed, total, details = run_golden()
    assert passed == total, "\n" + "\n".join(details)


def test_weekly_available_and_probability():
    r = build_plan(PROFILE, today=21)
    assert r.weekly_available == 52_000
    assert r.probability == 78
    assert r.disposable_month == 470_000
    assert r.remaining_budget == 200_000


def test_direction_changes_outputs():
    reduce = build_plan(PROFILE.model_copy(update={"direction": "reduce"}), 21)
    increase = build_plan(PROFILE.model_copy(update={"direction": "increase"}), 21)
    assert reduce.weekly_available == 38_000 and reduce.probability == 86
    assert increase.weekly_available == 70_000 and increase.probability == 69


def test_risk_detected():
    r = build_plan(PROFILE, today=21)
    assert r.risk.has_risk
    assert r.risk.event_title == "생일파티 2차"
    assert r.risk.probability_now == 78
    assert r.risk.probability_if_added == 60


def test_monte_carlo_matches_analytic():
    """시드 고정 MC가 정규근사와 ±2%p 이내 → 모델 신뢰성."""
    mu = expected_remaining_spend(PROFILE, UPCOMING_EVENTS, 21, DAYS_IN_MONTH, False)
    r = build_plan(PROFILE, 21)
    analytic = probability_analytic(mu, SPEND_SIGMA, r.remaining_budget)
    assert abs(r.probability - analytic) <= 2


def test_deterministic():
    """같은 입력 → 항상 같은 출력(재현성)."""
    a = build_plan(PROFILE, 21)
    b = build_plan(PROFILE, 21)
    assert a.weekly_available == b.weekly_available
    assert a.probability == b.probability


def test_groundedness_extract():
    nums = extract_amounts("이번 주 52,000원까지 괜찮고 확률은 78%예요. 4만원만 조정하세요.")
    assert {52_000, 78, 40_000} <= nums


def test_groundedness_flags_hallucination():
    ok, bad = check("목표 확률은 99%까지 올라가요", allowed={78})
    assert not ok and 99 in bad
