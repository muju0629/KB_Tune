"""편향 보정 중앙값, 위험 분위수, 온라인 conformal 구간의 신규 홀드아웃 검증."""
from __future__ import annotations

from collections import deque
from pathlib import Path
import json

import numpy as np
import pandas as pd

import active_feedback_bench as base
import personal_bayes_feedback_bench as generator
import risk_gated_personalization_12week as prior_experiment
from card_calendar_bench import FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE


HERE = Path(__file__).parent
OUT = HERE / "results/calibrated_risk_conformal_holdout"
CALIBRATION = HERE / "results/local_spend_profile/calibration.json"
APP_WEEKS = 12
TRAIN_PEOPLE = range(0, 240)
CALIBRATION_PEOPLE = range(240, N_PRIOR_PEOPLE)
QUANTILES = {"안전 q67": 2 / 3, "안전 q75": 3 / 4, "안전 q83": 5 / 6}
CONDITIONS = ["Ridge", "기존 LightGBM", "편향 보정 중앙값", *QUANTILES]
HOLDOUTS = [
    {"scenario": "기본", "seed": 20261221},
    {"scenario": "중간 생활변화", "seed": 20261222, "mid_drift": True},
    {"scenario": "금액 변동성", "seed": 20261223, "volatility": 0.35},
]


class QuantileModel:
    def __init__(self, alpha: float, seed: int):
        from lightgbm import LGBMRegressor

        self.model = LGBMRegressor(
            objective="quantile", alpha=alpha,
            n_estimators=260, learning_rate=0.04, num_leaves=24,
            min_child_samples=40, reg_lambda=1.5, verbose=-1,
            random_state=seed,
        )

    def fit(self, X, y):
        self.model.fit(X, y)

    def predict(self, X):
        return np.clip(self.model.predict(X), 0, None)


class OnlineConformal:
    """초기 보정 사용자 점수와 이전 평가 주차만 쓰는 ACI 형태의 구간."""

    def __init__(self, initial_scores, target_coverage=0.80):
        self.scores = deque(np.asarray(initial_scores, float).tolist(), maxlen=1600)
        self.target_coverage = target_coverage
        self.alpha = 1 - target_coverage

    def interval(self, prediction):
        quantile = float(np.quantile(self.scores, 1 - self.alpha, method="higher"))
        lower = np.maximum(0, prediction * (1 - quantile))
        upper = prediction * (1 + quantile)
        return lower, upper, quantile, self.alpha

    def update(self, actual, prediction, lower, upper):
        missed = ((actual < lower) | (actual > upper)).astype(float)
        miss_rate = float(missed.mean())
        target_alpha = 1 - self.target_coverage
        self.alpha = float(np.clip(
            self.alpha + 0.08 * (target_alpha - miss_rate), 0.03, 0.40,
        ))
        scores = np.abs(actual - prediction) / np.maximum(prediction, 1_000)
        self.scores.extend(np.clip(scores, 0, 5).tolist())


def set_seed(seed):
    generator.SEED = seed
    base.SEED = seed + 10_000
    generator.LIFESTYLE_GLOBAL_SD = 0.18
    generator.LIFESTYLE_CATEGORY_SD = 0.35
    generator.LIFESTYLE_OCCURRENCE_SD = 0.55


def total_by_person(meta, actual, prediction):
    group_columns = ["person", "week"] if meta.week.nunique() > 1 else ["person"]
    frame = meta[group_columns].copy()
    frame["actual"] = actual
    frame["prediction"] = prediction
    return frame.groupby(group_columns, as_index=False)[["actual", "prediction"]].sum()


def fit_seed_models(seed, X_train, y_train):
    models = {}
    for model in base.models(seed=seed):
        if model.name in ["Ridge", "LightGBM"]:
            model.fit(X_train, y_train)
            models[model.name] = model
    quantiles = {name: QuantileModel(alpha, seed) for name, alpha in QUANTILES.items()}
    for model in quantiles.values():
        model.fit(X_train, y_train)
    return models, quantiles


