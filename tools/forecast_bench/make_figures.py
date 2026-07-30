"""PPT 용 figure 생성. results.csv 를 읽어 그리고, 재계산하지 않는다.

    python make_figures.py     → results/fig/*.png

색은 눈으로 고르지 않고 dataviz 검증기를 통과한 조합만 쓴다.
대비 3:1 미만인 색(#eda100)에는 반드시 직접 레이블을 붙인다 — relief 규칙.
"""
from __future__ import annotations

from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

import features
import mpp

HERE = Path(__file__).parent
OUT = HERE / "results/fig"

# 앱 디자인 토큰 + dataviz 검증 통과 색
SURFACE, INK, INK2, MUTED = "#FBFAF7", "#25241F", "#52514E", "#898781"
GRID, BASELINE = "#E1E0D9", "#C3C2B7"
EMPH = "#eda100"        # 우리 모델 (대비 2.07 → 직접 레이블 필수)
CONTEXT = "#C3C2B7"     # 비교군 (강조 대비용, 카테고리 색 아님)
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"   # 3계열 all-pairs 통과
RED = "#e34948"

OURS = ("R5", "R6", "R7")     # 우리 안 — 강조 대상

plt.rcParams.update({
    "font.family": "Apple SD Gothic Neo",
    "axes.unicode_minus": False,
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "text.color": INK,
    "axes.labelcolor": INK2,
    "xtick.color": MUTED,
    "ytick.color": INK2,
    "axes.edgecolor": BASELINE,
    "font.size": 12,
})


def _frame(ax, xgrid=True):
    """축은 물러나게. 데이터가 주인공이다."""
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.spines["left"].set_color(BASELINE)
    ax.spines["bottom"].set_color(BASELINE)
    ax.grid(axis="x" if xgrid else "y", color=GRID, lw=0.8, zorder=0)
    ax.set_axisbelow(True)


def _save(fig, name: str):
    OUT.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT / name, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  {OUT/name}")


def _short(label: str) -> str:
    return label.replace("  ", " ").strip()


def fig_wape(res: pd.DataFrame):
    """모델별 총액 WAPE. 우리 안을 강조하고 나머지는 물러나게 (emphasis form)."""
    d = res.sort_values("WAPE", ascending=False).reset_index(drop=True)
    colors = [EMPH if _short(m).startswith(OURS) else CONTEXT for m in d["모델"]]

    fig, ax = plt.subplots(figsize=(10, 6))
    top = 0.21
    shown = np.minimum(d.WAPE, top)          # 선형회귀 0.60 이 축을 삼키지 않게
    bars = ax.barh(range(len(d)), shown, color=colors, height=0.68,
                   edgecolor=SURFACE, lw=2, zorder=2)
    r0 = float(d.loc[d["모델"].str.strip().str.startswith("R0"), "WAPE"].iloc[0])
    ax.axvline(r0, color=RED, lw=2, ls="--", zorder=3)
    ax.text(r0, len(d) - 0.3, f"  현재 방식 {r0:.3f}", color=RED, fontsize=11, va="center")

    for i, (b, v) in enumerate(zip(bars, d.WAPE)):
        clipped = v > top
        ax.text(min(v, top) + 0.002, i, f"{v:.3f}" + (" →" if clipped else ""),
                va="center", fontsize=11,
                color=INK if colors[i] == EMPH else INK2,
                fontweight="bold" if colors[i] == EMPH else "normal")

    ax.set_yticks(range(len(d)), [_short(m) for m in d["모델"]], fontsize=11)
    ax.set_xlim(0, top + 0.022)
    ax.set_xlabel("WAPE — 가중절대오차율 (낮을수록 정확)")
    ax.set_title("모델별 예측 정확도 · 노란색이 우리 안\n"
                 "AI Hub 카드 승인매출 5,000명 · 다음 달 총 이용금액",
                 fontsize=14, loc="left", pad=14)
    _frame(ax)
    fig.text(0.5, -0.035,
             "→ 표시는 축을 넘는 값(실제 수치 표기). 선형 회귀는 log 예측이 expm1 에서 증폭돼 발산한다.",
             fontsize=9.5, color=MUTED, ha="center")
    _save(fig, "1_wape.png")


