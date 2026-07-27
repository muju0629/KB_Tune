"""챗봇 스트리밍 — 계획을 바꾸는 대화. 엔진 숫자에 접지.

LLM_BACKEND 에 따라:
  offline → 결정론 템플릿을 청크로 스트리밍 (비용 0)
  local   → 로컬 오픈소스 모델(OpenAI 호환) 스트리밍 (비용 0)
  claude  → Anthropic 스트리밍 (유료, 선택)
어떤 경우든 실패하면 템플릿으로 폴백.
"""
from __future__ import annotations

import json
from typing import Iterator

from .. import config
from ..models import PlanResult
from . import prompts


def chat_stream(plan: PlanResult, message: str, card=None, upcoming=None, app=None) -> Iterator[str]:
    backend = config.llm_backend()
    try:
        if backend == "claude":
            yield from _claude_stream(plan, message, card, upcoming, app)
            return
        if backend == "local":
            yield from _local_stream(plan, message, card, upcoming, app)
            return
        if backend == "openai":
            yield from _openai_stream(plan, message, card, upcoming, app)
            return
    except Exception:
        pass  # 어떤 실패든 템플릿으로
    yield from _template_stream(plan, message, card, app)


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


def _openai_stream(plan: PlanResult, message: str, card=None, upcoming=None, app=None) -> Iterator[str]:
    """OpenAI /v1/chat/completions 스트리밍. 로컬 서버와 응답 형식이 같아 파싱을 공유한다."""
    import httpx
    url = config.OPENAI_BASE_URL.rstrip("/") + "/chat/completions"
    payload = {
        "model": config.OPENAI_MODEL,
        "stream": True,
        "messages": [
            {"role": "system", "content": prompts.chat_system(plan, card, upcoming, app)},
            {"role": "user", "content": message},
        ],
    }
    headers = {"Authorization": f"Bearer {config.openai_key()}"}
    with httpx.stream("POST", url, json=payload, headers=headers, timeout=60) as r:
        r.raise_for_status()
        yield from _sse_deltas(r)


def _claude_stream(plan: PlanResult, message: str, card=None, upcoming=None, app=None) -> Iterator[str]:
    import anthropic
    client = anthropic.Anthropic()
    with client.messages.stream(
        model=config.CLAUDE_MODEL, max_tokens=1024,
        system=prompts.chat_system(plan, card, upcoming, app),
        messages=[{"role": "user", "content": message}],
    ) as stream:
        for text in stream.text_stream:
            yield text


def _local_stream(plan: PlanResult, message: str, card=None, upcoming=None, app=None) -> Iterator[str]:
    """OpenAI 호환 로컬 서버(/v1/chat/completions) 스트리밍. Bonsai/Ollama/llama.cpp 공용."""
    import httpx
    url = config.LOCAL_LLM_BASE_URL.rstrip("/") + "/chat/completions"
    payload = {
        "model": config.LOCAL_LLM_MODEL,
        "stream": True,
        "max_tokens": 512,
        "messages": [
            {"role": "system", "content": prompts.chat_system(plan, card, upcoming, app)},
            {"role": "user", "content": message},
        ],
    }
    with httpx.stream("POST", url, json=payload, timeout=60) as r:
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
        return (f"7월 일정비는 {plan.month_estimate_low:,}~{plan.month_estimate_high:,}원으로 보여요. "
                "레이저 제모가 선결제인지 확인하면 범위를 더 좁힐 수 있어요.")
    if any(k in q for k in ("데이트", "가족")):
        return (f"{plan.protected_summary}으로 두었어요. 확정 일정을 반영하고도 이번 주에는 "
                f"약 {weekly:,}원까지 쓸 수 있어요.")
    if any(k in q for k in ("적금", "목표", "저축")):
        return (f"지금 계획대로면 목표 확률은 {prob}%예요. "
                f"이번 달 남은 예산은 {remaining:,}원이에요.")
    return (f"이번 주에는 약 {weekly:,}원까지 쓸 수 있어요. "
            f"7월 일정비는 {plan.month_estimate_low:,}~{plan.month_estimate_high:,}원으로 예상해요. "
            "확인하고 싶은 일정을 말해 주세요.")


def _template_stream(plan: PlanResult, message: str, card=None, app=None) -> Iterator[str]:
    for token in _template_reply(plan, message, card, app).split(" "):
        yield token + " "
