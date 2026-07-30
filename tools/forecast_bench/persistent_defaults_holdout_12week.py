"""지속 개인학습 v2의 개발/최종 홀드아웃 분리 12주 검증.

이전 `persistent_learning_12week.py`의 평가 사용자 100명은 모델 수정의 근거로 사용됐으므로
다시 최종 성능 판정에 쓰지 않는다. 여기서는 개발 시드 3개에서 사전 등록한 7개 후보만
비교하고, 선택된 하나를 새로운 홀드아웃 시드 3개에 한 번만 적용한다.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
import json

import numpy as np
import pandas as pd

import active_feedback_bench as base
import personal_bayes_feedback_bench as personal_data
import persistent_learning_12week as strict
from card_calendar_bench import FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE


HERE = Path(__file__).parent
OUT = HERE / "results/persistent_defaults_holdout_12week"
CALIBRATION = HERE / "results/local_spend_profile/calibration.json"
APP_WEEKS = 12

DEV_SEEDS = [20260811, 20260812, 20260813]
HOLDOUTS = [
    {"scenario": "기본", "seed": 20260821},
    {
        "scenario": "피드백 잡음",
        "seed": 20260822,
        "response_rate": 0.70,
        "intent_accuracy": 0.85,
        "amount_log_error": 0.20,
    },
    {
        "scenario": "약한 생활변화",
        "seed": 20260823,
        "lifestyle_scale": 0.55,
    },
]

PASSIVE = strict.PASSIVE
IMMEDIATE = strict.IMMEDIATE
PERSISTENT = strict.PERSISTENT


@dataclass(frozen=True)
class Candidate:
    name: str
    mode: str
    global_prior: float
    category_prior: float
    decay: float


# 이전 최종 100명의 결과를 보고 늘리지 않는 제한된 후보군.
CANDIDATES = [
    Candidate("R-g4-c2-d90", "residual", 4.0, 2.0, 0.90),
    Candidate("R-g8-c4-d90", "residual", 8.0, 4.0, 0.90),
    Candidate("R-g4-c2-d100", "residual", 4.0, 2.0, 1.00),
    Candidate("D-g4-c1.5-d90", "direct", 4.0, 1.5, 0.90),
    Candidate("D-g4-c3-d90", "direct", 4.0, 3.0, 0.90),
    Candidate("D-g4-c1.5-d100", "direct", 4.0, 1.5, 1.00),
    Candidate("D-g8-c3-d90", "direct", 8.0, 3.0, 0.90),
]


class PersonalDefaults:
    """주간 예측 잔차가 아니라 사용자가 말한 평소 기본값을 별도 상태로 보관한다."""

    def __init__(self, spec: Candidate):
        self.spec = spec
        self.amount_global = defaultdict(lambda: [0.0, 0.0])
        self.amount_category = defaultdict(lambda: [0.0, 0.0])
        self.occurrence_global = defaultdict(lambda: [0.0, 0.0])
        self.occurrence_category = defaultdict(lambda: [0.0, 0.0])

    def decay(self) -> None:
        if self.spec.decay >= 1:
            return
        for store in [self.amount_global, self.amount_category,
                      self.occurrence_global, self.occurrence_category]:
            for value in store.values():
                value[0] *= self.spec.decay
                value[1] *= self.spec.decay

    @staticmethod
    def _add(store, key, value, weight=1.0):
        store[key][0] += float(value) * weight
        store[key][1] += weight

    @staticmethod
    def _posterior(store, key, prior):
        total, weight = store[key]
        return total / (weight + prior), weight

    @staticmethod
    def _mean(store, key):
        total, weight = store[key]
        return (total / weight if weight else 0.0), weight

    def update(self, person: int, category: str, row, answer: dict) -> None:
        if not answer["responded"]:
            return

        amount_anchor = max(float(row.positive_mean), 100.0)
        occurrence_anchor = float(np.clip(
            0.8 * row.occur_rate + 0.2 * row.population_occurrence, 0.02, 0.98,
        ))
        if answer.get("reported_amount") is not None:
            reported_log = float(np.log(max(answer["reported_amount"], 100.0)))
            amount_residual = float(np.clip(reported_log - np.log(amount_anchor), -0.8, 0.8))
            self._add(self.amount_global, person, amount_residual, 0.35)
            category_value = reported_log if self.spec.mode == "direct" else amount_residual
            self._add(self.amount_category, (person, category), category_value)

        if answer.get("reported_probability") is not None:
            reported_logit = float(strict.logit(answer["reported_probability"]))
            occurrence_residual = float(np.clip(
                reported_logit - strict.logit(occurrence_anchor), -1.5, 1.5,
            ))
            self._add(self.occurrence_global, person, occurrence_residual, 0.35)
            category_value = reported_logit if self.spec.mode == "direct" else occurrence_residual
            self._add(self.occurrence_category, (person, category), category_value)

    def adjust(self, meta: pd.DataFrame, p: np.ndarray,
               amount: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        p, amount = p.copy(), amount.copy()
        for i, row in enumerate(meta.itertuples(index=False)):
            person, category = int(row.person), str(row.category)
            global_amount, _ = self._posterior(
                self.amount_global, person, self.spec.global_prior,
            )
            global_occurrence, _ = self._posterior(
                self.occurrence_global, person, self.spec.global_prior,
            )
            if self.spec.mode == "direct":
                category_amount, category_amount_n = self._mean(
                    self.amount_category, (person, category),
                )
                category_occurrence, category_occurrence_n = self._mean(
                    self.occurrence_category, (person, category),
                )
            else:
                category_amount, category_amount_n = self._posterior(
                    self.amount_category, (person, category), self.spec.category_prior,
                )
                category_occurrence, category_occurrence_n = self._posterior(
                    self.occurrence_category, (person, category), self.spec.category_prior,
                )

            base_log_amount = float(np.log(max(amount[i], 100.0)))
            base_logit = float(strict.logit(p[i]))
            if self.spec.mode == "direct":
                amount_weight = min(0.70, category_amount_n
                                    / (category_amount_n + self.spec.category_prior))
                occurrence_weight = min(0.70, category_occurrence_n
                                        / (category_occurrence_n + self.spec.category_prior))
                shifted_base = base_log_amount + 0.45 * np.clip(global_amount, -0.5, 0.5)
                shifted_logit = base_logit + 0.45 * np.clip(global_occurrence, -1.0, 1.0)
                base_log_amount = ((1 - amount_weight) * shifted_base
                                   + amount_weight * category_amount)
                base_logit = ((1 - occurrence_weight) * shifted_logit
                              + occurrence_weight * category_occurrence)
            else:
                base_log_amount += (
                    0.40 * np.clip(global_amount, -0.5, 0.5)
                    + 0.60 * np.clip(category_amount, -0.5, 0.5)
                )
                base_logit += (
                    0.40 * np.clip(global_occurrence, -1.0, 1.0)
                    + 0.60 * np.clip(category_occurrence, -1.0, 1.0)
                )

            amount[i] = float(np.exp(base_log_amount))
            p[i] = float(strict.logistic(base_logit))
        return np.clip(p, 0.01, 0.99), np.clip(amount, 100, None)


def simulate_answers(scopes, week, target_cat, pop_amount, pop_occurrence,
                     latent_lookup, rng, scenario):
    response_rate = float(scenario.get("response_rate", base.RESPONSE_RATE))
    intent_accuracy = float(scenario.get("intent_accuracy", base.INTENT_ACCURACY))
    amount_log_error = float(scenario.get("amount_log_error", base.AMOUNT_LOG_ERROR))
    answers = {}
    for person, category in sorted(scopes):
        scope = scopes[(person, category)]
        actual = float(target_cat.get((person, week, category), 0))
        responded = bool(rng.random() < response_rate)
        reported_probability = None
        if scope == "thisOccurrence":
            reported_occurrence = actual > 0
            if responded and rng.random() > intent_accuracy:
                reported_occurrence = not reported_occurrence
            reported_amount = None
            if responded and reported_occurrence:
                reference = actual if actual > 0 else float(pop_amount[category])
                reported_amount = float(reference * rng.lognormal(0, amount_log_error))
        else:
            latent = latent_lookup.get((person, category), {
                "test_typical_amount": float(pop_amount[category]),
                "test_occurrence_probability": float(pop_occurrence[category]),
            })
            reported_probability = (
                float(np.clip(latent["test_occurrence_probability"] + rng.normal(0, 0.08),
                              0.05, 0.95)) if responded else None
            )
            reported_occurrence = bool(
                reported_probability is not None and reported_probability >= 0.5
            )
            reported_amount = (
                float(latent["test_typical_amount"] * rng.lognormal(0, amount_log_error))
                if responded else None
            )
        answers[(person, category)] = {
            "actual": actual,
            "responded": responded,
            "reported_occurrence": reported_occurrence,
            "reported_probability": reported_probability,
            "reported_amount": reported_amount,
        }
    return answers


def _set_generator_scenario(seed: int, scenario: dict):
    personal_data.SEED = seed
    base.SEED = seed + 10_000
    scale = float(scenario.get("lifestyle_scale", 1.0))
    personal_data.LIFESTYLE_GLOBAL_SD = 0.18 * scale
    personal_data.LIFESTYLE_CATEGORY_SD = 0.35 * scale
    personal_data.LIFESTYLE_OCCURRENCE_SD = 0.55 * scale


def run_seed(seed: int, scenario: dict, candidates: list[Candidate],
             global_model_name: str = "LightGBM") -> pd.DataFrame:
    _set_generator_scenario(seed, scenario)
    calibration = json.loads(CALIBRATION.read_text(encoding="utf-8"))
    true_tx, calendar, latent = personal_data.generate_persistent(calibration)
    latent_lookup = {
        (int(row.person), str(row.category)): {
            "test_typical_amount": float(row.test_typical_amount),
            "test_occurrence_probability": float(row.test_occurrence_probability),
        }
        for row in latent.itertuples(index=False)
    }
    observed = base.add_observation_noise(true_tx)
    target_cat, _ = base.true_targets(true_tx)
    pop_amount, pop_occurrence = base.population_stats(true_tx)
    index = base.make_index(observed, calendar)
    X_train, _, y_train = base.build_rows(
        range(N_PRIOR_PEOPLE), range(base.HISTORY_WEEKS, FIRST_TEST_WEEK),
        index, target_cat, pop_amount, pop_occurrence,
    )
    global_model = next(
        model for model in base.models(seed=seed) if model.name == global_model_name
    )
    global_model.fit(X_train, y_train)

    learners = {spec.name: PersonalDefaults(spec) for spec in candidates}
    history: dict[tuple[int, str], int] = {}
    answer_rng = np.random.default_rng(seed + 99)
    rows = []

    for app_week in range(1, APP_WEEKS + 1):
        week = FIRST_TEST_WEEK + app_week - 1
        X, meta, actual = base.build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], index, target_cat,
            pop_amount, pop_occurrence,
        )
        base_p, base_amount = global_model.predict(X)
        scopes = strict.select_scopes(meta, X, (base_p, base_amount), app_week, history)
        answers = simulate_answers(
            scopes, week, target_cat, pop_amount, pop_occurrence,
            latent_lookup, answer_rng, scenario,
        )
        queried = np.array([
            (int(row.person), str(row.category)) in scopes
            for row in meta.itertuples(index=False)
        ], bool)
        immediate_p, immediate_amount, _, _ = strict.apply_immediate(
            meta, base_p, base_amount, scopes, answers,
        )

        def append(condition, p, amount):
            for i, row in enumerate(meta.itertuples(index=False)):
                rows.append({
                    "scenario": scenario["scenario"], "seed": seed,
                    "사용주차": app_week, "condition": condition,
                    "person": int(row.person), "category": str(row.category),
                    "actual": float(actual[i]), "probability": float(p[i]),
                    "prediction": float(p[i] * amount[i]),
                    "queried": bool(queried[i]),
                })

        append(PASSIVE, base_p, base_amount)
        append(IMMEDIATE, immediate_p, immediate_amount)
        for spec in candidates:
            learner = learners[spec.name]
            p, amount = learner.adjust(meta, base_p, base_amount)
            p, amount, _, _ = strict.apply_immediate(meta, p, amount, scopes, answers)
            append(spec.name, p, amount)

        # 현재 주 예측·평가 후 다음 주 상태를 갱신한다.
        feature_lookup = {
            (int(row.person), str(row.category)): row
            for row in X.assign(person=meta.person, category=meta.category).itertuples(index=False)
        }
        for learner in learners.values():
            learner.decay()
            for key, scope in scopes.items():
                if scope == "futureDefault":
                    learner.update(key[0], key[1], feature_lookup[key], answers[key])
        print(f"{scenario['scenario']} seed {seed} · {app_week}주 완료", flush=True)
    return pd.DataFrame(rows)


def strict_wape(data: pd.DataFrame) -> float:
    data = data[~data.queried]
    total = data.groupby(["seed", "person"])[["actual", "prediction"]].sum()
    return base.wape(total.actual, total.prediction)


def select_candidate(dev: pd.DataFrame) -> tuple[Candidate, pd.DataFrame]:
    late = dev[dev.사용주차.between(8, 12)]
    immediate = strict_wape(late[late.condition == IMMEDIATE])
    rows = []
    for spec in CANDIDATES:
        score = strict_wape(late[late.condition == spec.name])
        rows.append({
            "candidate": spec.name, "mode": spec.mode,
            "global_prior": spec.global_prior, "category_prior": spec.category_prior,
            "decay": spec.decay, "late_week_wape": score,
            "improvement_vs_immediate": immediate - score,
        })
    leaderboard = pd.DataFrame(rows).sort_values(
        ["late_week_wape", "candidate"], ignore_index=True,
    )
    selected_name = str(leaderboard.iloc[0].candidate)
    return next(spec for spec in CANDIDATES if spec.name == selected_name), leaderboard


def summarize_final(final: pd.DataFrame, selected: Candidate) -> pd.DataFrame:
    keep = final[final.condition.isin([PASSIVE, IMMEDIATE, selected.name])].copy()
    keep["condition"] = keep.condition.replace({selected.name: PERSISTENT})
    rows = []
    for (scenario, week, condition), group in keep.groupby(
            ["scenario", "사용주차", "condition"]):
        unqueried = group[~group.queried]
        total = group.groupby(["seed", "person"])[["actual", "prediction"]].sum()
        uq_total = unqueried.groupby(["seed", "person"])[["actual", "prediction"]].sum()
        rows.append({
            "scenario": scenario, "사용주차": week, "condition": condition,
            "total_wape": base.wape(total.actual, total.prediction),
            "unqueried_wape": base.wape(uq_total.actual, uq_total.prediction),
            "brier": float(np.mean((group.probability - (group.actual > 0)) ** 2)),
            "users": int(total.shape[0]),
        })
    return pd.DataFrame(rows)


def bootstrap_final(final: pd.DataFrame, selected: Candidate, week: int,
                    n_boot: int = 2500):
    data = final[(final.사용주차 == week) & (~final.queried)
                 & (final.condition.isin([IMMEDIATE, selected.name]))].copy()
    data["unit"] = data.scenario + ":" + data.seed.astype(str) + ":" + data.person.astype(str)
    totals = data.groupby(["condition", "unit"])[["actual", "prediction"]].sum().reset_index()
    pivot = totals.pivot(index="unit", columns="condition", values=["actual", "prediction"])
    units = pivot.index.to_numpy()
    rng = np.random.default_rng(20260900 + week)

    def delta(sample):
        immediate = base.wape(pivot.loc[sample, ("actual", IMMEDIATE)],
                              pivot.loc[sample, ("prediction", IMMEDIATE)])
        persistent = base.wape(pivot.loc[sample, ("actual", selected.name)],
                               pivot.loc[sample, ("prediction", selected.name)])
        return immediate - persistent

    point = delta(units)
    draws = [delta(rng.choice(units, len(units), replace=True)) for _ in range(n_boot)]
    low, high = np.quantile(draws, [0.025, 0.975])
    return float(point), float(low), float(high)


def scenario_checkpoints(summary: pd.DataFrame) -> pd.DataFrame:
    checkpoints = summary[summary.사용주차.isin([8, 12])]
    pivot = checkpoints.pivot(index=["scenario", "사용주차"],
                              columns="condition", values="unqueried_wape")
    out = pivot.reset_index()
    out["improvement"] = out[IMMEDIATE] - out[PERSISTENT]
    return out


def make_figures(summary: pd.DataFrame, intervals: pd.DataFrame,
                 checkpoints: pd.DataFrame) -> None:
    import matplotlib as mpl
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    mpl.rcParams["axes.unicode_minus"] = False
    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    ink, muted, grid, canvas = "#25241F", "#747168", "#E6E2D8", "#FBFAF7"
    palette = {PASSIVE: "#BDB9AF", IMMEDIATE: "#2A72E5", PERSISTENT: "#7A5CF0"}
    figures = OUT / "figures"; figures.mkdir(parents=True, exist_ok=True)

    aggregate = summary.groupby(["사용주차", "condition"], as_index=False).agg(
        actual=("unqueried_wape", "mean")
    )

    def frame(title, subtitle):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.905, title, fontproperties=medium, fontsize=22, color=ink)
        fig.text(0.06, 0.865, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        return fig

    fig = frame("최종 홀드아웃 1~12주 미질문 WAPE",
                "신규 3개 시드·총 300명 · 기본/피드백 잡음/약한 생활변화 평균 · 낮을수록 정확")
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    for condition in [PASSIVE, IMMEDIATE, PERSISTENT]:
        group = aggregate[aggregate.condition == condition]
        ax.plot(group.사용주차, group.actual * 100, label=condition,
                color=palette[condition], linewidth=3 if condition == PERSISTENT else 2.2,
                marker="o", markersize=5.5)
    ax.set_xticks(range(1, 13)); ax.set_xlim(0.7, 12.3)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("미질문 WAPE (%)", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.legend(frameon=False, prop=medium)
    fig.text(0.08, 0.07, "개발 시드에서 후보 선택 후 홀드아웃 시드는 1회만 평가",
             fontproperties=light, fontsize=10, color=muted)
    fig.savefig(figures / "01_holdout_unqueried_wape.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "01_holdout_unqueried_wape.svg", facecolor=canvas)
    plt.close(fig)

    fig = frame("최종 홀드아웃의 지속학습 추가 개선폭",
                "즉시 보정만 WAPE 빼기 지속 개인학습 WAPE · 사용자 bootstrap 95% 구간")
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    x = intervals.사용주차.to_numpy(float)
    y = intervals.improvement.to_numpy(float) * 100
    low = intervals.CI_low.to_numpy(float) * 100
    high = intervals.CI_high.to_numpy(float) * 100
    ax.axhline(0, color=ink, linewidth=1.2)
    ax.fill_between(x, low, high, color=palette[PERSISTENT], alpha=0.16)
    ax.plot(x, y, color=palette[PERSISTENT], linewidth=3, marker="o", markersize=6)
    ax.set_xticks(range(1, 13)); ax.set_xlim(0.7, 12.3)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("미질문 WAPE 개선폭 (%p)", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    fig.text(0.08, 0.07, "신뢰구간 하한이 0보다 클 때만 일반화로 판정",
             fontproperties=light, fontsize=10, color=muted)
    fig.savefig(figures / "02_holdout_persistent_lift.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "02_holdout_persistent_lift.svg", facecolor=canvas)
    plt.close(fig)

    plot = checkpoints.copy()
    labels = [f"{row.scenario} · {int(row.사용주차)}주" for row in plot.itertuples()]
    values = plot.improvement.to_numpy(float) * 100
    colors = ["#2A72E5" if week == 8 else "#7A5CF0" for week in plot.사용주차]
    fig = frame("시나리오별 8주·12주 지속학습 개선폭",
                "양수면 지속 개인학습 우세 · 같은 알고리즘을 기본/잡음/약한 변화 조건에 적용")
    ax = fig.add_axes([0.22, 0.15, 0.72, 0.66])
    y_pos = np.arange(len(plot))
    bars = ax.barh(y_pos, values, color=colors, edgecolor=ink, linewidth=0.5)
    ax.axvline(0, color=ink, linewidth=1.2)
    ax.set_yticks(y_pos, labels); ax.invert_yaxis()
    for label in ax.get_yticklabels(): label.set_fontproperties(light)
    span = max(float(values.max() - values.min()), 0.1)
    ax.set_xlim(float(values.min() - 0.12 * span), float(values.max() + 0.35 * span))
    value_column = float(values.max() + 0.12 * span)
    for bar, value in zip(bars, values):
        ax.text(value_column, bar.get_y() + bar.get_height()/2, f"{value:+.2f}%p",
                va="center", ha="left",
                fontproperties=medium, fontsize=10, color=ink)
    ax.set_xlabel("미질문 WAPE 개선폭 (%p)", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="x", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    fig.savefig(figures / "03_scenario_checkpoints.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "03_scenario_checkpoints.svg", facecolor=canvas)
    plt.close(fig)


def report(selected, leaderboard, summary, intervals, checkpoints) -> str:
    ci8 = intervals[intervals.사용주차 == 8].iloc[0]
    ci12 = intervals[intervals.사용주차 == 12].iloc[0]
    passed8, passed12 = ci8.CI_low > 0, ci12.CI_low > 0
    if passed8 and passed12:
        verdict = "8주와 12주 모두 신규 홀드아웃에서 미질문 일반화가 확인됐다."
    elif passed12:
        verdict = "12주 시점에서만 신규 홀드아웃 일반화가 확인됐다."
    else:
        verdict = "신규 홀드아웃에서 지속학습 일반화가 확인되지 않았다."
    final_points = summary[summary.사용주차.isin([8, 12])].sort_values(
        ["scenario", "사용주차", "condition"]
    )
    return f"""# 지속 개인 기본값 학습 · 개발/최종 홀드아웃 12주 검증

