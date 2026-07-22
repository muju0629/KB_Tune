"""AI 기능 4종 회귀 테스트 — 전부 키/네트워크 없이 결정론 경로로 검증."""
from app.data import PROFILE, TRANSACTIONS_HISTORY
from app.engine.budget import disposable_month
from app.engine.categorize import categorize_many, categorize_rule
from app.engine.estimate import estimate_event_cost
from app.engine.forecast import detect_patterns, forecast_next_month
from app.llm.extract import extract_from_text


# ---------- ③ 분류 ----------

def test_categorize_rules():
    assert categorize_rule("인포스탁 인턴")[0] == "출근"
    assert categorize_rule("SensCoreAI 연구")[0] == "업무·학업"
    assert categorize_rule("200일 데이트")[0] == "데이트"
    assert categorize_rule("스타벅스 강남R점")[0] == "카페"
    assert categorize_rule("배달의민족")[0] == "배달"
    assert categorize_rule("GS25 성수점")[0] == "쇼핑"
    assert categorize_rule("알수없는가게")[0] is None


def test_categorize_many_hit_rate():
    res, hit = categorize_many(["스타벅스", "요기요", "김밥천국", "듣보잡상회"])
    assert hit == 0.75                      # 4개 중 3개 규칙 적중
    assert res[-1].category == "기타"       # 미스는 안전하게 기타로


# ---------- ① 일정 → 예상 지출 ----------

def test_estimate_uses_history():
    """7월 캘린더의 데이트 두 건(100,000/30,000원)으로 개인화한다."""
    r = estimate_event_cost("200일 데이트", TRANSACTIONS_HISTORY)
    assert r.category == "데이트"
    assert r.low == 30_000 and r.high == 100_000
    assert r.amount == 65_000
    assert "7월 캘린더" in r.basis


def test_estimate_unknown_category_falls_back():
    r = estimate_event_cost("우주여행 티켓 발권", TRANSACTIONS_HISTORY)
    assert r.method in ("fallback", "rule", "llm")
    assert r.amount > 0


def test_estimate_wedding_uses_default_when_no_history():
    """경조사 표본이 한 건뿐이므로 보수적인 기본 예상액 경로."""
    r = estimate_event_cost("지민 결혼식", TRANSACTIONS_HISTORY)
    assert r.category == "경조사"
    assert r.amount == 70_000
    assert r.confidence <= 0.6


def test_user_confirmed_schedule_costs_override_estimation():
    meeting = estimate_event_cost("회의", TRANSACTIONS_HISTORY)
    ward = estimate_event_cost("와드", TRANSACTIONS_HISTORY)
    assert (meeting.amount, meeting.low, meeting.high) == (0, 0, 0)
    assert (ward.amount, ward.low, ward.high) == (40_000, 40_000, 40_000)


# ---------- ② 캡처 → 거래 추출 ----------

SAMPLE_OCR = """
오늘
스타벅스 강남R점  -5,600원
배달의민족  -18,900원
잔액 1,204,300원
GS25 성수점  -3,200원
"""


def test_extract_from_text():
    r = extract_from_text(SAMPLE_OCR)
    amounts = sorted(t.amount for t in r.transactions)
    assert amounts == [3_200, 5_600, 18_900]      # 잔액 줄은 제외됨
    assert r.total == 27_700
    cats = {t.merchant.split()[0]: t.category for t in r.transactions}
    assert cats["스타벅스"] == "카페"
    assert r.method == "ocr-rule"


def test_extract_ignores_noise_lines():
    r = extract_from_text("합계 500,000원\n포인트 적립 1,200원")
    assert r.transactions == []
    assert r.warnings


# ---------- ④ 다음 달 예측 ----------

def test_detect_recurring_patterns():
    pats = detect_patterns(TRANSACTIONS_HISTORY)
    kinds = {p.category for p in pats}
    assert {"출근", "업무·학업", "모임", "데이트"} <= kinds
    commute = next(p for p in pats if p.category == "출근")
    assert commute.cadence == "weekly"
    assert commute.merchant == "인포스탁 인턴"


def test_forecast_next_month():
    f = forecast_next_month(TRANSACTIONS_HISTORY, disposable_month(PROFILE))
    assert f.predicted_total > 0
    assert f.predicted_events
    assert f.disposable_month == 965_000
    # 예측 합계는 카테고리 합과 일치해야 한다(계산 일관성)
    assert f.predicted_total == sum(f.by_category.values())
    assert isinstance(f.over_budget_by, int)


def test_forecast_is_deterministic():
    a = forecast_next_month(TRANSACTIONS_HISTORY, 1_220_000)
    b = forecast_next_month(TRANSACTIONS_HISTORY, 1_220_000)
    assert a.predicted_total == b.predicted_total
