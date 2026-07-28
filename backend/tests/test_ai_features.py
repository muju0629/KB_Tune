"""AI 기능 4종 회귀 테스트 — 전부 키/네트워크 없이 결정론 경로로 검증."""
from collections import Counter

from app import config
from app.data import PROFILE, TRANSACTIONS_HISTORY
from app.engine import build_plan
from app.engine.budget import disposable_month
from app.engine.categorize import categorize_many, categorize_rule
from app.engine.estimate import estimate_event_cost
from app.engine.forecast import detect_patterns, forecast_next_month
from app.eval.runner import run_eval
from app.eval import groundedness
from app.llm import chat, coach, prompts
from app.llm.complete import _first_json_object, complete_json
from app.llm.extract import extract_from_text
from app.models import AppNumbers, CardBilling, ChatHistoryItem, UpcomingEvent


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


def test_categorize_uses_shared_llm_json_array(monkeypatch):
    monkeypatch.setattr(
        "app.llm.complete.complete_json",
        lambda *_args, **_kwargs: [{"id": 0, "category": "여가"}],
    )
    results, _ = categorize_many(["미지상점"], use_llm=True)
    assert results[0].category == "여가"
    assert results[0].method == "llm"


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


def test_forecast_excludes_single_occurrence_categories():
    counts = Counter(t.category for t in TRANSACTIONS_HISTORY)
    one_off_categories = {category for category, count in counts.items() if count == 1}
    f = forecast_next_month(TRANSACTIONS_HISTORY, disposable_month(PROFILE))

    assert one_off_categories
    assert one_off_categories.isdisjoint(f.by_category)
    assert all(pattern.occurrences >= 2 for pattern in f.patterns)


def test_forecast_is_deterministic():
    a = forecast_next_month(TRANSACTIONS_HISTORY, 1_220_000)
    b = forecast_next_month(TRANSACTIONS_HISTORY, 1_220_000)
    assert a.predicted_total == b.predicted_total


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
        chat, "_openai_stream",
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
        chat, "_openai_stream",
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
        chat, "_openai_stream",
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
    list(chat._openai_stream(
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


def test_eval_uses_configured_chat_path_and_reports_block(monkeypatch):
    monkeypatch.setattr(config, "llm_backend", lambda: "openai")
    monkeypatch.setattr(
        chat, "_openai_stream",
        lambda *_args, **_kwargs: iter(["근거에 없는 999,999원을 써도 돼요."]),
    )
    result = run_eval()
    assert result.groundedness_rate == 0.0
    chat_details = [d for d in result.details if "groundedness/chat" in d]
    assert len(chat_details) == 3
    # 표시를 붙여 내보냈어도 모델 접지 점수는 실패다 — 안전 폴백과 모델 품질을 섞지 않는다.
    assert all("모델 차단 숫자=[999999]" in d for d in chat_details)
    assert all("[FAIL]" in d for d in chat_details)
    assert all("모델 차단 숫자=[999999]" in d for d in chat_details)


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


def test_coach_uses_llm_on_any_model_backend(monkeypatch):
    """Phase 4 — claude 전용 게이트 때문에 openai 에서 코칭만 템플릿으로 떨어졌다."""
    plan = build_plan(PROFILE, 22)
    monkeypatch.setattr(config, "llm_backend", lambda: "openai")
    monkeypatch.setattr(coach, "complete_json", lambda *_a, **_k: {
        "direction": "maintain",
        "headline": f"이번 주에는 {plan.weekly_available:,}원까지 쓸 수 있어요.",
        "reason": "확정 일정을 반영했어요.",
        "impact": f"적금 목표 확률은 {plan.probability}%예요.",
        "recommendation": "금액이 빈 일정만 채워 주세요.",
    })
    out = coach.coach(plan)
    assert out.used_llm and out.grounded


def test_coach_falls_back_to_template_when_offline(monkeypatch):
    plan = build_plan(PROFILE, 22)
    monkeypatch.setattr(config, "llm_backend", lambda: "offline")
    assert coach.coach(plan).used_llm is False


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
