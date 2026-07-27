"""LLM 프롬프트 — 엔진 숫자에 '접지(grounding)'된 코칭.

핵심: LLM은 계산하지 않는다. 엔진이 준 숫자만 인용해 '설명·판단·문장'만 만든다.
"""
from __future__ import annotations

from ..models import PlanResult

STYLE = """너는 사회초년생·대학생을 위한 소비 코치 'KB Tune 에이전트'다.
원칙:
- 결론부터 짧게 말한다.
- 금지("쓰지 마세요")보다 대안("이걸 옮기면")을 먼저 제시한다.
- 지키기로 한 소비(보호 소비)는 건드리지 않는다.
- 확정 보장 표현을 쓰지 않는다. 확률은 현재 계획 기준 '시뮬레이션'이다.
- 사용자를 평가하거나 소비를 도덕적으로 훈계하지 않는다.
"""

GROUNDING_RULE = """[매우 중요] 아래 '계획 수치'에 있는 숫자만 사용하라.
새로운 금액·확률을 절대 만들어내지 마라(계산 금지). 수치가 필요하면 목록의 값을 그대로 인용하라."""


def _facts(plan: PlanResult, app=None) -> str:
    # 앱이 이미 화면에 띄운 값이 있으면 그쪽이 단일 진실 — 백엔드 재계산과 어긋나면 안 된다.
    weekly = app.weekly_available if app else plan.weekly_available
    prob = app.probability if app else plan.probability
    remaining = app.remaining_budget if app else plan.remaining_budget
    spent = app.spent_to_date if app else plan.variable_spent_to_date
    carry = app.installment_carryover if app else 0
    remaining_note = (
        f"(가처분 {plan.disposable_month:,} − 지금까지 {spent:,} − 할부 이월 {carry:,})"
        if carry else f"(가처분 {plan.disposable_month:,} − 지금까지 {spent:,})"
    )
    lines = [
        f"- 이번 주 사용 가능액: {weekly:,}원",
        f"- 적금 목표 달성 확률: {prob}%",
        f"- 이번 달 저축 목표: {plan.savings_goal:,}원",
        f"- 이번 달 남은 예산: {remaining:,}원 {remaining_note}",
        f"- 7월 일정 예상액: {plan.month_estimate_low:,}~{plan.month_estimate_high:,}원",
        f"- 월말 여유 예상: {plan.month_end_remaining_low:,}~{plan.month_end_remaining_high:,}원",
        f"- 예상 근거: {plan.estimate_basis}",
        f"- 이번 달 소비 방향: {plan.direction}",
        f"- 보호 소비: {plan.protected_summary}",
        f"- 가장 큰 소비 카테고리: {plan.analysis.top_category}",
    ]
    if plan.analysis.anomalies:
        lines.append("- 급증 신호: " + "; ".join(plan.analysis.anomalies))
    if plan.risk.has_risk:
        lines.append(f"- 위험 일정: {plan.risk.summary}")
    if plan.adjustments:
        lines.append("- 가능한 조정안:")
        for a in plan.adjustments:
            lines.append(f"    · {a.title} → 사용가능액 {a.weekly_available:,}원 · 확률 {a.probability}%")
    allowed = set(plan.grounded_numbers) | {weekly, remaining, spent}
    if carry:
        allowed.add(carry)
    lines.append(f"- (인용 허용 숫자: {', '.join(f'{n:,}' for n in sorted(allowed))})")
    return "\n".join(lines)


def coach_system(plan: PlanResult) -> str:
    return f"{STYLE}\n\n{GROUNDING_RULE}\n\n[계획 수치]\n{_facts(plan)}"


def coach_user(plan: PlanResult) -> str:
    if plan.risk.has_risk:
        return "위 계획을 바탕으로, 이번 주에 주의할 일정과 지킬 수 있는 방법을 코칭해줘."
    return "위 계획을 바탕으로 이번 주 소비 코칭을 해줘."


def _card_facts(card, upcoming) -> str:
    """카드 청구와 앞으로의 일정 — 엔진의 월 예산 계산에는 들어가지 않는 별도 사실."""
    lines: list[str] = []
    if card and card.due_next:
        lines.append(
            f"- 다음 카드 결제일: {card.pay_label} (D-{card.days_until_pay}) · "
            f"빠질 금액 {card.due_next:,}원"
        )
        lines.append(f"- 이번 이용기간 이용금액: {card.usage:,}원")
        if card.carryover:
            lines.append(
                f"- 할부로 {card.next_pay_label}에 넘어가는 금액: {card.carryover:,}원 "
                "(이번 달 소비에는 안 잡혔지만 다음 달 카드값에 자동으로 얹힘)"
            )
        if card.days_until_close == 0:
            lines.append(
                f"- 오늘이 이용기간 마지막 날({card.close_label}). "
                f"오늘 쓰면 {card.pay_label}에, 내일 쓰면 {card.next_pay_label}에 빠져나감"
            )
        elif card.days_until_close > 0:
            lines.append(
                f"- 이용기간 마감까지 {card.days_until_close}일 "
                f"({card.close_label}까지 쓴 돈이 {card.pay_label}에 한 번에 빠짐)"
            )
    if upcoming:
        lines.append("- 오늘 이후 잡혀 있는 지출 일정:")
        for e in upcoming:
            lines.append(f"    · 7/{e.day} {e.title} {e.amount:,}원 ({e.category})")
        lines.append(f"    합계 {sum(e.amount for e in upcoming):,}원")
    return "\n".join(lines)


def chat_system(plan: PlanResult, card=None, upcoming=None, app=None) -> str:
    extra = _card_facts(card, upcoming or [])
    return (
        f"{STYLE}\n\n{GROUNDING_RULE}\n\n"
        "사용자의 질문에 대해 (1)결론 (2)이유(반영한 데이터) (3)영향(전/후 숫자) (4)행동 제안 순서로 "
        "간결하게 답한다. 표나 목록을 남발하지 말고 대화체로.\n"
        "지출을 물어보면 이번 주 예산만 보지 말고, 다음 카드 결제일에 빠질 금액과 "
        "앞으로 잡혀 있는 일정까지 함께 놓고 답한다.\n\n"
        f"[계획 수치]\n{_facts(plan, app)}"
        + (f"\n\n[카드 청구·앞으로의 일정]\n{extra}" if extra else "")
    )
