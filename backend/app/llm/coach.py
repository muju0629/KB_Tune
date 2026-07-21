"""코칭 생성 — 엔진 PlanResult → 접지된 자연어 코칭.

키가 있으면 Claude(구조화 출력) + groundedness 검증, 없으면 결정론적 템플릿.
LLM이 화이트리스트 밖 숫자를 만들면 자동으로 템플릿으로 폴백한다.
"""
from __future__ import annotations

from pydantic import BaseModel

from .. import config
from ..eval import groundedness
from ..models import CoachResponse, Direction, PlanResult
from . import prompts


class _CoachLLM(BaseModel):
    """LLM이 채우는 필드(숫자 whitelist 인용만)."""
    direction: Direction
    headline: str
    reason: str
    impact: str
    recommendation: str


def coach(plan: PlanResult) -> CoachResponse:
    # 구조화 코칭은 Claude일 때만 LLM 사용, 그 외(offline/local)는 결정론 템플릿.
    if config.llm_backend() != "claude":
        return _template(plan, used_llm=False)

    try:
        import anthropic
        client = anthropic.Anthropic()
        resp = client.messages.parse(
            model=config.CLAUDE_MODEL,
            max_tokens=1024,
            system=prompts.coach_system(plan),
            messages=[{"role": "user", "content": prompts.coach_user(plan)}],
            output_format=_CoachLLM,
        )
        out = resp.parsed_output
    except Exception:
        # API 오류/네트워크 → 안전하게 템플릿
        return _template(plan, used_llm=False)

    text = " ".join([out.headline, out.reason, out.impact, out.recommendation])
    grounded, _bad = groundedness.check(text, set(plan.grounded_numbers))
    if not grounded:
        # LLM이 숫자를 지어냄 → 템플릿으로 폴백(정확도 보증)
        return _template(plan, used_llm=True, grounded=False)

    return CoachResponse(
        direction=out.direction, headline=out.headline, reason=out.reason,
        impact=out.impact, recommendation=out.recommendation,
        grounded=True, used_llm=True,
    )


def _template(plan: PlanResult, used_llm: bool, grounded: bool = True) -> CoachResponse:
    """오프라인/폴백용 결정론적 코칭 — 엔진 숫자만 사용."""
    if plan.risk.has_risk:
        r = plan.risk
        move = next((a for a in plan.adjustments if a.id == "move"), None)
        headline = f"‘{r.event_title}’은 조정을 추천해요."
        reason = f"이번 달 {plan.analysis.top_category} 지출이 커진 상태예요. 지키기로 한 {plan.protected_summary}는 그대로 두었어요."
        impact = r.summary or ""
        recommendation = (
            f"{move.title}(사용가능액 {move.weekly_available:,}원 · 확률 {move.probability}%)면 계획을 지킬 수 있어요."
            if move else "조정안을 비교해 보세요."
        )
    else:
        headline = f"이번 주 {plan.weekly_available:,}원까지 괜찮아요."
        reason = f"최근 3개월 소비와 {plan.protected_summary}를 반영했어요."
        impact = f"적금 목표 달성 확률은 {plan.probability}%예요."
        recommendation = "지금 계획대로 두면 목표를 지킬 수 있어요."
    return CoachResponse(
        direction=plan.direction, headline=headline, reason=reason,
        impact=impact, recommendation=recommendation,
        grounded=grounded, used_llm=used_llm,
    )
