"""코칭 생성 — 엔진 PlanResult → 접지된 자연어 코칭.

모델을 쓰는 백엔드(claude·openai·local)면 LLM + groundedness 검증, offline이면 결정론적 템플릿.
LLM이 화이트리스트 밖 숫자를 만들면 자동으로 템플릿으로 폴백한다.

코칭은 카드 한 장을 채우는 짧은 글이라 접지를 엄격하게 둔다 — 대화(chat)처럼
문제 숫자에만 표시를 붙이지 않고, 하나라도 어긋나면 통째로 템플릿으로 바꾼다.
"""
from __future__ import annotations

import logging

from pydantic import BaseModel

from .. import config
from ..eval import groundedness
from ..models import CoachResponse, Direction, PlanResult
from . import prompts
from .complete import complete_json

logger = logging.getLogger("kbtune.llm")


class _CoachLLM(BaseModel):
    """LLM이 채우는 필드(숫자 whitelist 인용만)."""
    direction: Direction
    headline: str
    reason: str
    impact: str
    recommendation: str


_JSON_FORMAT = (
    "아래 형식의 JSON 객체 하나만 출력한다. 설명도 코드블록도 붙이지 않는다.\n"
    '{"direction": "reduce 또는 maintain 또는 increase", "headline": "...", '
    '"reason": "...", "impact": "...", "recommendation": "..."}'
)


def coach(plan: PlanResult) -> CoachResponse:
    """모델을 쓰는 백엔드면 어디서든 LLM 코칭. offline 이면 결정론 템플릿.

    예전에는 Claude 일 때만 LLM 을 붙였다. 백엔드를 openai 로 돌린 동안 코칭만
    조용히 템플릿으로 떨어져, 매번 같은 문장이 나오는데 이유가 드러나지 않았다.
    호출 방식 차이는 complete_json 이 이미 흡수한다(외부 전송 시 비식별화 포함).
    """
    if not config.llm_enabled():
        return _template(plan, used_llm=False)

    data = complete_json(
        f"{prompts.coach_system(plan)}\n\n{prompts.coach_user(plan)}\n\n{_JSON_FORMAT}",
        max_tokens=800,
    )
    if not isinstance(data, dict):
        logger.info("coach backend=%s: no JSON object -> template", config.llm_backend())
        return _template(plan, used_llm=False)
    try:
        out = _CoachLLM.model_validate(data)
    except Exception as exc:
        logger.info("coach backend=%s: %s -> template", config.llm_backend(), type(exc).__name__)
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
        headline = f"이번 주에는 약 {plan.weekly_available:,}원까지 쓸 수 있어요."
        reason = f"7월 캘린더의 확정 일정과 ‘{plan.protected_summary}’ 원칙을 반영했어요."
        impact = f"적금 목표 달성 확률은 {plan.probability}%예요."
        recommendation = "금액이 비어 있는 일정만 확인하면 예상 범위를 더 좁힐 수 있어요."
    return CoachResponse(
        direction=plan.direction, headline=headline, reason=reason,
        impact=impact, recommendation=recommendation,
        grounded=grounded, used_llm=used_llm,
    )
