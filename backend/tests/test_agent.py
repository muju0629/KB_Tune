"""대화 에이전트와 검색어 검증기.

이 기능이 지켜야 하는 것은 하나다. **모델이 만든 검색어에 사용자 문장의 낱말이
섞이면 검색 엔진으로 나가지 않는다.** LLM 제공자는 무보존을 계약으로 묶을 수 있지만
검색 엔진은 그게 안 되기 때문에, 두 통로를 다른 등급으로 취급한다.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.engine import searchguard
from app.llm import agent
from app.main import app

client = TestClient(app)


# ---------- 검색어 검증기 ----------

@pytest.mark.parametrize("query", [
    "국내 3박 여행 1인 평균 경비",
    "해외 2박 숙박 요금 평균",
    "여행 평균 비용",
    "결혼식 축의금 평균",
    "영화 관람료 평균",
])
def test_queries_built_from_allowed_words_pass(query):
    assert searchguard.is_safe(query), searchguard.rejected_tokens(query)


@pytest.mark.parametrize("query,leaked", [
    ("제주도 3박4일 여행 경비", "제주도"),
    ("김민수 결혼식 축의금 평균", "김민수"),
    ("성심병원 진료비 평균", "성심병원"),
    ("강남 미용실 가격", "강남"),
    ("이태원 맛집 저녁 비용", "이태원"),
    ("성당 모임 회비 평균", "성당"),
])
def test_queries_carrying_user_words_are_rejected(query, leaked):
    assert not searchguard.is_safe(query)
    assert leaked in searchguard.rejected_tokens(query)


def test_absurdly_long_query_is_rejected():
    """길면 문장을 통째로 옮겨 담은 것이다."""
    assert not searchguard.is_safe("여행 " * 40)


# ---------- 검증기와 에이전트의 접속 ----------

def _plan():
    from app.data import PROFILE
    from app.engine import build_plan
    return build_plan(PROFILE, 22, False)


def test_unsafe_query_is_never_searched(monkeypatch):
    """검증기가 막으면 search_cost 를 부르지도 않아야 한다."""
    called = []
    monkeypatch.setattr(agent, "search_cost", lambda q: called.append(q))
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: ({
        "reply": "네", "actions": [], "search_query": "제주도 3박4일 여행 경비",
    }, ""))
    result = agent.run_agent(_plan(), "제주도 여행 얼마야", 22, may_search=True)
    assert called == []
    assert result.searched_query is None
    assert "보내지 않았어요" in result.reply


def test_search_is_not_offered_without_consent(monkeypatch):
    """동의를 안 받았으면 안전한 질의여도 검색하지 않는다."""
    called = []
    monkeypatch.setattr(agent, "search_cost", lambda q: called.append(q))
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: ({
        "reply": "네", "actions": [], "search_query": "국내 3박 여행 1인 평균 경비",
    }, ""))
    result = agent.run_agent(_plan(), "여행 얼마야", 22, may_search=False)
    assert called == []
    assert result.searched_query is None


def test_safe_query_reaches_search(monkeypatch):
    from app.models import SearchCostResult

    monkeypatch.setattr(agent, "search_cost", lambda q: SearchCostResult(
        amount=286_000, low=185_000, high=317_000, method="web",
        basis="공표 자료 기준이에요.", sources=["https://example.kr"],
    ))
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: ({
        "reply": "여행이군요.",
        "actions": [{"kind": "add_event", "day": 45, "title": "여행",
                     "category": "여행", "amount": None, "label": "일정 추가"}],
        "search_query": "국내 3박 여행 1인 평균 경비",
    }, ""))
    result = agent.run_agent(_plan(), "여행 얼마야", 22, may_search=True)
    assert result.searched_query == "국내 3박 여행 1인 평균 경비"
    assert result.method == "llm+web"
    # 금액을 비워 둔 동작은 검색 결과로 채워진다.
    assert result.actions[0].amount == 286_000


# ---------- 동작 스키마 ----------

def test_malformed_actions_are_dropped_not_crashed(monkeypatch):
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: ({
        "reply": "네",
        "actions": [
            {"kind": "존재하지않는동작", "day": 45, "title": "x", "label": "y"},
            {"kind": "add_event", "title": "날짜없음", "label": "y"},
            "문자열",
            {"kind": "add_event", "day": 45, "title": "여행", "label": "일정 추가"},
        ],
        "search_query": None,
    }, ""))
    result = agent.run_agent(_plan(), "뭐든", 22, may_search=False)
    assert len(result.actions) == 1
    assert result.actions[0].title == "여행"


def test_prose_answer_is_kept_not_thrown_away(monkeypatch):
    """모델이 JSON 을 안 지키고 문장으로 답해도 그 답을 보여준다.

    gpt-4.1 에서 5회 중 1회 관측된 실패다. 답 자체는 멀쩡한데 중괄호가 없다는 이유로
    버리고 '답을 만들지 못했어요'를 띄우면, 있는 답을 없애는 셈이 된다.
    """
    prose = "이번 달은 외식과 모임에 지출이 몰려 있어요. 데이트 일정은 그대로 지키고 있고요."
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: (None, prose))
    result = agent.run_agent(_plan(), "내 소비패턴은 어때?", 22, may_search=False)
    assert result.reply == prose
    assert result.method == "llm"
    assert result.actions == []


def test_broken_json_is_not_shown_raw(monkeypatch):
    """중괄호가 섞인 건 깨진 JSON 이다. 사용자에게 그대로 보이면 안 된다."""
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: (None, '{"reply": "여기서 잘림'))
    result = agent.run_agent(_plan(), "뭐든", 22, may_search=False)
    assert result.method == "template"
    assert "{" not in result.reply


def test_agent_survives_a_model_that_returns_nothing(monkeypatch):
    monkeypatch.setattr("app.llm.complete.complete_json_with_text",
                        lambda *_a, **_k: (None, ""))
    result = agent.run_agent(_plan(), "뭐든", 22, may_search=False)
    assert result.method == "template"
    assert result.reply
    assert result.actions == []


# ---------- 엔드포인트 ----------

def test_agent_endpoint_defaults_to_no_search():
    """may_search 를 안 보내면 검색이 꺼진 것으로 본다."""
    from app.models import AgentRequest

    assert AgentRequest(message="안녕").may_search is False


def test_agent_endpoint_answers_without_a_model():
    """LLM 이 꺼져 있어도 500 이 아니라 사람이 읽을 답이 나가야 한다."""
    resp = client.post("/api/agent", json={"message": "이번 주 얼마 남았어?"})
    assert resp.status_code == 200
    assert resp.json()["reply"]
