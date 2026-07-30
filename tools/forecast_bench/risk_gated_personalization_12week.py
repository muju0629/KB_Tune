"""위험 손실 전역 모델과 안전 게이트 개인화의 개발/홀드아웃 12주 실험.

주지표는 과소예측 비용을 과대예측의 3배로 둔 정규화 의사결정 손실이다.
개인화 상태는 현재 주 예측을 모두 평가한 뒤 지난 실제 카드 지출로만 갱신한다.
"""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import json

import numpy as np
import pandas as pd

import active_feedback_bench as base
import personal_bayes_feedback_bench as generator
from card_calendar_bench import FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE


HERE = Path(__file__).parent
OUT = HERE / "results/risk_gated_personalization_12week"
CALIBRATION = HERE / "results/local_spend_profile/calibration.json"
APP_WEEKS = 12
UNDER_COST = 3.0
OVER_COST = 1.0
RISK_QUANTILE = UNDER_COST / (UNDER_COST + OVER_COST)

DEV_SEEDS = [20261111, 20261112, 20261113]
HOLDOUTS = [
    {"scenario": "기본", "seed": 20261121},
    {"scenario": "중간 생활변화", "seed": 20261122, "mid_drift": True},
    {"scenario": "금액 변동성", "seed": 20261123, "volatility": 0.35},
]

RIDGE = "Ridge"
LIGHTGBM = "LightGBM"
RISK = "위험 q75 LightGBM"
EWMA = "q75 + EWMA"
BAYES = "q75 + Bayesian"
GATE = "q75 + 안전 게이트"
CONDITIONS = [RIDGE, LIGHTGBM, RISK, EWMA, BAYES, GATE]


class DirectQuantile:
    """0을 포함한 주간 카테고리 총지출의 조건 없는 q75 예측."""

    def __init__(self, seed: int):
        from lightgbm import LGBMRegressor

        self.model = LGBMRegressor(
            objective="quantile", alpha=RISK_QUANTILE,
            n_estimators=260, learning_rate=0.04, num_leaves=24,
            min_child_samples=40, reg_lambda=1.5, verbose=-1,
            random_state=seed,
        )

    def fit(self, X: pd.DataFrame, y: np.ndarray):
        self.model.fit(X, y)

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        return np.clip(self.model.predict(X), 0, None)


class LocalExperts:
    """원거래 대신 사용자×카테고리 로그잔차 충분통계량만 보관한다."""

    def __init__(self):
        self.ewma = defaultdict(float)
        self.bayes = defaultdict(lambda: [0.0, 0.0])
        self.weights = defaultdict(lambda: np.array([0.80, 0.10, 0.10], float))

    def predict(self, meta: pd.DataFrame, baseline: np.ndarray):
        ewma_pred, bayes_pred, gate_pred = [], [], []
        for i, row in enumerate(meta.itertuples(index=False)):
            key = (int(row.person), str(row.category))
            base_log = float(np.log1p(max(baseline[i], 0)))
            ewma_shift = float(np.clip(self.ewma[key], -0.9, 0.9))
            total, count = self.bayes[key]
            bayes_shift = float(np.clip(total / (count + 4.0), -0.9, 0.9))
            expert = np.array([
                baseline[i],
                np.expm1(base_log + ewma_shift),
                np.expm1(base_log + bayes_shift),
            ])
            ewma_pred.append(expert[1])
            bayes_pred.append(expert[2])
            gate_pred.append(float(self.weights[int(row.person)] @ expert))
        return (
            np.clip(np.asarray(ewma_pred), 0, None),
            np.clip(np.asarray(bayes_pred), 0, None),
            np.clip(np.asarray(gate_pred), 0, None),
        )

    def update(self, meta: pd.DataFrame, actual: np.ndarray, baseline: np.ndarray,
               predictions: tuple[np.ndarray, np.ndarray, np.ndarray]):
        ewma_pred, bayes_pred, _ = predictions
        frame = meta[["person", "category"]].copy()
        frame["actual"] = actual
        frame["base"] = baseline
        frame["ewma"] = ewma_pred
        frame["bayes"] = bayes_pred

        # 먼저 이번 주의 세 전문가 손실로 다음 주 게이트 가중치를 갱신한다.
        for person, group in frame.groupby("person"):
            y = float(group.actual.sum())
            preds = np.array([group.base.sum(), group.ewma.sum(), group.bayes.sum()])
            losses = asymmetric_loss(np.full(3, y), preds) / max(y, 1.0)
            old = self.weights[int(person)]
            updated = old * np.exp(-0.55 * np.clip(losses, 0, 6))
            updated = updated / max(updated.sum(), 1e-12)
            # 한 번의 이상치로 후보가 영구 탈락하지 않도록 2%를 안전 사전값으로 복귀.
            self.weights[int(person)] = 0.98 * updated + 0.02 * np.array([0.80, 0.10, 0.10])

        # 이후에만 실제 카드 지출로 로컬 잔차 상태를 갱신한다.
        for i, row in enumerate(meta.itertuples(index=False)):
            key = (int(row.person), str(row.category))
            residual = float(np.clip(
                np.log1p(max(actual[i], 0)) - np.log1p(max(baseline[i], 0)), -1.5, 1.5,
            ))
            self.ewma[key] = 0.70 * self.ewma[key] + 0.30 * residual
            self.bayes[key][0] = 0.92 * self.bayes[key][0] + residual
            self.bayes[key][1] = 0.92 * self.bayes[key][1] + 1.0