def fig_coverage(res: pd.DataFrame):
    """80% 구간이 실제로 80%를 덮는가. 목표에서의 편차를 발산 막대로."""
    d = res.copy()
    d["dev"] = d["커버리지80"] - 0.80
    d = d.sort_values("dev").reset_index(drop=True)
    colors = [BLUE if v > 0 else RED for v in d.dev]

    fig, ax = plt.subplots(figsize=(10, 6))
    ax.barh(range(len(d)), d.dev * 100, color=colors, height=0.68,
            edgecolor=SURFACE, lw=2, zorder=2)
    ax.axvline(0, color=INK, lw=2, zorder=3)

    for i, (v, cov) in enumerate(zip(d.dev, d["커버리지80"])):
        off = 1.2 if v >= 0 else -1.2
        ax.text(v * 100 + off, i, f"{cov:.0%}", va="center",
                ha="left" if v >= 0 else "right", fontsize=11, color=INK2)

    ax.set_yticks(range(len(d)), [_short(m) for m in d["모델"]], fontsize=11)
    ax.set_xlabel("목표 80%에서의 편차 (%p) — 0 에 가까울수록 정직하다")
    ax.set_title("구간 신뢰도 캘리브레이션 · 0 이 정답\n"
                 "왼쪽(빨강)은 과대 확신, 오른쪽(파랑)은 과대 보수",
                 fontsize=14, loc="left", pad=14)
    _frame(ax)
    lo, hi = d.dev.min() * 100, d.dev.max() * 100
    ax.set_xlim(lo - 8, hi + 8)
    _save(fig, "2_coverage.png")


def fig_change(res: pd.DataFrame):
    """수준을 제거하면 모델이 갈리는가. naive(=1.0) 대비 변화량 WAPE."""
    d = res.sort_values("변화WAPE", ascending=False).reset_index(drop=True)
    colors = [EMPH if _short(m).startswith(OURS) else CONTEXT for m in d["모델"]]

    fig, ax = plt.subplots(figsize=(10, 6))
    top = 1.5
    for i, (v, c) in enumerate(zip(d["변화WAPE"], colors)):
        x = min(v, top)
        ax.plot([1.0, x], [i, i], color=c, lw=3, zorder=2, solid_capstyle="round")
        ax.plot(x, i, "o", ms=10, color=c, zorder=3,
                markeredgecolor=SURFACE, markeredgewidth=2)
        ax.text(x + 0.02 if v >= 1 else x - 0.02, i,
                f"{v:.3f}" + (" →" if v > top else ""),
                va="center", ha="left" if v >= 1 else "right", fontsize=11,
                color=INK if c == EMPH else INK2,
                fontweight="bold" if c == EMPH else "normal")

    ax.axvline(1.0, color=INK, lw=2, zorder=4)
    ax.text(1.0, len(d) - 0.4, "  직전 달 복사 = 1.0", color=INK, fontsize=11, va="center")
    ax.set_yticks(range(len(d)), [_short(m) for m in d["모델"]], fontsize=11)
    ax.set_xlim(0.9, top + 0.12)
    ax.set_xlabel("변화량 WAPE — 1.0 미만이면 직전 달 복사보다 나음")
    ax.set_title("수준을 제거하면 모델이 갈리는가 · 최고가 2.3% 개선\n"
                 "이 데이터는 직전 달이 다음 달의 R²=0.958 을 설명한다",
                 fontsize=14, loc="left", pad=14)
    _frame(ax)
    _save(fig, "3_change.png")


