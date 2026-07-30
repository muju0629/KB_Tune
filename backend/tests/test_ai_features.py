"""일정 추정·대화 접지 회귀 테스트 — 전부 키/네트워크 없이 결정론 경로로 검증."""

from app import config
from app.data import PROFILE, TRANSACTIONS_HISTORY
from app.engine import build_plan
from app.engine.estimate import estimate_event_cost
from app.eval import groundedness
from app.llm import chat, prompts
from app.llm.complete import _first_json_object, complete_json
from app.models import AppNumbers, CardBilling, ChatHistoryItem, UpcomingEvent


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
    # 개인 이력을 근거로 내세우지만 않으면 된다. baseline 은 '여행' 규칙에 걸렸을 때 나온다.
    assert r.method in ("fallback", "rule", "baseline", "llm")
    assert r.amount > 0


def test_estimate_uses_shared_provider_path(monkeypatch):
    monkeypatch.setattr(
        "app.llm.complete.complete_json",
        lambda *_args, **_kwargs: {"category": "여가", "amount": 28_000},
    )
    result = estimate_event_cost("방탈출 예약", TRANSACTIONS_HISTORY, use_llm=True)
    assert result.method == "llm"
    assert result.category == "여가"
    assert result.amount == 28_000


def test_shared_json_parser_accepts_object_and_array_with_surrounding_text():
    assert _first_json_object('설명 {"amount": 20000} 끝') == {"amount": 20_000}
    assert _first_json_object('설명 뒤 [1, {"category": "카페"}] 끝') == [1, {"category": "카페"}]


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


# ---------- 실제 챗 경로 접지 검증 ----------

def _chat_context():
    plan = build_plan(PROFILE, 22)
    app = AppNumbers(
        weekly_available=77_777, probability=64, remaining_budget=333_333,
        spent_to_date=444_444, installment_carryover=12_345,
        month_end_remaining=222_222,
    )
    card = CardBilling(
        due_next=542_630, usage=633_220, carryover=90_590,
        pay_label="8월 14일", next_pay_label="9월 14일",
        days_until_pay=23, days_until_close=4, close_label="7월 26일",
    )
    upcoming = [UpcomingEvent(day=40, amount=20_000, category="카페")]
    return plan, app, card, upcoming


def test_chat_allows_exact_app_card_and_upcoming_numbers(monkeypatch):
    plan, app, card, upcoming = _chat_context()
    monkeypatch.setattr(config, "llm_backend", lambda: "openai")
    monkeypatch.setattr(
        chat, "_openai_compatible_stream",
        lambda *_args, **_kwargs: iter([
            "이번 주 추가 사용 가능액은 77,777원이고 ",
            "8월 14일 카드 청구액은 542,630원이에요. 카페 일정은 20,000원이에요.",
        ]),
    )
    result = chat.chat_reply(plan, "이번 주 어때?", card, upcoming, app)
    assert result.source == "openai"
    assert not result.blocked_numbers
    assert "77,777원" in result.text and "542,630원" in result.text


def test_chat_marks_single_fabricated_amount_and_keeps_the_rest(monkeypatch):
    """틀린 숫자 하나 때문에 맞는 문장까지 사라지지 않는다 — 그 숫자에만 표시를 붙인다."""
    plan, app, card, upcoming = _chat_context()
    monkeypatch.setattr(config, "llm_backend", lambda: "openai")
    monkeypatch.setattr(
        chat, "_openai_compatible_stream",
        lambda *_args, **_kwargs: iter([
            "이번 주 추가 사용 가능액은 77,777원이에요. 다음 달에는 999,999원이 필요해요."
        ]),
    )
    result = chat.chat_reply(plan, "얼마 남아?", card, upcoming, app)
    assert result.source == "openai(annotated)"
    # 표시를 붙였어도 모델이 지어냈다는 사실은 그대로 남는다(평가에서 실패로 집계).
    assert result.blocked_numbers == (999_999,)
    assert "999,999원 (확인 필요)" in result.text
    assert "77,777원" in result.text and "77,777원 (확인 필요)" not in result.text


def test_chat_falls_back_to_template_when_mostly_fabricated(monkeypatch):
    """지어낸 숫자가 여러 개면 표시로는 감당이 안 된다 — 통째로 템플릿."""
    plan, app, card, upcoming = _chat_context()
    monkeypatch.setattr(config, "llm_backend", lambda: "openai")
    monkeypatch.setattr(
        chat, "_openai_compatible_stream",
        lambda *_args, **_kwargs: iter([
            "111,111원과 555,555원을 쓰면 888,888원이 남아요."
        ]),
    )
    result = chat.chat_reply(plan, "얼마 남아?", card, upcoming, app)
    assert result.source == "openai->template(ungrounded)"
    assert result.blocked_numbers == (111_111, 555_555, 888_888)
    streamed = "".join(chat.chat_stream(plan, "얼마 남아?", card, upcoming, app))
    assert "111,111원" not in streamed


def test_external_chat_history_is_user_or_assistant_and_identifier_redacted():
    messages = chat._conversation(
        "내 이름은 김성제, 010-1234-5678로 연락해",
        [ChatHistoryItem(role="assistant", content="지민 결혼식은 확인했어요")],
        external=True,
    )
    assert [m["role"] for m in messages] == ["assistant", "user"]
    text = " ".join(m["content"] for m in messages)
    assert "김성제" not in text and "지민" not in text and "010-1234-5678" not in text


