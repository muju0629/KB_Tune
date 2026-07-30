"""카드+캘린더 벤치마크를 발표용 16:9 PNG/SVG로 만든다."""
from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
import numpy as np
import pandas as pd


HERE = Path(__file__).parent
RESULTS = HERE / "results/card_calendar"
FIG = RESULTS / "figures"
FONT_DIR = HERE.parents[1] / "KB_Tune/Fonts"

INK = "#25241F"
MUTED = "#747168"
LINE = "#E6E2D8"
CANVAS = "#FBFAF7"
SURFACE = "#FFFFFF"
YELLOW = "#FFCC00"
YELLOW_SOFT = "#FFF7CF"
VIOLET = "#7A5CF0"
INFO = "#2A72E5"
GREEN = "#3F8A55"


def fonts() -> tuple[font_manager.FontProperties, font_manager.FontProperties]:
    light = font_manager.FontProperties(fname=FONT_DIR / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=FONT_DIR / "KBFGText-Medium.otf")
    return light, medium


LIGHT, MEDIUM = fonts()


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


def performance() -> None:
    df = pd.read_csv(RESULTS / "results.csv")
    occ = pd.read_csv(RESULTS / "occurrence_results.csv")
    fig = canvas(
        "캘린더를 더하자, 예측 오차가 가장 크게 줄었다",
        "카드 결제만 사용 · 인구 사전 300명 / 별도 평가 100명 × 20주 · 합성 데이터",
    )

    ax = fig.add_axes([0.16, 0.17, 0.47, 0.61])
    labels = ["최근 8주 평균", "개인 발생×금액", "+ 캘린더"]
    values = df.WAPE.to_numpy() * 100
    colors = ["#C8C4BA", VIOLET, YELLOW]
    bars = ax.barh(np.arange(3), values, color=colors, height=0.56,
                   edgecolor=["#AAA59A", VIOLET, "#D2A900"], linewidth=1)
    ax.invert_yaxis()
    ax.set_yticks(np.arange(3), labels, fontproperties=MEDIUM, fontsize=13, color=INK)
    ax.set_xlim(0, 52)
    ax.set_xlabel("주간 WAPE · 낮을수록 정확", fontproperties=LIGHT, fontsize=10.5,
                  color=MUTED, labelpad=12)
    ax.grid(axis="x", color=LINE, linewidth=0.8)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(axis="x", colors=MUTED, labelsize=9)
    for bar, value in zip(bars, values):
        ax.text(value + 0.7, bar.get_y() + bar.get_height()/2, f"{value:.1f}%",
                va="center", fontproperties=MEDIUM, fontsize=12, color=INK)

    ax.text(27, 1, "개인화로 3.1% 개선", ha="center", va="center",
            fontproperties=MEDIUM, fontsize=10.5, color=SURFACE)
    ax.text(25, 2, "캘린더로 추가 9.7% 개선", ha="center", va="center",
            fontproperties=MEDIUM, fontsize=10.5, color=INK)

    card = fig.add_axes([0.69, 0.18, 0.25, 0.59])
    card.axis("off")
    card.add_patch(FancyBboxPatch((0, 0), 1, 1, boxstyle="round,pad=0.025,rounding_size=0.05",
                                  facecolor=SURFACE, edgecolor=LINE, linewidth=1.1))
    card.text(0.09, 0.88, "발생 예측", fontproperties=MEDIUM, fontsize=15, color=INK)
    precision = float(occ.iloc[2]["정밀도@0.6"]) * 100
    recall = float(occ.iloc[2]["재현율@0.6"]) * 100
    coverage = float(df.iloc[2]["커버리지80"]) * 100
    metrics = [("정밀도", precision, "헛제안 감소"),
               ("재현율", recall, "놓치는 소비 감소"),
               ("80% 구간", coverage, "실제 포함률")]
    for i, (label, value, note) in enumerate(metrics):
        y = 0.69 - i * 0.24
        card.text(0.09, y + 0.10, label, fontproperties=LIGHT, fontsize=10.5, color=MUTED)
        card.text(0.09, y, f"{value:.1f}%", fontproperties=MEDIUM, fontsize=23, color=INK)
        card.text(0.09, y - 0.07, note, fontproperties=LIGHT, fontsize=9.5, color=MUTED)
    fig.text(0.06, 0.07, "주: 합성 데이터의 구조 검증 결과이며 실사용자 성능을 의미하지 않음",
             fontproperties=LIGHT, fontsize=9.5, color=MUTED)
    save(fig, "01_model_performance")