## 결론

- 판정: **{verdict}**
- 배포 결정: **보류** — 개발 시드에서도 즉시 보정 대비 우세한 후보가 0/7개였습니다.
- 선택 모델: **{selected.name}** (`{selected.mode}`, global prior {selected.global_prior}, category prior {selected.category_prior}, decay {selected.decay})
- 8주차 추가 개선폭: **{ci8.improvement*100:.2f}%p** (95% CI {ci8.CI_low*100:.2f}~{ci8.CI_high*100:.2f}%p)
- 12주차 추가 개선폭: **{ci12.improvement*100:.2f}%p** (95% CI {ci12.CI_low*100:.2f}~{ci12.CI_high*100:.2f}%p)

## 개발 시드 후보 선택

선택 기준은 개발 시드 3개의 8~12주 미질문 WAPE입니다. 최종 홀드아웃은 선택에 사용하지 않았습니다.
다만 모든 후보의 `improvement_vs_immediate`가 음수였으므로, 실제 승격 게이트에서는 후보를 선택하지 않고 즉시 보정 모델을 유지해야 합니다. 아래 홀드아웃 평가는 가장 덜 나빴던 후보의 일반화 여부를 확인한 진단 결과입니다.

{leaderboard.to_markdown(index=False, floatfmt='.4f')}