def test_external_openai_payload_contains_only_structured_user_intent(monkeypatch):
    """실제 OpenAI 전송 바디에 질문·이력·일정 제목 원문이 없어야 한다."""
    plan, app, card, _upcoming = _chat_context()
    canary = "김민수랑 헬스"
    upcoming = [UpcomingEvent(
        day=40, title=canary, amount=20_000, category="여가",
    )]
    captured = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def raise_for_status(self):
            return None

        def iter_lines(self):
            return iter(["data: [DONE]"])

    def fake_stream(_method, _url, **kwargs):
        captured.update(kwargs["json"])
        return FakeResponse()

    monkeypatch.setattr("httpx.stream", fake_stream)
    list(chat._openai_compatible_stream(
        "openai",
        plan,
        f"{canary} 갈래, 2만원 정도",
        card,
        upcoming,
        app,
        [
            ChatHistoryItem(role="user", content=f"예전에도 {canary} 3만원"),
            ChatHistoryItem(role="assistant", content=f"{canary} 일정을 확인했어요"),
        ],
    ))

    outbound = str(captured)
    assert canary not in outbound
    assert "김민수" not in outbound
    assert "금융 의도:" in outbound
    assert "지출 유형: 여가" in outbound
    assert "명시 금액: 20,000원" in outbound
    system = captured["messages"][0]["content"]
    assert "8/9 여가 20,000원" in system
    assert canary not in system


# ---------- 지난 소비 열람 (자유 대화의 근거) ----------

def _past_events():
    return [
        UpcomingEvent(day=3, amount=12_000, category="카페"),
        UpcomingEvent(day=11, amount=8_000, category="카페"),
        UpcomingEvent(day=14, amount=45_000, category="외식"),
    ]


def test_past_spending_reaches_the_prompt_with_category_totals():
    """Phase 1 — "카페에 얼마 썼어?"에 답하려면 지난 소비가 프롬프트에 있어야 한다."""
    plan = build_plan(PROFILE, 22)
    system = prompts.chat_system(plan, past=_past_events())
    assert "[지난 소비]" in system
    assert "7/3 카페 12,000원" in system
    # 모델이 직접 더하지 않아도 되도록 합계를 미리 준다.
    assert "카페 20,000원" in system
    assert "이미 쓴 지출 합계: 65,000원" in system


def test_past_spending_prompt_carries_no_titles():
    """제목은 지난 소비라고 덜 민감하지 않다 — 날짜·유형·금액만 나간다."""
    plan = build_plan(PROFILE, 22)
    past = [UpcomingEvent(day=3, amount=12_000, category="카페", title="김성제 소개팅")]
    system = prompts.chat_system(plan, past=past)
    assert "소개팅" not in system and "김성제" not in system


def test_grounding_rule_allows_deriving_numbers_from_given_data():
    """Phase 1 — '계산 금지'는 자유 대화와 정면 충돌한다. 근거 있는 계산은 허용."""
    assert "계산 금지" not in prompts.GROUNDING_RULE
    assert "만들어내지 마라" in prompts.GROUNDING_RULE


def test_category_total_is_quotable(monkeypatch):
    """Phase 2 — 우리가 시킨 덧셈의 결과가 '지어낸 숫자'로 판정되면 안 된다."""
    plan = build_plan(PROFILE, 22)
    allowed = chat.allowed_chat_numbers(plan, past=_past_events())
    assert 20_000 in allowed          # 카페 12,000 + 8,000
    assert 65_000 in allowed          # 전체 합계
    assert 12_000 in allowed and 45_000 in allowed


def test_rounded_wording_is_grounded_but_invented_number_is_not():
    """Phase 2 — '약 12만원'은 반올림이고, 125,000원은 지어낸 값이다."""
    allowed = groundedness.expand_roundings({118_500})
    assert groundedness.check("약 12만원이에요", allowed)[0]
    assert not groundedness.check("125,000원이에요", allowed)[0]


def test_annotate_marks_only_the_ungrounded_number():
    """Phase 3 — 표시는 문제 숫자에만 붙는다."""
    text, bad = groundedness.annotate("77,777원 남았고 999,999원이 필요해요", {77_777})
    assert bad == [999_999]
    assert "999,999원 (확인 필요)" in text
    assert "77,777원 남았고" in text


def test_openai_uses_max_completion_tokens_and_local_keeps_max_tokens(monkeypatch):
    """최신 OpenAI 모델은 max_tokens 를 400으로 거절한다 — 백엔드별로 이름이 다르다."""
    sent = {}

    class _Resp:
        status_code = 200
        def raise_for_status(self): pass
        def json(self): return {"choices": [{"message": {"content": '{"ok": 1}'}}]}

    def _capture(url, headers=None, timeout=None, json=None):
        sent.update(json)
        return _Resp()

    monkeypatch.setattr("httpx.post", _capture)

    monkeypatch.setattr(config, "llm_backend", lambda: "openai")
    complete_json("ping", max_tokens=42)
    assert sent["max_completion_tokens"] == 42 and "max_tokens" not in sent

    sent.clear()
    monkeypatch.setattr(config, "llm_backend", lambda: "local")
    complete_json("ping", max_tokens=42)
    assert sent["max_tokens"] == 42 and "max_completion_tokens" not in sent