def asymmetric_loss(actual, predicted):
    actual = np.asarray(actual, float)
    predicted = np.asarray(predicted, float)
    return UNDER_COST * np.maximum(actual - predicted, 0) + OVER_COST * np.maximum(predicted - actual, 0)


def set_seed(seed: int):
    generator.SEED = seed
    base.SEED = seed + 10_000
    generator.LIFESTYLE_GLOBAL_SD = 0.18
    generator.LIFESTYLE_CATEGORY_SD = 0.35
    generator.LIFESTYLE_OCCURRENCE_SD = 0.55


def apply_scenario(tx: pd.DataFrame, scenario: dict) -> pd.DataFrame:
    out = tx.copy()
    rng = np.random.default_rng(int(scenario["seed"]) + 777)
    eval_mask = (out.person >= N_PRIOR_PEOPLE) & (out.week >= FIRST_TEST_WEEK)
    volatility = float(scenario.get("volatility", 0.0))
    if volatility:
        out.loc[eval_mask, "amount"] *= rng.lognormal(0, volatility, int(eval_mask.sum()))
    if scenario.get("mid_drift"):
        people = rng.choice(np.arange(N_PRIOR_PEOPLE, N_PEOPLE), size=30, replace=False)
        for person in people:
            categories = rng.choice(base.CATEGORIES, size=2, replace=False)
            factor = float(rng.choice([0.55, 1.75]))
            mask = (
                (out.person == person) & out.category.isin(categories)
                & (out.week >= FIRST_TEST_WEEK + 6)
            )
            out.loc[mask, "amount"] *= factor
    out["amount"] = out.amount.clip(lower=0).round(2)
    return out


def fit_models(seed: int, X_train: pd.DataFrame, y_train: np.ndarray):
    fitted = {}
    for model in base.models(seed=seed):
        if model.name in [RIDGE, LIGHTGBM]:
            model.fit(X_train, y_train)
            fitted[model.name] = model
    quantile = DirectQuantile(seed)
    quantile.fit(X_train, y_train)
    return fitted, quantile


