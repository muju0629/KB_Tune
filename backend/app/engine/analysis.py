"""캘린더 기반 7월 예상 지출을 카테고리별로 요약한다."""
from __future__ import annotations

from ..data import HISTORY_MONTHLY, TRANSACTIONS_THIS_MONTH, UPCOMING_EVENTS
from ..models import CategoryStat, SpendingAnalysis, Transaction


def analyze(history: dict[str, int] | None = None,
            txns: list[Transaction] | None = None) -> SpendingAnalysis:
    using_calendar_default = history is None
    history = dict(HISTORY_MONTHLY if history is None else history)
    txns = txns if txns is not None else TRANSACTIONS_THIS_MONTH

    if using_calendar_default:
        for event in UPCOMING_EVENTS:
            history[event.category] = history.get(event.category, 0) + event.amount

    total = sum(history.values())
    cats = [
        CategoryStat(name=k, monthly_avg=v, share=round(v / total, 3))
        for k, v in sorted(history.items(), key=lambda x: -x[1])
    ]

    anomalies = ["레이저 제모 결제 여부에 따라 7월 예상액이 50,000원 달라져요."]

    return SpendingAnalysis(
        period="2026.07 캘린더 예상",
        monthly_variable_avg=total,
        categories=cats,
        top_category=cats[0].name,
        anomalies=anomalies,
    )
