"""공개 통계 기준 금액(baseline).

이 기능이 지켜야 하는 것 두 가지를 테스트로 박아 둔다.
  ① 이력이 없는 사람에게도 값이 나오되, 그 값이 남의 소비 이력이 아니라 공개 통계일 것
  ② 개인 이력이 있으면 그게 항상 이긴다 — 통계 평균이 개인 값을 덮지 않을 것
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import baseline
from app.data import TRANSACTIONS_HISTORY
from app.engine.estimate import estimate_event_cost
from app.main import app

client = TestClient(app)


# ---------- 표 자체 ----------

def test_bundled_table_loads_without_firestore():
    """자격증명도 네트워크도 없이 표가 읽혀야 한다. Cloud Run 밖에서도 앱이 돌아야 하니까."""
    table = baseline.table()
    assert table["events"] and table["items"]
    assert table["monthly"]["total"] > 0


def test_every_row_carries_its_source():
    """근거 없는 숫자를 못 넣게 막는다. 화면에 출처를 그대로 인용하기 때문이다."""
    table = baseline.table()
    for row in table["events"] + table["items"]:
        assert row["source"].strip(), row
        # 출처 문자열에는 기준 시점이 괄호로 들어간다 — '(2026-06, 전국 16개 시도)'
        assert "(" in row["source"] and "20" in row["source"], row


def test_ranges_bracket_the_amount():
    for row in baseline.table()["events"] + baseline.table()["items"]:
        assert row["low"] <= row["amount"] <= row["high"], row


def test_monthly_bimok_sums_close_to_total():
    """12대 비목 합계가 공표 총액과 맞는지. 파서가 열을 밀려 읽으면 여기서 걸린다."""
    monthly = baseline.monthly()
    total = sum(b["amount"] for b in monthly["bimok"])
    assert abs(total - monthly["total"]) <= monthly["total"] * 0.02


# ---------- 조회 ----------

def test_age_factor_changes_the_amount():
    plain = baseline.for_category("모임")
    twenties = baseline.for_category("모임", age_bucket="20")
    assert twenties["amount"] < plain["amount"]      # 20대는 같은 업종에서 덜 쓴다
    assert "20대" in twenties["age_note"]


def test_unknown_age_bucket_is_ignored_not_crashed():
    assert baseline.for_category("모임", age_bucket="99") == baseline.for_category("모임")


def test_category_without_public_statistics_returns_none():
    """축의금·스터디비에 대응하는 공표 통계가 없다. 없으면 없다고 해야 규칙으로 넘어간다."""
    assert baseline.for_category("경조사") is None
    assert baseline.for_category("업무·학업") is None


def test_item_lookup_beats_nothing():
    match = baseline.for_title("점심은 자장면")
    assert match is not None
    assert "자장면" in match["basis"]


# ---------- 추정기와의 접속 ----------

def test_new_user_with_no_history_gets_a_sourced_amount():
    """일정을 하나도 안 가진 사람. 이 기능의 존재 이유다."""
    result = estimate_event_cost("친구 저녁", [])
    assert result.method == "baseline"
    assert result.amount > 0
    assert "출처는" in result.basis


def test_personal_history_wins_over_public_average():
    """성제의 모임 평균은 25,000원, 공개 통계는 47,791원. 개인 값이 이겨야 한다."""
    with_history = estimate_event_cost("친구 저녁", TRANSACTIONS_HISTORY)
    assert with_history.method == "rule"          # 이력 경로
    assert with_history.amount == 25_000


def test_llm_guess_wins_over_generic_baseline(monkeypatch):
    """LLM 을 부른 제목은 규칙도 이력도 못 잡은 것들이라 카테고리 평균보다 LLM 이 가깝다."""
    monkeypatch.setattr("app.llm.complete.complete_json",
                        lambda *_a, **_k: {"category": "여가", "amount": 28_000})
    result = estimate_event_cost("방탈출 예약", [], use_llm=True)
    assert result.method == "llm"
    assert result.amount == 28_000


def test_category_without_baseline_falls_back_to_rule():
    result = estimate_event_cost("교수님 결혼식", [])
    assert result.method == "rule"
    assert result.category == "경조사"


@pytest.mark.parametrize("bucket", ["20", "30", "40", "50"])
def test_age_bucket_flows_through_the_estimator(bucket):
    plain = estimate_event_cost("친구 저녁", [])
    aged = estimate_event_cost("친구 저녁", [], age_bucket=bucket)
    assert aged.method == "baseline"
    if bucket == "20":
        assert aged.amount < plain.amount


# ---------- 엔드포인트 ----------

def test_baseline_endpoint_needs_no_request_body():
    """제목당 한 번 물어보는 방식이면 일정 제목이 나간다. 그래서 본문 없는 GET 이다."""
    resp = client.get("/api/baseline")
    assert resp.status_code == 200
    body = resp.json()
    assert body["events"] and body["monthly"]


def test_search_request_has_no_field_but_the_query():
    """받을 칸이 있으면 언젠가 채워 보낸다. 검색어 말고는 칸 자체를 두지 않는다."""
    from app.models import SearchCostRequest

    assert set(SearchCostRequest.model_fields) == {"query"}


def test_search_rejects_a_query_long_enough_to_carry_a_title():
    resp = client.post("/api/search/cost", json={"query": "가" * 200})
    assert resp.status_code == 422


def test_search_is_unavailable_without_an_external_model():
    """offline 이면 검색 도구가 없다. 없는데 있는 척하지 않고 사용자에게 넘긴다."""
    resp = client.post("/api/search/cost", json={"query": "국내 3박 여행 1인 평균 경비"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["method"] == "unavailable"
    assert body["amount"] is None


def test_search_drops_an_answer_with_no_sources(monkeypatch):
    """근거 문서를 못 대는 숫자는 모델이 지어낸 것과 구분할 수 없다."""
    from app.llm import search

    monkeypatch.setattr(search.config, "llm_backend", lambda: "openai")
    monkeypatch.setattr(search, "_search",
                        lambda *_a: ({"amount": 300_000, "basis": "그냥"}, []))
    assert search.search_cost("국내 3박 여행 1인 평균 경비").method == "unavailable"


def test_search_drops_an_amount_outside_a_believable_range(monkeypatch):
    from app.llm import search

    monkeypatch.setattr(search.config, "llm_backend", lambda: "openai")
    for absurd in (12, 90_000_000, float("inf"), True, "3만원"):
        monkeypatch.setattr(search, "_search",
                            lambda *_a, v=absurd: ({"amount": v, "basis": "x"}, ["출처"]))
        assert search.search_cost("국내 3박 여행 1인 평균 경비").method == "unavailable"


def test_baseline_response_carries_no_personal_data():
    """공개 통계만 나가야 한다. 데모 페르소나의 이름·금액이 섞이면 안 된다."""
    text = client.get("/api/baseline").text
    for leaked in ("성제", "인포스탁", "SensCoreAI", "와드"):
        assert leaked not in text