def run_seed(item):
    seed = int(item["seed"])
    set_seed(seed)
    calibration = json.loads(CALIBRATION.read_text(encoding="utf-8"))
    true_tx, calendar, _ = generator.generate_persistent(calibration)
    true_tx = prior_experiment.apply_scenario(true_tx, item)
    observed = base.add_observation_noise(true_tx)
    target_cat, _ = base.true_targets(true_tx)
    pop_amount, pop_occurrence = base.population_stats(true_tx)
    index = base.make_index(observed, calendar)

    X_train, _, y_train = base.build_rows(
        TRAIN_PEOPLE, range(base.HISTORY_WEEKS, FIRST_TEST_WEEK),
        index, target_cat, pop_amount, pop_occurrence,
    )
    models, quantiles = fit_seed_models(seed, X_train, y_train)

    # 전역 모델과 완전히 다른 60명의 마지막 8주로 편향 및 초기 구간을 보정한다.
    X_cal, meta_cal, y_cal = base.build_rows(
        CALIBRATION_PEOPLE, range(FIRST_TEST_WEEK - 8, FIRST_TEST_WEEK),
        index, target_cat, pop_amount, pop_occurrence,
    )
    p_cal, amount_cal = models["LightGBM"].predict(X_cal)
    raw_cal = p_cal * amount_cal
    cal_total = total_by_person(meta_cal.assign(block=meta_cal.week), y_cal, raw_cal)
    bias_factor = float(np.clip(cal_total.actual.sum() / max(cal_total.prediction.sum(), 1), 0.75, 1.35))
    calibrated_total = cal_total.prediction.to_numpy(float) * bias_factor
    initial_scores = (
        np.abs(cal_total.actual.to_numpy(float) - calibrated_total)
        / np.maximum(calibrated_total, 1_000)
    )
    conformal = OnlineConformal(initial_scores)

    prediction_rows, interval_rows = [], []
    for app_week in range(1, APP_WEEKS + 1):
        week = FIRST_TEST_WEEK + app_week - 1
        X, meta, actual = base.build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], index, target_cat,
            pop_amount, pop_occurrence,
        )
        ridge_p, ridge_amount = models["Ridge"].predict(X)
        lgbm_p, lgbm_amount = models["LightGBM"].predict(X)
        predictions = {
            "Ridge": ridge_p * ridge_amount,
            "기존 LightGBM": lgbm_p * lgbm_amount,
            "편향 보정 중앙값": lgbm_p * lgbm_amount * bias_factor,
        }
        predictions.update({name: model.predict(X) for name, model in quantiles.items()})

        for condition, prediction in predictions.items():
            total = total_by_person(meta, actual, prediction)
            for row in total.itertuples(index=False):
                prediction_rows.append({
                    "scenario": item["scenario"], "seed": seed,
                    "사용주차": app_week, "condition": condition,
                    "person": int(row.person), "actual": float(row.actual),
                    "prediction": float(row.prediction), "bias_factor": bias_factor,
                })

        central = total_by_person(meta, actual, predictions["편향 보정 중앙값"])
        y = central.actual.to_numpy(float)
        pred = central.prediction.to_numpy(float)
        lower, upper, q, alpha = conformal.interval(pred)
        covered = (y >= lower) & (y <= upper)
        interval_rows.append({
            "scenario": item["scenario"], "seed": seed, "사용주차": app_week,
            "coverage": float(covered.mean()),
            "normalized_width": float(np.mean(upper - lower) / max(np.mean(y), 1)),
            "score_quantile": q, "adaptive_alpha": alpha,
            "users": len(y),
        })
        conformal.update(y, pred, lower, upper)
        print(f"{item['scenario']} seed {seed} · {app_week}주 완료", flush=True)
    return pd.DataFrame(prediction_rows), pd.DataFrame(interval_rows)


def summarize_predictions(predictions):
    rows = []
    late = predictions[predictions.사용주차.between(8, 12)]
    for condition, group in late.groupby("condition"):
        denominator = max(group.actual.sum(), 1.0)
        rows.append({
            "condition": condition,
            "wape": float(np.abs(group.actual - group.prediction).sum() / denominator),
            "bias": float((group.prediction.sum() - group.actual.sum()) / denominator),
            "underprediction_rate": float((group.prediction < group.actual).mean()),
            "users_weeks": len(group),
        })
    return pd.DataFrame(rows)


