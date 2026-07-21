"""소비 분석 — 카테고리별 월평균·비중, 이상 급증 탐지. (결정론적)"""
from __future__ import annotations

from ..data import HISTORY_MONTHLY, TRANSACTIONS_THIS_MONTH
from ..models import CategoryStat, SpendingAnalysis, Transaction


def analyze(history: dict[str, int] | None = None,
            txns: list[Transaction] | None = None) -> SpendingAnalysis:
    history = history or HISTORY_MONTHLY
    txns = txns if txns is not None else TRANSACTIONS_THIS_MONTH

    total = sum(history.values())
    cats = [
        CategoryStat(name=k, monthly_avg=v, share=round(v / total, 3))
        for k, v in sorted(history.items(), key=lambda x: -x[1])
    ]

    # 이번 달 카테고리별 누적
    month: dict[str, int] = {}
    for t in txns:
        month[t.category] = month.get(t.category, 0) + t.amount

    anomalies: list[str] = []
    for cat, spent in month.items():
        hist = history.get(cat)
        if hist and spent >= hist * 0.9:  # 20일 만에 월평균의 90%↑ → 급증
            anomalies.append(f"{cat}이(가) 20일 만에 월평균 {hist:,}원의 {round(spent/hist*100)}%에 도달했어요")

    return SpendingAnalysis(
        period="2026.04~06",
        monthly_variable_avg=total,
        categories=cats,
        top_category=cats[0].name,
        anomalies=anomalies,
    )
