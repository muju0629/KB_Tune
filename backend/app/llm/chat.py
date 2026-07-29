"""챗봇 스트리밍 — 계획을 바꾸는 대화. 엔진 숫자에 접지.

LLM_BACKEND 에 따라:
  offline → 결정론 템플릿을 청크로 스트리밍 (비용 0)
  local   → 로컬 오픈소스 모델(OpenAI 호환) 스트리밍 (비용 0)
  openai  → OpenAI 스트리밍 (유료, 선택)
어떤 경우든 실패하면 템플릿으로 폴백. 모델 출력은 버퍼에서 숫자를 검증한 뒤 전송한다.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Iterator

from .. import config
from ..eval import groundedness
from ..models import ChatHistoryItem, PlanResult
from ..security import financial_intent_text, redact_personal_data, safe_text
from . import prompts

# 개인정보는 전부 요청 본문에 있고 본문은 절대 로그에 넣지 않는다.
# 여기 남기는 건 '어느 백엔드가 왜 실패했는지'뿐이다(docs/security.md §8).
logger = logging.getLogger("kbtune.llm")

# 근거 없는 숫자가 이보다 많으면 답변 대부분이 지어낸 것이다. 표시를 붙여 보여주는 것보다
# 템플릿으로 갈아끼우는 쪽이 안전하다.
MAX_ANNOTATED = 3


@dataclass(frozen=True)
class ChatResult:
    text: str
    source: str
    blocked_numbers: tuple[int, ...] = ()


def _event_numbers(events, allowed: set[int]) -> None:
    """일정 목록에서 인용 가능한 숫자를 모은다 — 개별 금액·날짜·유형별 합계·전체 합계.

    합계를 미리 넣어두는 이유: 모델이 "카페에 20,000원 썼어요"라고 답하려면 그 20,000이
    명단에 있어야 하는데, 개별 금액만 넣으면 우리가 프롬프트로 시킨 덧셈의 결과가
    전부 '지어낸 숫자'로 판정된다.
    """
    by_category: dict[str, int] = {}
    for event in events:
        allowed.update((event.day, event.amount))
        month, day = (7, event.day) if event.day <= 31 else (8, event.day - 31)
        allowed.update((month, day))
        by_category[event.category] = by_category.get(event.category, 0) + event.amount
    allowed.update(by_category.values())
    allowed.add(sum(e.amount for e in events))


def allowed_chat_numbers(plan: PlanResult, card=None, upcoming=None, app=None,
                         past=None) -> set[int]:
    """대화에 인용해도 되는 엔진·앱·청구·일정 숫자의 합집합."""
    allowed = set(plan.grounded_numbers)
    allowed.add(plan.remaining_weeks)

    if app:
        for name in ("weekly_available", "probability", "remaining_budget",
                     "spent_to_date", "installment_carryover", "month_end_remaining"):
            value = getattr(app, name, None)
            if isinstance(value, int) and not isinstance(value, bool):
                allowed.add(value)

    if card:
        for name in ("due_next", "usage", "carryover", "days_until_pay", "days_until_close"):
            value = getattr(card, name, None)
            if isinstance(value, int) and not isinstance(value, bool):
                allowed.add(value)
        for label in (card.pay_label, card.next_pay_label, card.close_label):
            allowed.update(int(n) for n in re.findall(r"\d+", label or ""))

    if upcoming:
        _event_numbers(upcoming, allowed)
    if past:
        _event_numbers(past, allowed)
    # 지난 소비와 앞으로의 일정을 합쳐 묻는 질문("이번 달 카페에 얼마 쓰게 돼?")도 있다.
    if upcoming and past:
        _event_numbers(list(past) + list(upcoming), allowed)

    return allowed


def chat_reply(plan: PlanResult, message: str, card=None, upcoming=None, app=None,
               history: list[ChatHistoryItem] | None = None, past=None) -> ChatResult:
    """모델 응답을 전부 검증한 뒤 안전한 문자열만 반환한다.

    토큰을 즉시 사용자에게 내보내면 마지막 토큰에서 발견된 허위 금액을 되돌릴 수 없다.
    그래서 모델 출력은 서버 안에서 잠깐 버퍼링하고, 검증을 통과한 뒤에만 스트림에 싣는다.

    검증에 걸린 숫자가 몇 개 안 되면 답변을 버리지 않고 그 숫자에만 표시를 붙인다.
    맞는 문장 세 개가 틀린 숫자 하나 때문에 같이 사라지지 않게. 다만 표시를 붙였다는
    사실은 blocked_numbers 에 그대로 남겨, 평가에서는 여전히 모델 실패로 집계된다.
    """
    backend = config.llm_backend()
    if backend == "offline":
        return ChatResult(_template_reply(plan, message, card, app), "offline-template")

    try:
        # openai · local — 같은 OpenAI 호환 스키마
        chunks = _openai_compatible_stream(
            backend, plan, message, card, upcoming, app, history, past)
        text = "".join(chunks).strip()
        if not text:
            raise ValueError("empty model response")
    except Exception as exc:
        status = getattr(getattr(exc, "response", None), "status_code", None)
        logger.warning("chat backend=%s failed: %s%s", backend, type(exc).__name__,
                       f" status={status}" if status else "")
        return ChatResult(_template_reply(plan, message, card, app), f"{backend}->template(error)")

    allowed = groundedness.expand_roundings(
        allowed_chat_numbers(plan, card, upcoming, app, past)
    )
    ok, bad = groundedness.check(text, allowed)
    if ok:
        return ChatResult(text, backend)

    if len(bad) >= MAX_ANNOTATED:
        logger.info("chat backend=%s ungrounded=%d -> template", backend, len(bad))
        return ChatResult(
            _template_reply(plan, message, card, app),
            f"{backend}->template(ungrounded)",
            tuple(bad),
        )

    marked, _bad = groundedness.annotate(text, allowed)
    logger.info("chat backend=%s ungrounded=%d -> annotated", backend, len(bad))
    return ChatResult(marked, f"{backend}(annotated)", tuple(bad))


def chat_stream(plan: PlanResult, message: str, card=None, upcoming=None, app=None,
                history: list[ChatHistoryItem] | None = None, past=None) -> Iterator[str]:
    result = chat_reply(plan, message, card, upcoming, app, history, past)
    # 검증은 이미 끝났다. 기존 text/plain 스트리밍 계약과 점진 표시를 유지한다.
    for chunk in re.findall(r"\S+\s*", result.text):
        yield chunk


def _conversation(message: str, history: list[ChatHistoryItem] | None,
                  external: bool) -> list[dict[str, str]]:
    messages: list[dict[str, str]] = []
    for item in history or []:
        role = item.role if hasattr(item, "role") else item["role"]
        content = item.content if hasattr(item, "content") else item["content"]
        if external:
            # 외부 모델에는 user 원문을 보내지 않는다. 이름을 '가리는' 규칙은
            # 누락될 수 있지만, 코드가 정한 금융 의도로 바꾸면 원문이 경계를 넘지 않는다.
            content = (financial_intent_text(content) if role == "user"
                       else redact_personal_data(safe_text(content, 600), 600))
        else:
            content = safe_text(content, 600)
        messages.append({"role": role, "content": content})
    current = financial_intent_text(message) if external else safe_text(message, 2_000)
    messages.append({"role": "user", "content": current})
    return messages


def _system(plan: PlanResult, card=None, upcoming=None, app=None, *, external: bool,
            past=None) -> str:
    """외부 모델에는 일정의 day/category/amount만 보낸다."""
    system = prompts.chat_system(
        plan, card, upcoming, app, include_upcoming_titles=not external, past=past,
    )
    return redact_personal_data(system) if external else system


def _sse_deltas(response) -> Iterator[str]:
    """OpenAI 호환 스트리밍 응답에서 본문 조각만 뽑는다."""
    for line in response.iter_lines():
        if not line or not line.startswith("data:"):
            continue
        data = line[len("data:"):].strip()
        if data == "[DONE]":
            break
        try:
            delta = json.loads(data)["choices"][0]["delta"].get("content")
        except Exception:
            continue
        if delta:
            yield delta


def _openai_compatible_stream(backend: str, plan: PlanResult, message: str, card=None,
                              upcoming=None, app=None, history=None,
                              past=None) -> Iterator[str]:
    """/v1/chat/completions 스트리밍 — openai 와 local(Bonsai·Ollama·llama.cpp) 공용.

    두 백엔드는 같은 스키마를 쓴다. 갈리는 건 주소·인증 헤더·모델 이름과, 로컬 서버가
    요구하는 max_tokens 뿐이다. 예전에는 함수를 따로 뒀는데, 한쪽만 고치는 일이 반복됐다.
    """
    import httpx
    if backend == "openai":
        base, model = config.OPENAI_BASE_URL, config.OPENAI_MODEL
        headers = {"Authorization": f"Bearer {config.openai_key()}"}
        limits, external = {}, True
    else:
        base, model = config.LOCAL_LLM_BASE_URL, config.LOCAL_LLM_MODEL
        headers = {}
        limits, external = {"max_tokens": 512}, config.llm_is_external("local")

    payload = {
        "model": model,
        "stream": True,
        **limits,
        "messages": [
            {"role": "system", "content": _system(
                plan, card, upcoming, app, external=external, past=past)},
            *_conversation(message, history, external=external),
        ],
    }
    with httpx.stream("POST", base.rstrip("/") + "/chat/completions",
                      json=payload, headers=headers, timeout=60) as r:
        r.raise_for_status()
        yield from _sse_deltas(r)


# ---------- 오프라인 템플릿(비용 0) ----------

def _template_reply(plan: PlanResult, message: str, card=None, app=None) -> str:
    # 앱이 화면에 띄운 값이 오면 그쪽을 쓴다 — 폴백이라고 다른 숫자를 말하면 안 된다.
    weekly = app.weekly_available if app else plan.weekly_available
    prob = app.probability if app else plan.probability
    remaining = app.remaining_budget if app else plan.remaining_budget
    q = message.replace(" ", "")
    if card and card.due_next and any(k in q for k in ("카드", "카드값", "청구", "할부", "결제일")):
        return (f"{card.pay_label}에 {card.due_next:,}원이 빠져나가요. "
                f"이번 이용기간에 {card.usage:,}원을 썼고, 그중 {card.carryover:,}원은 할부라 "
                f"{card.next_pay_label}로 넘어가요.")
    if any(k in q for k in ("출근", "점심", "교통", "인턴")):
        return (f"이번 주 남은 확정 일정비는 {plan.committed_this_week:,}원이에요. "
                f"출근일의 점심과 이동비를 포함한 예상이라 실제 결제액에 따라 달라질 수 있어요.")
    if any(k in q for k in ("레이저", "제모", "예상범위")):
        return (f"이번 달 일정 예상액은 {plan.month_estimate_low:,}~{plan.month_estimate_high:,}원으로 보여요. "
                "레이저 제모가 선결제인지 확인하면 범위를 더 좁힐 수 있어요.")
    if any(k in q for k in ("데이트", "가족")):
        return (f"{plan.protected_summary}으로 두었어요. 확정 일정을 반영하고도 이번 주에는 "
                f"약 {weekly:,}원까지 쓸 수 있어요.")
    if any(k in q for k in ("적금", "목표", "저축")):
        return (f"지금 계획대로면 목표 확률은 {prob}%예요. "
                f"이번 달 남은 예산은 {remaining:,}원이에요.")
    return (f"이번 주에는 약 {weekly:,}원까지 쓸 수 있어요. "
            f"이번 달 일정 예상액은 {plan.month_estimate_low:,}~{plan.month_estimate_high:,}원으로 예상해요. "
            "확인하고 싶은 일정을 말해 주세요.")