def run_seed(seed: int, scenario: dict) -> pd.DataFrame:
    set_seed(seed)
    calibration = json.loads(CALIBRATION.read_text(encoding="utf-8"))
    true_tx, calendar, _ = generator.generate_persistent(calibration)
    true_tx = apply_scenario(true_tx, scenario)
    observed = base.add_observation_noise(true_tx)
    target_cat, _ = base.true_targets(true_tx)
    pop_amount, pop_occurrence = base.population_stats(true_tx)
    index = base.make_index(observed, calendar)
    X_train, _, y_train = base.build_rows(
        range(N_PRIOR_PEOPLE), range(base.HISTORY_WEEKS, FIRST_TEST_WEEK),
        index, target_cat, pop_amount, pop_occurrence,
    )
    fitted, quantile = fit_models(seed, X_train, y_train)
    local = LocalExperts()
    rows = []

    for app_week in range(1, APP_WEEKS + 1):
        week = FIRST_TEST_WEEK + app_week - 1
        X, meta, actual = base.build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], index, target_cat,
            pop_amount, pop_occurrence,
        )
        ridge_p, ridge_amount = fitted[RIDGE].predict(X)
        lgbm_p, lgbm_amount = fitted[LIGHTGBM].predict(X)
        ridge_prediction = ridge_p * ridge_amount
        lgbm_prediction = lgbm_p * lgbm_amount
        risk_prediction = quantile.predict(X)
        personal = local.predict(meta, risk_prediction)
        predictions = {
            RIDGE: ridge_prediction,
            LIGHTGBM: lgbm_prediction,
            RISK: risk_prediction,
            EWMA: personal[0],
            BAYES: personal[1],
            GATE: personal[2],
        }
        for condition, prediction in predictions.items():
            for i, row in enumerate(meta.itertuples(index=False)):
                rows.append({
                    "scenario": scenario["scenario"], "seed": seed,
                    "사용주차": app_week, "condition": condition,
                    "person": int(row.person), "category": str(row.category),
                    "actual": float(actual[i]), "prediction": float(prediction[i]),
                })
        local.update(meta, actual, risk_prediction, personal)
        print(f"{scenario['scenario']} seed {seed} · {app_week}주 완료", flush=True)
    return pd.DataFrame(rows)


def aggregate_metrics(data: pd.DataFrame) -> pd.DataFrame:
    total = data.groupby(
        ["scenario", "seed", "사용주차", "condition", "person"], as_index=False,
    )[["actual", "prediction"]].sum()
    rows = []
    for keys, group in total.groupby(["scenario", "사용주차", "condition"]):
        denominator = max(float(group.actual.sum()), 1.0)
        rows.append({
            "scenario": keys[0], "사용주차": keys[1], "condition": keys[2],
            "wape": float(np.abs(group.actual - group.prediction).sum() / denominator),
            "bias": float((group.prediction.sum() - group.actual.sum()) / denominator),
            "decision_loss": float(asymmetric_loss(group.actual, group.prediction).sum() / denominator),
            "underprediction_rate": float((group.prediction < group.actual).mean()),
            "users": int(len(group)),
        })
    return pd.DataFrame(rows)


def development_leaderboard(dev: pd.DataFrame) -> pd.DataFrame:
    summary = aggregate_metrics(dev)
    late = summary[summary.사용주차.between(8, 12)]
    return late.groupby("condition", as_index=False).agg(
        decision_loss=("decision_loss", "mean"),
        wape=("wape", "mean"), bias=("bias", "mean"),
        underprediction_rate=("underprediction_rate", "mean"),
    ).sort_values(["decision_loss", "wape"], ignore_index=True)


def bootstrap_gate(data: pd.DataFrame, week: int, n_boot: int = 2500):
    frame = data[(data.사용주차 == week) & data.condition.isin([RISK, GATE])]
    total = frame.groupby(
        ["scenario", "seed", "person", "condition"], as_index=False,
    )[["actual", "prediction"]].sum()
    total["unit"] = total.scenario + ":" + total.seed.astype(str) + ":" + total.person.astype(str)
    pivot = total.pivot(index="unit", columns="condition", values=["actual", "prediction"])
    units = pivot.index.to_numpy()

    def delta(sample):
        actual = pivot.loc[sample, ("actual", RISK)].to_numpy(float)
        base_pred = pivot.loc[sample, ("prediction", RISK)].to_numpy(float)
        gate_pred = pivot.loc[sample, ("prediction", GATE)].to_numpy(float)
        denominator = max(actual.sum(), 1.0)
        return float((asymmetric_loss(actual, base_pred).sum()
                      - asymmetric_loss(actual, gate_pred).sum()) / denominator)

    rng = np.random.default_rng(20261200 + week)
    point = delta(units)
    draws = [delta(rng.choice(units, len(units), replace=True)) for _ in range(n_boot)]
    low, high = np.quantile(draws, [0.025, 0.975])
    return point, float(low), float(high)