def fig_detection():
    """습관이 바뀔 때 몇 주 만에 따라오는가. 3계열 그룹 막대."""
    p = mpp.Prior(a=2.0, b=30.0, mu0=np.log(10_000), tau2=0.25, sigma2=0.25)
    scenarios = [("금주\n(0.5 → 0.05건/일)", 0.5, 0.05),
                 ("카페 시작\n(0.1 → 1.0건/일)", 0.1, 1.0)]
    series = [("누적만 (망각 없음)", CONTEXT), ("단일 망각", ORANGE), ("이중 추정 (우리 안)", BLUE)]

    vals = []
    for _, before, after in scenarios:
        vals.append([mpp._lag_single(p, before, after, 1.0),
                     mpp._lag_single(p, before, after, 0.85),
                     mpp._lag_tracker(p, before, after)[0]])
    vals = np.array(vals, float)

    fig, ax = plt.subplots(figsize=(10, 5.5))
    x, w = np.arange(len(scenarios)), 0.26
    for j, (label, color) in enumerate(series):
        pos = x + (j - 1) * w
        ax.bar(pos, vals[:, j], w * 0.92, label=label, color=color,
               edgecolor=SURFACE, lw=2, zorder=2)
        for xi, v in zip(pos, vals[:, j]):
            ax.text(xi, v + 1.2, f"{v:.0f}주", ha="center", fontsize=11, color=INK2)

    ax.set_xticks(x, [s[0] for s in scenarios], fontsize=12)
    ax.set_ylabel("감지까지 걸린 주 수 (낮을수록 좋음)")
    ax.set_ylim(0, vals.max() + 9)
    ax.set_title("습관이 바뀔 때 얼마나 빨리 알아채나\n"
                 "누적만 하면 금주를 14개월간 못 알아챈다 · 거짓경보 0회",
                 fontsize=14, loc="left", pad=14)
    ax.legend(frameon=False, loc="upper right", fontsize=11)
    _frame(ax, xgrid=False)
    _save(fig, "4_detection.png")


def fig_sigma():
    """σ 를 상수로 두면 월초와 월말의 불확실성이 같아진다."""
    import sys
    sys.path.insert(0, str(HERE.parent.parent / "backend"))
    from app.data import DAYS_IN_MONTH, UPCOMING_EVENTS
    from app.engine.probability import spend_sigma

    days = [(1, "월초\n31일 남음"), (8, "1주차\n24일"), (15, "월중\n17일"),
            (22, "3주차\n10일"), (29, "월말\n3일")]
    vals = [spend_sigma(UPCOMING_EVENTS, d, DAYS_IN_MONTH, "maintain", False)
            for d, _ in days]

    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.bar(range(len(days)), vals, 0.6, color=EMPH, edgecolor=SURFACE, lw=2, zorder=2)
    for i, v in enumerate(vals):
        ax.text(i, v + 6_000, f"{v/10_000:.1f}만", ha="center", fontsize=12,
                color=INK, fontweight="bold")

    ax.axhline(100_000, color=RED, lw=2, ls="--", zorder=3)
    ax.text(len(days) - 0.4, 108_000, "옛 고정값 10만원", color=RED, fontsize=11, ha="right")

    ax.set_xticks(range(len(days)), [d[1] for d in days], fontsize=11)
    ax.set_ylabel("남은 지출의 표준편차 σ (원)")
    ax.set_yticks([0, 100_000, 200_000], ["0", "10만", "20만"])
    ax.set_ylim(0, max(vals) * 1.18)
    ax.set_title("σ 하드코딩 제거 · 불확실성이 남은 일수에 반응한다\n"
                 "고정 10만원은 월초에 2.4배 과소, 월말에 3.8배 과대였다",
                 fontsize=14, loc="left", pad=14)
    _frame(ax, xgrid=False)
    _save(fig, "5_sigma.png")


