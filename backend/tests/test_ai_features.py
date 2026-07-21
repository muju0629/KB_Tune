"""AI 기능 4종 회귀 테스트 — 전부 키/네트워크 없이 결정론 경로로 검증."""
from app.data import PROFILE, TRANSACTIONS_HISTORY
from app.engine.budget import disposable_month
from app.engine.categorize import categorize_many, categorize_rule
from app.engine.estimate import estimate_event_cost
from app.engine.forecast import detect_patterns, forecast_next_month
from app.llm.extract import extract_from_text


# ---------- ③ 분류 ----------

def test_categorize_rules():
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
    """과거 '술·모임' 이력(25,000/35,000)으로 개인화되어야 한다."""
    r = estimate_event_cost("동아리 회식", TRANSACTIONS_HISTORY)
    assert r.category == "술·모임"
    assert r.low == 25_000 and r.high == 35_000
    assert 25_000 <= r.amount <= 35_000
    assert "3개월" in r.basis


def test_estimate_unknown_category_falls_back():
    r = estimate_event_cost("우주여행 티켓 발권", TRANSACTIONS_HISTORY)
    assert r.method in ("fallback", "rule", "llm")
    assert r.amount > 0


def test_estimate_wedding_uses_default_when_no_history():
    """경조사 이력이 없으므로 일반 기본값 경로."""
    r = estimate_event_cost("지민 결혼식", TRANSACTIONS_HISTORY)
    assert r.category == "경조사"
    assert r.amount == 150_000
    assert r.confidence <= 0.6


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
    assert {"카페", "외식", "술·모임", "구독"} <= kinds
    sub = next(p for p in pats if p.category == "구독")
    assert sub.cadence == "monthly" and sub.typical_day == 15
    cafe = next(p for p in pats if p.category == "카페")
    assert cafe.cadence == "weekly"


def test_forecast_next_month():
    f = forecast_next_month(TRANSACTIONS_HISTORY, disposable_month(PROFILE))
    assert f.predicted_total > 0
    assert f.predicted_events
    assert f.disposable_month == 470_000
    # 예측 합계는 카테고리 합과 일치해야 한다(계산 일관성)
    assert f.predicted_total == sum(f.by_category.values())
    assert isinstance(f.over_budget_by, int)


def test_forecast_is_deterministic():
    a = forecast_next_month(TRANSACTIONS_HISTORY, 470_000)
    b = forecast_next_month(TRANSACTIONS_HISTORY, 470_000)
    assert a.predicted_total == b.predicted_total