def sensitivity(predictions):
    late = predictions[predictions.사용주차.between(8, 12)]
    rows = []
    for cost in [2, 3, 5]:
        for condition, group in late.groupby("condition"):
            y, pred = group.actual.to_numpy(float), group.prediction.to_numpy(float)
            loss = cost * np.maximum(y - pred, 0) + np.maximum(pred - y, 0)
            rows.append({
                "under_cost": cost, "condition": condition,
                "decision_loss": float(loss.sum() / max(y.sum(), 1)),
            })
    return pd.DataFrame(rows)


def make_figures(summary, sensitivity_data, intervals):
    import matplotlib as mpl
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
    from matplotlib.colors import LinearSegmentedColormap

    mpl.rcParams["axes.unicode_minus"] = False
    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    canvas, ink, muted, grid = "#FBFAF7", "#25241F", "#747168", "#E6E2D8"
    yellow, yellow_soft, violet, blue, gray = "#FFCC00", "#FFF4B8", "#7A5CF0", "#2A72E5", "#BDB9AF"
    figures = OUT / "figures"; figures.mkdir(parents=True, exist_ok=True)

    def frame(title, subtitle):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.890, title, fontproperties=medium, fontsize=22, color=ink)
        fig.text(0.06, 0.842, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        return fig

    # Figure 1: 비용 가정별 모델 민감도 heatmap.
    pivot = sensitivity_data.pivot(index="condition", columns="under_cost", values="decision_loss")
    pivot = pivot.reindex(CONDITIONS)
    values = pivot.to_numpy(float) * 100
    cmap = LinearSegmentedColormap.from_list("kb", ["#FFF9DB", "#FFDD55", "#C79E00"])
    fig = frame("과소예측 비용별 모델 의사결정 손실",
                "신규 홀드아웃 300명·8~12주 · 셀 값이 낮을수록 안전 · 열별 최저값 검은 테두리")
    ax = fig.add_axes([0.25, 0.14, 0.64, 0.64])
    image = ax.imshow(values, cmap=cmap, aspect="auto")
    ax.set_xticks(range(3), ["2배", "3배", "5배"])
    ax.set_yticks(range(len(pivot)), pivot.index)
    for label in [*ax.get_xticklabels(), *ax.get_yticklabels()]: label.set_fontproperties(light)
    for i in range(values.shape[0]):
        for j in range(values.shape[1]):
            ax.text(j, i, f"{values[i, j]:.1f}", ha="center", va="center",
                    fontproperties=medium, fontsize=11, color=ink)
    for j in range(values.shape[1]):
        i = int(np.argmin(values[:, j]))
        ax.add_patch(plt.Rectangle((j - 0.48, i - 0.48), 0.96, 0.96,
                                   fill=False, edgecolor=ink, linewidth=2.2))
    for spine in ax.spines.values(): spine.set_visible(False)
    colorbar = fig.colorbar(image, ax=ax, fraction=0.035, pad=0.04)
    colorbar.set_label("손실 지수 (×100)", fontproperties=light, color=muted)
    fig.savefig(figures / "01_cost_sensitivity.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "01_cost_sensitivity.svg", facecolor=canvas)
    plt.close(fig)

    # Figure 2: 중앙값과 안전 상한의 편향/과소예측 절충.
    focus = summary[summary.condition.isin(["기존 LightGBM", "편향 보정 중앙값", "안전 q75"])].set_index("condition")
    order = ["기존 LightGBM", "편향 보정 중앙값", "안전 q75"]
    colors = [gray, blue, yellow]
    fig = frame("중앙 예측과 안전 상한의 역할 분리",
                "신규 홀드아웃 300명·8~12주 · 중앙값은 편향 최소화, q75는 과소예측 방어")
    ax1 = fig.add_axes([0.09, 0.18, 0.38, 0.58])
    ax2 = fig.add_axes([0.57, 0.18, 0.36, 0.58])
    bias = focus.reindex(order).bias.to_numpy(float) * 100
    under = focus.reindex(order).underprediction_rate.to_numpy(float) * 100
    y = np.arange(len(order))
    bars = ax1.barh(y, bias, color=colors, edgecolor=ink, linewidth=0.6)
    ax1.axvline(0, color=ink, linewidth=1.2)
    ax1.set_yticks(y, order); ax1.invert_yaxis()
    ax1.set_xlim(-17, 22)
    ax1.set_xlabel("총액 편향 (%)", fontproperties=light, color=muted)
    for bar, value in zip(bars, bias):
        if value < -6:
            text_x, align = value + 1.0, "left"
        elif value < 0:
            text_x, align = value - 1.0, "right"
        else:
            text_x, align = value + 1.0, "left"
        ax1.text(text_x, bar.get_y()+bar.get_height()/2,
                 f"{value:+.1f}%", va="center", ha=align,
                 fontproperties=medium, fontsize=10, color=ink)
    bars = ax2.barh(y, under, color=colors, edgecolor=ink, linewidth=0.6)
    ax2.set_yticks(y, [""] * len(y)); ax2.invert_yaxis(); ax2.set_xlim(0, 65)
    ax2.set_xlabel("과소예측 사용자 비율 (%)", fontproperties=light, color=muted)
    ax2.bar_label(bars, fmt="%.1f%%", padding=4, fontproperties=medium, fontsize=10)
    for ax in [ax1, ax2]:
        ax.grid(axis="x", color=grid); ax.set_axisbelow(True)
        for label in ax.get_yticklabels(): label.set_fontproperties(light)
        for spine in ax.spines.values(): spine.set_visible(False)
    fig.savefig(figures / "02_expected_vs_safe.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "02_expected_vs_safe.svg", facecolor=canvas)
    plt.close(fig)

    # Figure 3: 온라인 구간 커버리지와 폭.
    weekly = intervals.groupby("사용주차", as_index=False).agg(
        coverage=("coverage", "mean"), normalized_width=("normalized_width", "mean")
    )
    fig = frame("온라인 예측구간 12주 검증",
                "편향 보정 중앙값 기반 · 직전 주 오차만 반영 · 목표 커버리지 80%")
    ax1 = fig.add_axes([0.08, 0.51, 0.84, 0.27])
    ax2 = fig.add_axes([0.08, 0.14, 0.84, 0.25])
    x = weekly.사용주차
    ax1.axhline(80, color=ink, linewidth=1.2, linestyle="--", label="목표 80%")
    ax1.plot(x, weekly.coverage * 100, color=yellow, marker="o", linewidth=3,
             markeredgecolor=ink, label="실제 커버리지")
    ax1.set_ylabel("커버리지 (%)", fontproperties=light, color=muted)
    ax1.set_ylim(55, 100); ax1.legend(frameon=False, prop=medium, loc="lower right")
    ax2.plot(x, weekly.normalized_width * 100, color=violet, marker="o", linewidth=2.6)
    ax2.set_ylabel("평균 구간폭 / 실제 지출 (%)", fontproperties=light, color=muted)
    ax2.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted)
    for ax in [ax1, ax2]:
        ax.set_xticks(range(1, APP_WEEKS + 1)); ax.set_xlim(0.7, APP_WEEKS + 0.3)
        ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
        for spine in ax.spines.values(): spine.set_visible(False)
    fig.savefig(figures / "03_online_conformal.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "03_online_conformal.svg", facecolor=canvas)
    plt.close(fig)


def main():
    prediction_parts, interval_parts = [], []
    for item in HOLDOUTS:
        predictions, intervals = run_seed(item)
        prediction_parts.append(predictions); interval_parts.append(intervals)
    predictions = pd.concat(prediction_parts, ignore_index=True)
    intervals = pd.concat(interval_parts, ignore_index=True)
    summary = summarize_predictions(predictions)
    sensitivity_data = sensitivity(predictions)

    OUT.mkdir(parents=True, exist_ok=True)
    predictions.to_csv(OUT / "holdout_predictions.csv", index=False)
    intervals.to_csv(OUT / "conformal_weekly.csv", index=False)
    summary.to_csv(OUT / "model_summary.csv", index=False)
    sensitivity_data.to_csv(OUT / "cost_sensitivity.csv", index=False)
    make_figures(summary, sensitivity_data, intervals)
    print(OUT.resolve())


if __name__ == "__main__":
    main()