def learning_curve() -> None:
    df = pd.read_csv(RESULTS / "learning_curve.csv")
    fig = canvas(
        "첫 주부터 쓸 수 있고, 사용할수록 나에게 가까워진다",
        "예측 정확도 = 1 - WAPE · 같은 평가 사용자 100명의 미래 20주 반복 측정",
    )
    ax = fig.add_axes([0.08, 0.18, 0.84, 0.61])
    series = [
        ("R1 개인 발생×금액", "카드 이력만", VIOLET, "--", "o"),
        ("R2 + 캘린더", "카드 + 캘린더", YELLOW, "-", "o"),
    ]
    for key, label, color, style, marker in series:
        g = df[df.모델 == key].sort_values("사용주차")
        ax.plot(g.사용주차, g.WAPE기반정확도 * 100, label=label, color=color,
                linewidth=3, linestyle=style, marker=marker, markersize=6,
                markeredgecolor=INK if color == YELLOW else color,
                markeredgewidth=0.8)
        first, last = g.iloc[0], g.iloc[-1]
        ax.text(first.사용주차, first.WAPE기반정확도 * 100 - 1.6,
                f"{first.WAPE기반정확도*100:.1f}%", ha="center",
                fontproperties=MEDIUM, fontsize=9.5, color=color if color != YELLOW else INK)
        ax.text(last.사용주차 + 0.5, last.WAPE기반정확도 * 100,
                f"{last.WAPE기반정확도*100:.1f}%", va="center",
                fontproperties=MEDIUM, fontsize=10.5, color=color if color != YELLOW else INK)

    ax.set_xlim(0, 34.5)
    ax.set_ylim(47, 63)
    ax.set_xticks([1, 2, 4, 6, 8, 12, 16, 20, 26, 32])
    ax.set_xlabel("앱 사용 및 개인 이력 축적 기간(주)", fontproperties=LIGHT,
                  fontsize=11, color=MUTED, labelpad=12)
    ax.set_ylabel("WAPE 기반 예측 정확도", fontproperties=LIGHT,
                  fontsize=11, color=MUTED, labelpad=12)
    ax.grid(axis="y", color=LINE, linewidth=0.9)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(colors=MUTED, labelsize=9.5)
    ax.legend(loc="lower right", frameon=False, prop=MEDIUM, fontsize=10.5)
    ax.axvspan(0.5, 1.5, color=YELLOW_SOFT, alpha=0.85, zorder=-1)
    ax.text(1, 62.2, "첫 주", ha="center", fontproperties=MEDIUM, fontsize=9.5, color=INK)
    fig.text(0.08, 0.08,
             "카드 결제는 자동 학습하고, 일정 추가·취소·금액 수정은 미래 의도로 반영",
             fontproperties=LIGHT, fontsize=10, color=MUTED)
    save(fig, "02_learning_curve")


def _box(ax, x, y, w, h, title, body, face, edge=LINE):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                               boxstyle="round,pad=0.014,rounding_size=0.025",
                               facecolor=face, edgecolor=edge, linewidth=1.2))
    ax.text(x + 0.04*w, y + h*0.67, title, fontproperties=MEDIUM,
            fontsize=13, color=INK, va="center")
    ax.text(x + 0.04*w, y + h*0.31, body, fontproperties=LIGHT,
            fontsize=9.5, color=MUTED, va="center", linespacing=1.35)