def make_figures(summary: pd.DataFrame, intervals: pd.DataFrame):
    import matplotlib as mpl
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    mpl.rcParams["axes.unicode_minus"] = False
    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    ink, muted, grid, canvas = "#25241F", "#747168", "#E6E2D8", "#FBFAF7"
    blue, purple = "#2A72E5", "#7A5CF0"
    figures = OUT / "figures"; figures.mkdir(parents=True, exist_ok=True)

    def frame(title, subtitle):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.905, title, fontproperties=medium, fontsize=22, color=ink)
        fig.text(0.06, 0.865, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        return fig

    plot = summary[summary.사용주차.isin([8, 12])].groupby(
        ["사용주차", "condition"], as_index=False
    ).decision_loss.mean()
    order = CONDITIONS
    x = np.arange(len(order)); width = 0.34
    fig = frame("최종 홀드아웃 모델별 의사결정 손실",
                "신규 3개 시드·총 300명 · 과소예측 비용 3배 · 낮을수록 안전")
    ax = fig.add_axes([0.08, 0.19, 0.88, 0.60])
    for offset, week, color in [(-width/2, 8, blue), (width/2, 12, purple)]:
        values = plot[plot.사용주차 == week].set_index("condition").reindex(order).decision_loss * 100
        bars = ax.bar(x + offset, values, width, label=f"{week}주", color=color,
                      edgecolor=ink, linewidth=0.4)
        ax.bar_label(bars, fmt="%.1f", padding=3, fontproperties=light, fontsize=8)
    ax.set_xticks(x, order, rotation=18, ha="right")
    for label in ax.get_xticklabels(): label.set_fontproperties(light)
    ax.set_ylabel("의사결정 손실 지수 (×100)", fontproperties=light, color=muted)
    ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.legend(frameon=False, prop=medium)
    fig.savefig(figures / "01_decision_loss_models.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "01_decision_loss_models.svg", facecolor=canvas)
    plt.close(fig)

    fig = frame("안전 게이트 개인화의 추가 개선폭",
                "q75 전역 모델 손실 빼기 게이트 손실 · 사용자 bootstrap 95% 구간")
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    x = intervals.사용주차.to_numpy(float)
    y = intervals.improvement.to_numpy(float) * 100
    low = intervals.CI_low.to_numpy(float) * 100
    high = intervals.CI_high.to_numpy(float) * 100
    ax.axhline(0, color=ink, linewidth=1.2)
    ax.fill_between(x, low, high, color=purple, alpha=0.16)
    ax.plot(x, y, color=purple, linewidth=3, marker="o", markersize=6)
    ax.set_xticks(range(1, APP_WEEKS + 1)); ax.set_xlim(0.7, APP_WEEKS + 0.3)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("의사결정 손실 개선폭", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    fig.text(0.08, 0.07, "신뢰구간 하한이 0보다 클 때만 누적 개인화 일반화로 판정",
             fontproperties=light, fontsize=10, color=muted)
    fig.savefig(figures / "02_gate_lift.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "02_gate_lift.svg", facecolor=canvas)
    plt.close(fig)


def report(leaderboard, summary, intervals):
    winner = leaderboard.iloc[0]
    ci8 = intervals[intervals.사용주차 == 8].iloc[0]
    ci12 = intervals[intervals.사용주차 == 12].iloc[0]
    final = summary[summary.사용주차.isin([8, 12])].sort_values(
        ["scenario", "사용주차", "decision_loss"]
    )
    aggregate = summary[summary.사용주차.isin([8, 12])].groupby(
        ["사용주차", "condition"], as_index=False,
    ).agg(
        decision_loss=("decision_loss", "mean"),
        wape=("wape", "mean"), bias=("bias", "mean"),
        underprediction_rate=("underprediction_rate", "mean"),
        users=("users", "sum"),
    ).sort_values(["사용주차", "decision_loss"])
    gate_pass = bool(ci8.CI_low > 0 and ci12.CI_low > 0)
    return f"""# 위험 보정 전역 모델 + 안전 게이트 개인화 12주 검증

## 결론

- 개발 시드 의사결정 손실 1위: **{winner.condition}**
- 1위 개발 손실: **{winner.decision_loss:.4f}**, WAPE **{winner.wape:.4f}**, 편향 **{winner.bias:+.4f}**
- 안전 게이트 8주 추가 개선: **{ci8.improvement*100:.2f}** (95% CI {ci8.CI_low*100:.2f}~{ci8.CI_high*100:.2f})
- 안전 게이트 12주 추가 개선: **{ci12.improvement*100:.2f}** (95% CI {ci12.CI_low*100:.2f}~{ci12.CI_high*100:.2f})
- 누적 개인화 판정: **{'통과' if gate_pass else '보류'}**

## 개발 모델 순위

{leaderboard.to_markdown(index=False, floatfmt='.4f')}

## 최종 홀드아웃 8주·12주

### 세 시나리오 합계

{aggregate.to_markdown(index=False, floatfmt='.4f')}

### 시나리오별

{final.to_markdown(index=False, floatfmt='.4f')}

## 판정 계약

1. WAPE가 아니라 과소예측을 과대예측의 3배로 둔 의사결정 손실을 주지표로 사용.
2. q75는 비용 비율 `3/(3+1)`로 사전 고정하고 홀드아웃 결과로 변경하지 않음.
3. 개발 시드 `{DEV_SEEDS}`와 최종 시드 `{[x['seed'] for x in HOLDOUTS]}`를 분리.
4. 모든 현재 주 예측을 끝낸 뒤에만 실제 카드 지출로 개인 상태를 갱신.
5. 최종 평가는 기본·7주차 생활변화·금액 변동성 시나리오에서 한 번만 실행.
6. 사용자 bootstrap 95% 신뢰구간 하한이 0보다 클 때만 개인화 일반화로 인정.

## 개인정보 경계

- 실험은 합성 데이터만 사용하며 외부 전송이 없음.
- 제품에서는 원거래 대신 EWMA 값, Bayesian 합·가중치, 게이트 가중치만 기기 내 저장 가능.
- 사용자별 상태를 서버 재학습이나 외부 LLM 입력으로 보내지 않는 구조를 전제로 함.

## 제한

- 같은 합성 생성기 계열이므로 실제 사용자 성능을 증명하지 않음.
- 발생일·주기와 예측구간은 이번 1차 실험 범위가 아니며, 금액 모델이 통과한 뒤 별도 평가해야 함.
- 실제 제품 판단 전에는 카드 사용자 20~50명의 12주 shadow-mode 검증이 필요함.
"""


def main():
    dev = pd.concat([
        run_seed(seed, {"scenario": "개발", "seed": seed}) for seed in DEV_SEEDS
    ], ignore_index=True)
    leaderboard = development_leaderboard(dev)
    print("개발 1위:", leaderboard.iloc[0].condition, flush=True)

    holdout = pd.concat([
        run_seed(item["seed"], item) for item in HOLDOUTS
    ], ignore_index=True)
    summary = aggregate_metrics(holdout)
    intervals = pd.DataFrame([
        {
            "사용주차": week, "improvement": values[0],
            "CI_low": values[1], "CI_high": values[2],
        }
        for week in range(1, APP_WEEKS + 1)
        for values in [bootstrap_gate(holdout, week)]
    ])

    OUT.mkdir(parents=True, exist_ok=True)
    dev.to_csv(OUT / "development_predictions.csv", index=False)
    holdout.to_csv(OUT / "holdout_predictions.csv", index=False)
    leaderboard.to_csv(OUT / "development_leaderboard.csv", index=False)
    summary.to_csv(OUT / "holdout_summary.csv", index=False)
    intervals.to_csv(OUT / "gate_bootstrap_intervals.csv", index=False)
    (OUT / "results.md").write_text(
        report(leaderboard, summary, intervals), encoding="utf-8",
    )
    make_figures(summary, intervals)
    print((OUT / "results.md").resolve())


if __name__ == "__main__":
    main()
