"""평가 통합 — 골든(엔진 정합성) + groundedness(LLM 정확도)."""
from __future__ import annotations

from ..data import PROFILE
from ..engine import build_plan
from ..models import EvalResult
from . import groundedness
from .golden import run_golden


def run_eval() -> EvalResult:
    # 실제 /api/chat 과 같은 생성·검증·폴백 경로를 평가한다.
    from ..llm.chat import allowed_chat_numbers, chat_reply

    passed, total, details = run_golden()

    grounded = 0
    g_total = 0
    for d in ("reduce", "maintain", "increase"):
        plan = build_plan(PROFILE.model_copy(update={"direction": d}), today=21)
        result = chat_reply(plan, "이번 주 소비 계획과 적금 목표를 짧게 알려줘")
        ok, bad = groundedness.check(result.text, allowed_chat_numbers(plan))
        # 차단 후 템플릿은 안전하지만, 원 모델이 허위 숫자를 냈다면 모델 접지 점수에는
        # 실패로 기록한다. 안전 폴백과 모델 품질을 같은 100%로 포장하지 않는다.
        model_grounded = ok and not result.blocked_numbers
        g_total += 1
        grounded += int(model_grounded)
        blocked = (f" · 모델 차단 숫자={list(result.blocked_numbers)}"
                   if result.blocked_numbers else "")
        details.append(
            f"[{'OK' if model_grounded else 'FAIL'}] groundedness/chat/{d} "
            f"(실제 응답 소스={result.source})"
            + ("" if ok else f" ungrounded={bad}")
            + blocked
        )

    rate = round(grounded / g_total, 3) if g_total else 0.0
    return EvalResult(
        engine_tests_passed=passed,
        engine_tests_total=total,
        groundedness_rate=rate,
        details=details,
    )
