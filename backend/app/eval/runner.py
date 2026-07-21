"""평가 통합 — 골든(엔진 정합성) + groundedness(LLM 정확도)."""
from __future__ import annotations

from ..data import PROFILE
from ..engine import build_plan
from ..models import EvalResult
from . import groundedness
from .golden import run_golden


def run_eval() -> EvalResult:
    from ..llm.coach import coach  # 지연 임포트(anthropic 선택적)

    passed, total, details = run_golden()

    grounded = 0
    g_total = 0
    for d in ("reduce", "maintain", "increase"):
        plan = build_plan(PROFILE.model_copy(update={"direction": d}), today=21)
        c = coach(plan)
        text = " ".join([c.headline, c.reason, c.impact, c.recommendation])
        ok, bad = groundedness.check(text, set(plan.grounded_numbers))
        g_total += 1
        grounded += int(ok)
        src = "LLM" if c.used_llm else "템플릿"
        details.append(f"[{'OK' if ok else 'FAIL'}] groundedness/{d} ({src})"
                       + ("" if ok else f" ungrounded={bad}"))

    rate = round(grounded / g_total, 3) if g_total else 0.0
    return EvalResult(
        engine_tests_passed=passed,
        engine_tests_total=total,
        groundedness_rate=rate,
        details=details,
    )