def _arrow(ax, start, end, color=INK, rad=0):
    ax.add_patch(FancyArrowPatch(start, end, arrowstyle="-|>", mutation_scale=15,
                                linewidth=1.6, color=color,
                                connectionstyle=f"arc3,rad={rad}"))


def feedback_loop() -> None:
    fig = canvas(
        "예측은 폰 안에서 닫힌 학습 루프로 완성된다",
        "현금 확인 없이 카드 결제와 캘린더 행동만 사용 · 일정 제목 원문은 외부 전송하지 않음",
    )
    ax = fig.add_axes([0.05, 0.10, 0.90, 0.72])
    ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")

    _box(ax, 0.03, 0.57, 0.22, 0.22, "① 카드 결제", "발생일 · 금액 · 카테고리\n실제 소비의 정답", SURFACE)
    _box(ax, 0.03, 0.18, 0.22, 0.22, "② 캘린더 행동", "일정 추가 · 취소 · 이동\n예상 금액 수정", YELLOW_SOFT, "#D9B000")
    _box(ax, 0.38, 0.37, 0.25, 0.27, "③ 온디바이스 개인 모델",
         "발생 확률 · 반복 주기\n개인 금액 분포 · 최근 변화", "#F0ECFF", VIOLET)
    _box(ax, 0.75, 0.37, 0.22, 0.27, "④ 다음 주 예측",
         "예상 총액과 80% 범위\n예산 초과 확률 · 예측 근거", SURFACE, INFO)

    _arrow(ax, (0.25, 0.68), (0.38, 0.56), VIOLET)
    _arrow(ax, (0.25, 0.29), (0.38, 0.44), "#C49B00")
    _arrow(ax, (0.63, 0.505), (0.75, 0.505), INFO)
    _arrow(ax, (0.86, 0.37), (0.24, 0.57), MUTED, rad=-0.47)
    ax.text(0.61, 0.08, "예측 이후 실제 결제가 다시 학습 데이터가 됨",
            fontproperties=LIGHT, fontsize=9.5, color=MUTED, ha="center")

    ax.add_patch(FancyBboxPatch((0.38, 0.21), 0.25, 0.09,
                                boxstyle="round,pad=0.012,rounding_size=0.02",
                                facecolor=INK, edgecolor=INK))
    ax.text(0.505, 0.255, "민감정보 서버 전송 0건",
            fontproperties=MEDIUM, fontsize=11.5, color=CANVAS, ha="center", va="center")
    save(fig, "03_feedback_loop")


def write_notes() -> None:
    text = """# 발표용 시각자료

## 01_model_performance

- 질문: 개인화와 캘린더가 주간 예측을 얼마나 개선하는가
- 핵심: 캘린더 결합이 개인 모델 대비 WAPE 9.7% 개선
- 출처: `results.csv`, `occurrence_results.csv`

## 02_learning_curve

- 질문: 첫 주부터 장기 사용까지 예측 성능이 어떻게 변하는가
- 핵심: 카드+캘린더 모델의 WAPE 기반 정확도가 1주 57.8%에서 32주 60%대로 상승
- 출처: `learning_curve.csv`
- 주의: 합성 데이터 시뮬레이션이며 실사용자 성능으로 표현하지 않는다

## 03_feedback_loop

- 질문: 어떤 데이터가 어디에서 개인 모델을 갱신하는가
- 핵심: 카드 결제와 캘린더 행동만 사용하며 기기 안에서 학습 루프가 닫힌다
"""
    (RESULTS / "FIGURES.md").write_text(text, encoding="utf-8")


def main() -> None:
    performance()
    learning_curve()
    feedback_loop()
    write_notes()
    print(FIG)


if __name__ == "__main__":
    main()