## 최종 홀드아웃 8주·12주 결과

{final_points.to_markdown(index=False, floatfmt='.4f')}

## 시나리오별 개선폭

{checkpoints.to_markdown(index=False, floatfmt='.4f')}

## 과적합 방지 계약

1. 이전 평가 사용자 100명과 이전 시드 결과는 최종 판정에서 제외.
2. 개발 시드 `{DEV_SEEDS}`에서 사전 등록한 후보 7개만 비교.
3. 최종 시드 `{[h['seed'] for h in HOLDOUTS]}`는 후보 선택 후 한 번만 평가.
4. 최종 평가에 기본, 낮은 응답 품질, 약한 생활변화 시나리오를 각각 포함.
5. 현재 주 질문 카테고리는 모든 조건의 주지표에서 제외.
6. 현재 주 피드백은 평가가 끝난 뒤 저장해 다음 주부터만 사용.
7. 8주와 12주를 모두 보고하고 유리한 시점만 선택하지 않음.
8. 사용자 단위 bootstrap 95% 신뢰구간이 0을 넘을 때만 일반화로 인정.
9. 개발 데이터에서 기준 모델보다 좋아지지 않으면 홀드아웃 결과와 무관하게 배포하지 않음.

## 남는 한계

- 시드를 분리해도 같은 합성 생성기 계열이라는 한계는 남음.
- 최종 세 시나리오는 생성기 과적합을 줄이지만 실제 행동·응답 편향을 대체하지 못함.
- 실제 사용자 20~50명의 12주 파일럿에서 동일 프로토콜을 재현하기 전에는 제품 가능성 증거로만 표현해야 함.
"""


def main() -> None:
    dev_parts = []
    base_scenario = {"scenario": "개발"}
    for seed in DEV_SEEDS:
        dev_parts.append(run_seed(seed, base_scenario, CANDIDATES))
    dev = pd.concat(dev_parts, ignore_index=True)
    selected, leaderboard = select_candidate(dev)
    print(f"선택 후보: {selected}", flush=True)

    final_parts = []
    for scenario in HOLDOUTS:
        final_parts.append(run_seed(scenario["seed"], scenario, [selected]))
    final = pd.concat(final_parts, ignore_index=True)
    summary = summarize_final(final, selected)
    interval_rows = []
    for week in range(1, APP_WEEKS + 1):
        point, low, high = bootstrap_final(final, selected, week)
        interval_rows.append({
            "사용주차": week, "improvement": point, "CI_low": low, "CI_high": high,
        })
    intervals = pd.DataFrame(interval_rows)
    checkpoints = scenario_checkpoints(summary)

    OUT.mkdir(parents=True, exist_ok=True)
    dev.to_csv(OUT / "development_predictions.csv", index=False)
    final.to_csv(OUT / "holdout_predictions.csv", index=False)
    leaderboard.to_csv(OUT / "development_leaderboard.csv", index=False)
    summary.to_csv(OUT / "holdout_summary.csv", index=False)
    intervals.to_csv(OUT / "holdout_bootstrap_intervals.csv", index=False)
    checkpoints.to_csv(OUT / "scenario_checkpoints.csv", index=False)
    (OUT / "results.md").write_text(
        report(selected, leaderboard, summary, intervals, checkpoints), encoding="utf-8",
    )
    make_figures(summary, intervals, checkpoints)
    print((OUT / "results.md").resolve())


if __name__ == "__main__":
    main()