def fig_autocorr():
    """이 벤치마크가 모델을 구분하지 못하는 이유를 한 장으로."""
    raw = features.clip_spending(pd.read_parquet(HERE / "data/monthly.parquet"))
    d = features.build(raw)
    x = d["X_te"]["lag1"].to_numpy(float) / 10_000
    y = d["y_te"].to_numpy(float) / 10_000
    r = np.corrcoef(x, y)[0, 1]

    fig, ax = plt.subplots(figsize=(7.4, 6.6))
    ax.scatter(x, y, s=9, color=BLUE, alpha=0.22, linewidths=0, zorder=2)
    lim = np.percentile(np.concatenate([x, y]), 99.5)
    ax.plot([0, lim], [0, lim], color=INK, lw=1.6, ls="--", zorder=3)
    ax.set_xlim(0, lim); ax.set_ylim(0, lim)
    ax.set_aspect("equal")      # 축 비율을 맞춰야 45° 레이블이 대각선과 평행해진다
    ax.text(lim * 0.52, lim * 0.44, "직전 달 = 다음 달", color=INK2, fontsize=11, rotation=45)
    ax.set_xlabel("직전 달 이용금액 (만원)")
    ax.set_ylabel("다음 달 이용금액 (만원)")
    ax.set_title(f"직전 달이 다음 달의 {r**2:.1%}를 설명한다  (R² = {r**2:.3f})\n"
                 "그래서 어떤 모델도 유의하게 이기기 어렵다",
                 fontsize=14, loc="left", pad=14)
    _frame(ax)
    ax.grid(axis="y", color=GRID, lw=0.8, zorder=0)
    _save(fig, "6_autocorr.png")


def fig_coldstart():
    """주차별 오차 곡선. 쓸수록 개인 분포로 갱신되는가 — coldstart.csv 를 읽는다."""
    path = HERE / "results/coldstart.csv"
    if not path.exists():
        print("  coldstart.png 건너뜀 (python coldstart.py 를 먼저 돌린다)")
        return
    c = pd.read_csv(path)
    piv = c.pivot(index="week", columns="arm", values="wape")

    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    _frame(ax, xgrid=False)
    ax.plot(piv.index, piv["prior"], color=CONTEXT, lw=2, zorder=2)
    ax.plot(piv.index, piv["hier"], color=EMPH, lw=2.6, zorder=4)

    # 도달 가능한 하한. 사전분포 없이 개인 관측만 쓴 갈래의 후반 수준이다.
    floor = piv["personal"].iloc[-8:].mean()
    ax.axhline(floor, color=MUTED, lw=1, ls=(0, (4, 3)), zorder=1)

    # EMPH 는 대비 2.07 이라 범례로 못 쓴다 — 직접 레이블을 붙인다
    ax.annotate("공개 통계만 (고정)", (piv.index[-1], piv["prior"].iloc[-1]),
                xytext=(-6, 9), textcoords="offset points",
                ha="right", color=INK2, fontsize=11)
    ax.annotate("개인 분포로 갱신", (piv.index[-1], piv["hier"].iloc[-1]),
                xytext=(-6, -20), textcoords="offset points",
                ha="right", color=INK, fontsize=11, fontweight="bold")
    ax.annotate("줄일 수 없는 잡음", (1.4, floor), xytext=(0, -17),
                textcoords="offset points", color=MUTED, fontsize=10)

    a, b = piv["hier"].iloc[0], piv["hier"].iloc[-1]
    ax.set_title(f"쓸수록 내 분포가 된다 — 주간 지출 오차 {(a-b)/a:.0%} 감소\n"
                 f"합성 300명 × 26주", fontsize=13, loc="left", pad=14)
    ax.set_xlabel("앱 사용 주차")
    ax.set_ylabel("주간 총액 WAPE")
    ax.set_ylim(0, max(piv["prior"].max(), a) * 1.15)
    ax.set_xticks([1, 4, 8, 12, 16, 20, 26])
    _save(fig, "coldstart.png")


def main():
    res = pd.read_csv(HERE / "results/results.csv")
    print("figure 생성:")
    fig_wape(res)
    fig_coverage(res)
    fig_change(res)
    fig_detection()
    fig_sigma()
    fig_autocorr()
    fig_coldstart()


if __name__ == "__main__":
    main()
