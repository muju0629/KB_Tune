"""1~8주 회귀 모델 비교 결과를 발표용 16:9 PNG/SVG로 만든다."""
from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib import font_manager
import pandas as pd


HERE = Path(__file__).parent
RESULTS = HERE / "results/model_comparison_8week"
FIG = RESULTS / "figures"
FONT_DIR = HERE.parents[1] / "KB_Tune/Fonts"

INK = "#25241F"
MUTED = "#747168"
LINE = "#E6E2D8"
CANVAS = "#FBFAF7"
YELLOW = "#FFCC00"
VIOLET = "#7A5CF0"
INFO = "#2A72E5"
GRAY = "#BDB9AF"
LIGHT = font_manager.FontProperties(fname=FONT_DIR / "KBFGText-Light.otf")
MEDIUM = font_manager.FontProperties(fname=FONT_DIR / "KBFGText-Medium.otf")


LABEL = {
    "최근 평균 + 캘린더": "최근 평균",
    "Ridge": "Ridge",
    "Random Forest": "Random Forest",
    "LightGBM": "LightGBM",
    "KB Tune Bayesian": "Renewal Bayesian",
}


def canvas(title: str, subtitle: str):
    fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=CANVAS)
    fig.text(0.06, 0.91, title, fontproperties=MEDIUM, fontsize=25, color=INK)
    fig.text(0.06, 0.865, subtitle, fontproperties=LIGHT, fontsize=11.5, color=MUTED)
    return fig


def save(fig, stem: str) -> None:
    FIG.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG / f"{stem}.png", dpi=144, facecolor=CANVAS)
    fig.savefig(FIG / f"{stem}.svg", facecolor=CANVAS)
    plt.close(fig)


def ranking(df: pd.DataFrame) -> None:
    selected = list(LABEL)
    d = (df[(df.사용주차 == 8) & df.모델.isin(selected)]
         .assign(표시=lambda x: x.모델.map(LABEL))
         .sort_values("WAPE", ascending=True))
    fig = canvas(
        "같은 데이터를 줬을 때, LightGBM이 가장 정확했다",
        "8주 개인 이력 · 모든 모델에 동일한 카드·카테고리·경과일·캘린더 피처 제공 · 낮을수록 정확",
    )
    ax = fig.add_axes([0.20, 0.16, 0.67, 0.64])
    colors = [YELLOW if m == "LightGBM" else VIOLET if m == "KB Tune Bayesian" else GRAY
              for m in d.모델]
    edge = ["#C69E00" if m == "LightGBM" else VIOLET if m == "KB Tune Bayesian" else "#A6A197"
            for m in d.모델]
    bars = ax.barh(d.표시, d.WAPE * 100, color=colors, edgecolor=edge,
                   linewidth=1, height=0.60)
    ax.invert_yaxis()
    ax.set_xlim(0, 54)
    ax.set_xlabel("다음 주 총소비 WAPE", fontproperties=LIGHT, fontsize=11,
                  color=MUTED, labelpad=12)
    ax.grid(axis="x", color=LINE, linewidth=0.9)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(axis="x", colors=MUTED, labelsize=9.5)
    ax.tick_params(axis="y", colors=INK, labelsize=12)
    for label in ax.get_yticklabels():
        label.set_fontproperties(MEDIUM)
    for bar, value, model in zip(bars, d.WAPE * 100, d.모델):
        ax.text(value + 0.7, bar.get_y() + bar.get_height()/2, f"{value:.1f}%",
                va="center", fontproperties=MEDIUM, fontsize=12, color=INK)
        if model == "LightGBM":
            ax.text(value * 0.52, bar.get_y() + bar.get_height()/2, "점예측 최종 후보",
                    ha="center", va="center", fontproperties=MEDIUM, fontsize=10.5, color=INK)
    fig.text(0.06, 0.07,
             "결론: 순수 Bayesian 모델의 점예측 우위는 기각 · Bayesian은 발생확률과 예측구간 역할로 분리",
             fontproperties=LIGHT, fontsize=10, color=MUTED)
    save(fig, "01_model_ranking_8week")


def curve(df: pd.DataFrame) -> None:
    models = ["최근 평균 + 캘린더", "Ridge", "Random Forest", "LightGBM", "KB Tune Bayesian"]
    style = {
        "최근 평균 + 캘린더": (GRAY, ":", "o", 2.0),
        "Ridge": (INFO, "--", "s", 2.0),
        "Random Forest": ("#6F8B75", "-.", "^", 2.0),
        "LightGBM": (YELLOW, "-", "o", 3.3),
        "KB Tune Bayesian": (VIOLET, "--", "D", 2.3),
    }
    fig = canvas(
        "첫 주에 대부분의 성능을 확보하고, 8주 동안 완만하게 개인화된다",
        "WAPE 기반 정확도(1 - WAPE) · 인구 학습 300명 / 별도 평가 100명 × 미래 20주",
    )
    ax = fig.add_axes([0.08, 0.17, 0.84, 0.63])
    for model in models:
        g = df[df.모델 == model].sort_values("사용주차")
        color, line, marker, width = style[model]
        ax.plot(g.사용주차, g.WAPE기반정확도 * 100, label=LABEL[model],
                color=color, linestyle=line, marker=marker, linewidth=width,
                markersize=6, markeredgecolor=INK if model == "LightGBM" else color,
                markeredgewidth=0.8)
    ax.set_xlim(0.8, 8.2)
    ax.set_ylim(34, 64)
    ax.set_xticks(range(1, 9))
    ax.set_xlabel("개인 이력 축적 기간(주)", fontproperties=LIGHT, fontsize=11,
                  color=MUTED, labelpad=12)
    ax.set_ylabel("WAPE 기반 정확도", fontproperties=LIGHT, fontsize=11,
                  color=MUTED, labelpad=12)
    ax.grid(axis="y", color=LINE, linewidth=0.9)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(colors=MUTED, labelsize=9.5)
    ax.legend(loc="lower right", ncol=2, frameon=False, prop=MEDIUM, fontsize=9.5)
    lgb = df[df.모델 == "LightGBM"].sort_values("사용주차")
    ax.text(1, lgb.iloc[0].WAPE기반정확도*100 + 1.0,
            f"{lgb.iloc[0].WAPE기반정확도*100:.1f}%", ha="center",
            fontproperties=MEDIUM, fontsize=10, color=INK)
    ax.text(8, lgb.iloc[-1].WAPE기반정확도*100 + 1.0,
            f"{lgb.iloc[-1].WAPE기반정확도*100:.1f}%", ha="center",
            fontproperties=MEDIUM, fontsize=10, color=INK)
    fig.text(0.08, 0.07,
             "가파른 상승은 최근 평균 기준선에서만 나타남 · 글로벌 회귀는 첫 주부터 인구 패턴을 사용해 변화폭이 작음",
             fontproperties=LIGHT, fontsize=10, color=MUTED)
    save(fig, "02_learning_curve_1_to_8")


def main() -> None:
    df = pd.read_csv(RESULTS / "results.csv")
    ranking(df)
    curve(df)
    print(FIG)


if __name__ == "__main__":
    main()
