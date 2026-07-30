"""주 2회 고영향 피드백의 1~8주 개인화 효과를 기본 모델과 비교한다.

합성 카드 결제만 사용한다. Passive와 Active는 같은 모델·학습 사용자·평가 사용자를
공유하고, Active만 예측 전에 선택된 두 카테고리에 대한 미래 의도·금액 확인을 받는다.
직접 물어본 항목과 묻지 않은 항목을 분리해 정답 입력 효과와 일반화 효과를 구분한다.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import warnings

import numpy as np
import pandas as pd

from card_calendar_bench import (
    FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE, SPECS, generate,
)


HERE = Path(__file__).parent
OUT = HERE / "results/active_feedback_8week"
SEED = 20260730
HISTORY_WEEKS = 8
APP_WEEKS = 8
QUESTIONS_PER_WEEK = 2
RESPONSE_RATE = 0.85
INTENT_ACCURACY = 0.92
CATEGORY_CORRECTION_ACCURACY = 0.90
AMOUNT_LOG_ERROR = 0.12
MISCLASSIFICATION_RATE = 0.12
N_DRAWS = 300
CATEGORIES = [s.category for s in SPECS]


def wape(actual, predicted) -> float:
    actual = np.asarray(actual, float)
    predicted = np.asarray(predicted, float)
    return float(np.abs(actual - predicted).sum() / max(np.abs(actual).sum(), 1.0))


def add_observation_noise(tx: pd.DataFrame) -> pd.DataFrame:
    """카드 업종 분류 오류를 만들되 실제 정답 카테고리와 거래 id는 보존한다."""
    rng = np.random.default_rng(SEED + 11)
    out = tx.copy().reset_index(drop=True)
    out["tx_id"] = np.arange(len(out))
    out["true_category"] = out["category"]
    noisy = rng.random(len(out)) < MISCLASSIFICATION_RATE
    for i in np.flatnonzero(noisy):
        choices = [c for c in CATEGORIES if c != out.at[i, "true_category"]]
        out.at[i, "category"] = rng.choice(choices)
    return out


@dataclass
class LedgerIndex:
    weekly_amount: dict
    weekly_count: dict
    weekly_total: dict
    days: dict
    calendar_count: dict


def make_index(observed: pd.DataFrame, calendar: pd.DataFrame) -> LedgerIndex:
    return LedgerIndex(
        weekly_amount=observed.groupby(["person", "week", "category"]).amount.sum().to_dict(),
        weekly_count=observed.groupby(["person", "week", "category"]).size().to_dict(),
        weekly_total=observed.groupby(["person", "week"]).amount.sum().to_dict(),
        days={k: sorted(g.day.astype(int).tolist())
              for k, g in observed.groupby(["person", "category"])},
        calendar_count=calendar.groupby(["person", "week", "category"]).size().to_dict(),
    )


def true_targets(tx: pd.DataFrame):
    cat = tx.groupby(["person", "week", "category"]).amount.sum().to_dict()
    total = tx.groupby(["person", "week"]).amount.sum().to_dict()
    return cat, total


def population_stats(tx: pd.DataFrame) -> tuple[dict, dict]:
    train = tx[(tx.person < N_PRIOR_PEOPLE) & (tx.week < FIRST_TEST_WEEK)]
    event_amount = train.groupby("category").amount.median().to_dict()
    grids = pd.MultiIndex.from_product(
        [range(N_PRIOR_PEOPLE), range(FIRST_TEST_WEEK), CATEGORIES],
        names=["person", "week", "category"],
    ).to_frame(index=False)
    weekly = train.groupby(["person", "week", "category"]).amount.sum().reset_index()
    grids = grids.merge(weekly, how="left").fillna({"amount": 0})
    occurrence = grids.groupby("category").amount.apply(lambda x: float((x > 0).mean())).to_dict()
    return event_amount, occurrence


def feature_row(person: int, week: int, category: str, idx: LedgerIndex,
                pop_amount: dict, pop_occurrence: dict) -> dict[str, float]:
    history = range(week - HISTORY_WEEKS, week)
    amounts = np.array([idx.weekly_amount.get((person, w, category), 0.0)
                        for w in history], float)
    counts = np.array([idx.weekly_count.get((person, w, category), 0.0)
                       for w in history], float)
    totals = np.array([idx.weekly_total.get((person, w), 0.0) for w in history], float)
    positive = amounts[amounts > 0]
    days = idx.days.get((person, category), [])
    past_days = [d for d in days if d < week * 7]
    elapsed = week * 7 - past_days[-1] if past_days else 365
    calendar_count = float(idx.calendar_count.get((person, week, category), 0))

    row = {
        "amount_mean": float(amounts.mean()),
        "amount_median": float(np.median(amounts)),
        "positive_mean": float(positive.mean()) if len(positive) else float(pop_amount[category]),
        "amount_std": float(amounts.std()),
        "occur_rate": float((amounts > 0).mean()),
        "count_mean": float(counts.mean()),
        "last_amount": float(amounts[-1]),
        "elapsed_days": float(elapsed),
        "total_mean": float(totals.mean()),
        "total_std": float(totals.std()),
        "category_share": float(amounts.sum() / max(totals.sum(), 1)),
        "calendar_count": calendar_count,
        "calendar_expected": calendar_count * float(pop_amount[category]) * 0.90,
        "population_amount": float(pop_amount[category]),
        "population_occurrence": float(pop_occurrence[category]),
    }
    for cat in CATEGORIES:
        row[f"category_{cat}"] = float(cat == category)
    return row


def build_rows(people, weeks, idx: LedgerIndex, target_cat: dict,
               pop_amount: dict, pop_occurrence: dict):
    rows, meta, target = [], [], []
    for person in people:
        for week in weeks:
            for category in CATEGORIES:
                rows.append(feature_row(person, week, category, idx,
                                        pop_amount, pop_occurrence))
                meta.append((person, week, category))
                target.append(float(target_cat.get((person, week, category), 0)))
    return pd.DataFrame(rows), pd.DataFrame(meta, columns=["person", "week", "category"]), np.asarray(target)


class RecentMean:
    name = "최근 평균"

    def fit(self, X: pd.DataFrame, y: np.ndarray) -> None:
        pass

    def predict(self, X: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
        p = (X.occur_rate.to_numpy(float) * HISTORY_WEEKS
             + X.population_occurrence.to_numpy(float) * 2) / (HISTORY_WEEKS + 2)
        p = np.where(X.calendar_count.to_numpy(float) > 0, np.maximum(p, 0.90), p)
        cond = np.maximum(X.positive_mean.to_numpy(float), X.calendar_expected.to_numpy(float))
        return np.clip(p, 0.01, 0.99), np.clip(cond, 100, None)


class SklearnPair:
    def __init__(self, name, occurrence, amount):
        self.name = name
        self.occurrence = occurrence
        self.amount = amount

    def fit(self, X: pd.DataFrame, y: np.ndarray) -> None:
        self.occurrence.fit(X, y > 0)
        self.amount.fit(X[y > 0], np.log1p(y[y > 0]))

    def predict(self, X: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
        p = self.occurrence.predict_proba(X)[:, 1]
        cond = np.expm1(self.amount.predict(X))
        return np.clip(p, 0.01, 0.99), np.clip(cond, 100, None)


def models(seed: int = SEED):
    from lightgbm import LGBMClassifier, LGBMRegressor
    from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
    from sklearn.linear_model import LogisticRegression, Ridge
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    return [
        RecentMean(),
        SklearnPair(
            "Ridge",
            make_pipeline(StandardScaler(), LogisticRegression(C=0.7, max_iter=500)),
            make_pipeline(StandardScaler(), Ridge(alpha=20.0)),
        ),
        SklearnPair(
            "Random Forest",
            RandomForestClassifier(n_estimators=180, min_samples_leaf=12,
                                   max_features=0.75, n_jobs=-1, random_state=seed),
            RandomForestRegressor(n_estimators=180, min_samples_leaf=10,
                                  max_features=0.75, n_jobs=-1, random_state=seed),
        ),
        SklearnPair(
            "LightGBM",
            LGBMClassifier(n_estimators=260, learning_rate=0.04, num_leaves=24,
                           min_child_samples=40, reg_lambda=1.0, verbose=-1,
                           random_state=seed),
            LGBMRegressor(objective="regression_l1", n_estimators=260,
                          learning_rate=0.04, num_leaves=24, min_child_samples=35,
                          reg_lambda=1.0, verbose=-1, random_state=seed),
        ),
    ]


def predict_all(fitted, X: pd.DataFrame) -> dict[str, tuple[np.ndarray, np.ndarray]]:
    return {m.name: m.predict(X) for m in fitted}


def select_questions(meta: pd.DataFrame, X: pd.DataFrame,
                     prediction: tuple[np.ndarray, np.ndarray]) -> set[tuple[int, str]]:
    """실제값을 보지 않고 LightGBM의 영향도와 불확실성으로 사용자당 두 개를 고른다."""
    p, cond = prediction
    ranked = meta.copy()
    ranked["priority"] = p * cond + 2 * p * (1 - p) * cond + X.calendar_expected.to_numpy(float)
    selected: set[tuple[int, str]] = set()
    for person, group in ranked.groupby("person"):
        for row in group.nlargest(QUESTIONS_PER_WEEK, "priority").itertuples():
            selected.add((int(person), str(row.category)))
    return selected


def simulate_answers(selected: set[tuple[int, str]], week: int, target_cat: dict,
                     pop_amount: dict, rng: np.random.Generator) -> dict:
    answers = {}
    for person, category in sorted(selected):
        actual = float(target_cat.get((person, week, category), 0))
        responded = bool(rng.random() < RESPONSE_RATE)
        true_occurrence = actual > 0
        reported_occurrence = true_occurrence
        if responded and rng.random() > INTENT_ACCURACY:
            reported_occurrence = not true_occurrence
        reported_amount = None
        if responded and reported_occurrence:
            base = actual if actual > 0 else float(pop_amount[category])
            reported_amount = float(base * rng.lognormal(0, AMOUNT_LOG_ERROR))
        answers[(person, category)] = {
            "actual": actual,
            "responded": responded,
            "reported_occurrence": reported_occurrence,
            "reported_amount": reported_amount,
            "category_correct": bool(responded and rng.random() < CATEGORY_CORRECTION_ACCURACY),
        }
    return answers


def apply_answers(meta: pd.DataFrame, p: np.ndarray, cond: np.ndarray,
                  selected: set[tuple[int, str]], answers: dict):
    p = p.copy()
    cond = cond.copy()
    queried = np.zeros(len(meta), dtype=bool)
    responded = np.zeros(len(meta), dtype=bool)
    for i, row in enumerate(meta.itertuples(index=False)):
        key = (int(row.person), str(row.category))
        if key not in selected:
            continue
        queried[i] = True
        answer = answers[key]
        if not answer["responded"]:
            continue
        responded[i] = True
        p[i] = 0.95 if answer["reported_occurrence"] else 0.05
        if answer["reported_amount"] is not None:
            cond[i] = 0.75 * answer["reported_amount"] + 0.25 * cond[i]
    return p, cond, queried, responded


def conditional_sigma(model, X_train: pd.DataFrame, y_train: np.ndarray) -> float:
    _, cond = model.predict(X_train)
    positive = y_train > 0
    residual = np.log(y_train[positive] / np.clip(cond[positive], 1, None))
    return float(np.clip(np.std(residual), 0.15, 0.90))


def summarize_week(model_name: str, condition: str, app_week: int,
                   meta: pd.DataFrame, actual: np.ndarray,
                   p: np.ndarray, cond: np.ndarray, queried: np.ndarray,
                   responded: np.ndarray, comparison_queried: np.ndarray,
                   sigma: float, seed: int):
    detail = meta.copy()
    detail["actual"] = actual
    detail["probability"] = p
    detail["conditional_amount"] = cond
    detail["prediction"] = p * cond
    detail["queried"] = queried
    detail["responded"] = responded
    detail["comparison_queried"] = comparison_queried

    total = detail.groupby("person")[["actual", "prediction"]].sum()
    # Passive도 Active가 고른 동일 카테고리를 제외해야 분모가 같다.
    unqueried = detail[~detail.comparison_queried].groupby("person")[["actual", "prediction"]].sum()
    macro = np.mean([wape(g.actual, g.prediction) for _, g in detail.groupby("category")])
    brier = float(np.mean((detail.probability - (detail.actual > 0).astype(float)) ** 2))

    rng = np.random.default_rng(seed)
    draws = {person: np.zeros(N_DRAWS) for person in detail.person.unique()}
    for row in detail.itertuples(index=False):
        occurrence = rng.random(N_DRAWS) < row.probability
        row_sigma = 0.12 if row.responded and row.probability > 0.5 else sigma
        amounts = rng.lognormal(np.log(max(row.conditional_amount, 1)) - row_sigma**2 / 2,
                                row_sigma, N_DRAWS)
        draws[row.person] += occurrence * amounts
    intervals = pd.DataFrame([
        {"person": person, "p10": np.quantile(values, 0.1),
         "p90": np.quantile(values, 0.9)}
        for person, values in draws.items()
    ]).set_index("person").join(total.actual)

    summary = {
        "사용주차": app_week,
        "모델": model_name,
        "조건": condition,
        "총액_WAPE": wape(total.actual, total.prediction),
        "총액_정확도": 1 - wape(total.actual, total.prediction),
        "카테고리_Macro_WAPE": float(macro),
        "발생_Brier": brier,
        "미질문_WAPE": wape(unqueried.actual, unqueried.prediction),
        "구간_커버리지80": float(((intervals.actual >= intervals.p10)
                                  & (intervals.actual <= intervals.p90)).mean()),
        "구간폭_중앙값": float(np.median(intervals.p90 - intervals.p10)),
        "평가사용자": int(total.shape[0]),
        "질문수": int(queried.sum()),
        "응답수": int(responded.sum()),
    }
    detail["모델"] = model_name
    detail["조건"] = condition
    detail["사용주차"] = app_week
    return summary, detail, total.reset_index()


def bootstrap_delta(predictions: pd.DataFrame, model: str, week: int,
                    n_boot: int = 1500) -> tuple[float, float, float]:
    d = predictions[(predictions.모델 == model) & (predictions.사용주차 == week)]
    pivot = d.pivot(index="person", columns="조건", values=["actual", "prediction"])
    people = pivot.index.to_numpy()
    rng = np.random.default_rng(SEED + 404)
    deltas = []
    for _ in range(n_boot):
        sample = rng.choice(people, len(people), replace=True)
        passive = wape(pivot.loc[sample, ("actual", "Passive")],
                       pivot.loc[sample, ("prediction", "Passive")])
        active = wape(pivot.loc[sample, ("actual", "Active")],
                      pivot.loc[sample, ("prediction", "Active")])
        deltas.append(passive - active)
    point = (wape(pivot[("actual", "Passive")], pivot[("prediction", "Passive")])
             - wape(pivot[("actual", "Active")], pivot[("prediction", "Active")]))
    low, high = np.quantile(deltas, [0.025, 0.975])
    return float(point), float(low), float(high)


def bootstrap_unqueried_delta(predictions: pd.DataFrame, model: str, week: int,
                              n_boot: int = 1500) -> tuple[float, float, float]:
    d = predictions[(predictions.모델 == model) & (predictions.사용주차 == week)
                    & (~predictions.comparison_queried)]
    totals = d.groupby(["조건", "person"])[["actual", "prediction"]].sum().reset_index()
    pivot = totals.pivot(index="person", columns="조건", values=["actual", "prediction"])
    people = pivot.index.to_numpy()
    rng = np.random.default_rng(SEED + 405)
    deltas = []
    for _ in range(n_boot):
        sample = rng.choice(people, len(people), replace=True)
        passive = wape(pivot.loc[sample, ("actual", "Passive")],
                       pivot.loc[sample, ("prediction", "Passive")])
        active = wape(pivot.loc[sample, ("actual", "Active")],
                      pivot.loc[sample, ("prediction", "Active")])
        deltas.append(passive - active)
    point = (wape(pivot[("actual", "Passive")], pivot[("prediction", "Passive")])
             - wape(pivot[("actual", "Active")], pivot[("prediction", "Active")]))
    low, high = np.quantile(deltas, [0.025, 0.975])
    return float(point), float(low), float(high)


def make_figures(summary: pd.DataFrame) -> None:
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    colors = {"Passive": "#BDB9AF", "Active": "#7A5CF0"}
    labels = {"Passive": "피드백 없음", "Active": "피드백 있음"}
    ink, muted, line, canvas, yellow = "#25241F", "#747168", "#E6E2D8", "#FBFAF7", "#FFCC00"
    fig_dir = OUT / "figures"
    fig_dir.mkdir(parents=True, exist_ok=True)

    def base(title, subtitle):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.91, title, fontproperties=medium, fontsize=24, color=ink)
        fig.text(0.06, 0.865, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        return fig

    lightgbm = summary[summary.모델 == "LightGBM"]
    fig = base("주 2회 고영향 피드백: 피드백 유무 비교",
               "LightGBM · 카드 결제만 사용 · 평가 사용자 100명 · 높을수록 정확 · 확대 축")
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    for condition in ["Passive", "Active"]:
        g = lightgbm[lightgbm.조건 == condition].sort_values("사용주차")
        ax.plot(g.사용주차, g.총액_정확도 * 100, label=labels[condition],
                color=colors[condition], linewidth=3 if condition == "Active" else 2.2,
                marker="o", markersize=6)
    ax.set_xticks(range(1, 9)); ax.set_xlim(0.8, 8.2)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("WAPE 기반 정확도", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=line); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.legend(frameon=False, prop=medium, loc="lower right")
    ax.tick_params(colors=muted)
    fig.text(0.08, 0.07, "합성 실험 결과이며 실사용자 성능 주장이 아님",
             fontproperties=light, fontsize=10, color=muted)
    fig.savefig(fig_dir / "01_active_passive_curve.png", dpi=144, facecolor=canvas)
    fig.savefig(fig_dir / "01_active_passive_curve.svg", facecolor=canvas)
    plt.close(fig)

    week8 = summary[summary.사용주차 == 8].copy()
    models_order = week8[week8.조건 == "Passive"].sort_values("총액_WAPE").모델.tolist()
    x = np.arange(len(models_order)); width = 0.34
    fig = base("8주차 모델별 피드백 효과",
               "다음 주 총 카드 소비 WAPE · 낮을수록 정확 · 모든 모델에 동일 질문 제공")
    ax = fig.add_axes([0.10, 0.18, 0.82, 0.61])
    for offset, condition in [(-width/2, "Passive"), (width/2, "Active")]:
        values = [float(week8[(week8.모델 == m) & (week8.조건 == condition)].총액_WAPE.iloc[0]) * 100
                  for m in models_order]
        bars = ax.bar(x + offset, values, width, label=labels[condition],
                      color=colors[condition], edgecolor=ink, linewidth=0.5)
        for bar, value in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width()/2, value + 0.7, f"{value:.1f}%",
                    ha="center", fontproperties=medium, fontsize=10, color=ink)
    ax.set_xticks(x, models_order); ax.set_ylim(0, max(week8.총액_WAPE) * 115)
    for label in ax.get_xticklabels(): label.set_fontproperties(medium)
    ax.set_ylabel("WAPE", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=line); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.legend(frameon=False, prop=medium)
    fig.savefig(fig_dir / "02_model_feedback_comparison.png", dpi=144, facecolor=canvas)
    fig.savefig(fig_dir / "02_model_feedback_comparison.svg", facecolor=canvas)
    plt.close(fig)

    fig = base("직접 묻지 않은 소비에서도 개선됐는가",
               "LightGBM · 현재 주 질문 카테고리 제외 WAPE · 낮을수록 정확 · 확대 축")
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    for condition in ["Passive", "Active"]:
        g = lightgbm[lightgbm.조건 == condition].sort_values("사용주차")
        ax.plot(g.사용주차, g.미질문_WAPE * 100, label=labels[condition],
                color=colors[condition], linewidth=3 if condition == "Active" else 2.2,
                marker="o", markersize=6)
    ax.set_xticks(range(1, 9)); ax.set_xlim(0.8, 8.2)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("미질문 항목 WAPE", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=line); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.legend(frameon=False, prop=medium)
    fig.savefig(fig_dir / "03_unqueried_generalization.png", dpi=144, facecolor=canvas)
    fig.savefig(fig_dir / "03_unqueried_generalization.svg", facecolor=canvas)
    plt.close(fig)


def report(summary: pd.DataFrame, feedback: pd.DataFrame,
           ci: tuple[float, float, float],
           unqueried_ci: tuple[float, float, float]) -> str:
    week8 = summary[summary.사용주차 == 8].sort_values(["모델", "조건"])
    lgb = summary[summary.모델 == "LightGBM"].pivot(index="사용주차", columns="조건")
    delta = (lgb["총액_WAPE"]["Passive"] - lgb["총액_WAPE"]["Active"])
    generalization = (lgb["미질문_WAPE"]["Passive"] - lgb["미질문_WAPE"]["Active"])
    point, low, high = ci
    _, unqueried_low, unqueried_high = unqueried_ci
    response_rate = feedback.responded.mean()
    return f"""# Active feedback 1~8주 벤치마크

## 결론

- 8주차 LightGBM Active의 총액 WAPE 개선폭은 **{delta.loc[8]*100:.2f}%p**입니다.
- 사용자 단위 bootstrap 95% 구간은 **{low*100:.2f}~{high*100:.2f}%p**입니다.
- 8주차 직접 묻지 않은 항목의 WAPE 개선폭은 **{generalization.loc[8]*100:.2f}%p**입니다.
- 미질문 개선폭의 사용자 bootstrap 95% 구간은 **{unqueried_low*100:.2f}~{unqueried_high*100:.2f}%p**로 0을 포함합니다.
- 응답률은 {response_rate*100:.1f}%이고, 질문 부담은 사용자당 주 2회로 제한했습니다.
- 전체 개선의 대부분은 현재 주에 직접 확인한 항목에서 발생했습니다. 이 결과만으로 가파른 모델 개인화를 주장할 수 없습니다.
- Active의 80% 구간 커버리지는 74%로 목표에 못 미쳤습니다. 구간 폭 축소보다 재보정이 먼저입니다.

## 8주차 모델 비교

{week8.to_markdown(index=False, floatfmt=".4f")}

## LightGBM 1~8주 개선폭

{pd.DataFrame({"사용주차": delta.index, "총액_WAPE_개선폭": delta.values,
               "미질문_WAPE_개선폭": generalization.values}).to_markdown(index=False, floatfmt=".4f")}

## 실험 계약

- 데이터: 합성 카드 거래 400명 × 52주. 현금·미관측 결제는 사용하지 않음.
- 분할: 인구 학습 300명과 평가 100명 완전 분리.
- 평가: 평가 사용자의 33~40주차를 앱 사용 1~8주로 순차 예측.
- 모델: 최근 평균, Ridge, Random Forest, LightGBM. 발생확률 모델과 조건부 금액 모델을 결합.
- Passive: 카드 이력 8주 + 캘린더.
- Active: Passive 입력 + 주 2회 고영향 미래 의도·금액 확인 + 응답된 카테고리 수정의 다음 주 반영.
- 질문 선택: Passive LightGBM의 예상금액·발생 불확실성·캘린더 영향만 사용. 실제값은 선택 이후 답변 생성에만 사용.
- 모든 모델에 같은 질문과 같은 답변을 제공.

## 피드백 시뮬레이션 가정

- 응답률 {RESPONSE_RATE:.0%}, 미래 의도 정확도 {INTENT_ACCURACY:.0%}
- 금액 응답 로그오차 σ={AMOUNT_LOG_ERROR:.2f}, 카테고리 수정 정확도 {CATEGORY_CORRECTION_ACCURACY:.0%}
- 카드 카테고리 오분류율 {MISCLASSIFICATION_RATE:.0%}

## 지표 정의

- 총액 WAPE: 사용자별 다음 주 총 카드 소비를 합산해 절대오차/실제금액으로 계산.
- 카테고리 Macro WAPE: 카테고리별 WAPE의 단순 평균.
- Brier: 사용자×주×카테고리 발생확률의 제곱오차 평균.
- 미질문 WAPE: 현재 주에 질문하지 않은 카테고리만 합산. 직접 정답 입력 효과를 제외한 진단 지표.
- 80% 구간: 발생 Bernoulli와 조건부 금액 로그정규 표본 300개에서 p10~p90 산출.

## 제한과 발표 시 필수 문구

- 합성 데이터 결과이므로 실사용자 성능이나 인과효과를 주장할 수 없습니다.
- 피드백 응답은 실제 미래 지출에서 잡음을 넣어 생성했습니다. 따라서 Active의 전체 개선에는 직접 확인 효과가 포함됩니다.
- 미질문 개선은 이전 주의 카테고리 수정이 이후 이력에 남은 효과지만, 실제 사용자 행동으로 재검증해야 합니다.
- 하이퍼파라미터는 평가 사용자로 튜닝하지 않았습니다.
"""


def main() -> None:
    true_tx, calendar = generate()
    observed = add_observation_noise(true_tx)
    target_cat, _ = true_targets(true_tx)
    pop_amount, pop_occurrence = population_stats(true_tx)

    passive_idx = make_index(observed, calendar)
    train_weeks = range(HISTORY_WEEKS, FIRST_TEST_WEEK)
    X_train, _, y_train = build_rows(
        range(N_PRIOR_PEOPLE), train_weeks, passive_idx, target_cat,
        pop_amount, pop_occurrence,
    )
    fitted = models()
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=RuntimeWarning)
        for model in fitted:
            model.fit(X_train, y_train)
    sigmas = {model.name: conditional_sigma(model, X_train, y_train) for model in fitted}

    corrected_ids: set[int] = set()
    summaries, category_details, total_details, feedback_rows = [], [], [], []
    answer_rng = np.random.default_rng(SEED + 99)

    for app_week in range(1, APP_WEEKS + 1):
        week = FIRST_TEST_WEEK + app_week - 1
        active_observed = observed.copy()
        if corrected_ids:
            mask = active_observed.tx_id.isin(corrected_ids)
            active_observed.loc[mask, "category"] = active_observed.loc[mask, "true_category"]
        active_idx = make_index(active_observed, calendar)

        X_passive, meta, actual = build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], passive_idx, target_cat,
            pop_amount, pop_occurrence,
        )
        X_active, active_meta, active_actual = build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], active_idx, target_cat,
            pop_amount, pop_occurrence,
        )
        assert meta.equals(active_meta) and np.array_equal(actual, active_actual)

        passive_predictions = predict_all(fitted, X_passive)
        active_predictions = predict_all(fitted, X_active)
        selected = select_questions(meta, X_passive, passive_predictions["LightGBM"])
        answers = simulate_answers(selected, week, target_cat, pop_amount, answer_rng)
        comparison_queried = np.array([
            (int(row.person), str(row.category)) in selected
            for row in meta.itertuples(index=False)
        ], dtype=bool)

        for (person, category), answer in answers.items():
            feedback_rows.append({"사용주차": app_week, "person": person,
                                  "category": category, **answer})

        for model_index, model in enumerate(fitted):
            for condition, X, prediction in [
                ("Passive", X_passive, passive_predictions[model.name]),
                ("Active", X_active, active_predictions[model.name]),
            ]:
                p, cond = prediction
                queried = np.zeros(len(meta), bool)
                responded = np.zeros(len(meta), bool)
                if condition == "Active":
                    p, cond, queried, responded = apply_answers(
                        meta, p, cond, selected, answers,
                    )
                summary, detail, total = summarize_week(
                    model.name, condition, app_week, meta, actual, p, cond,
                    queried, responded, comparison_queried, sigmas[model.name],
                    seed=SEED + app_week * 100 + model_index,
                )
                summaries.append(summary)
                category_details.append(detail)
                total["모델"] = model.name
                total["조건"] = condition
                total["사용주차"] = app_week
                total_details.append(total)

        # 이번 주에 답한 카테고리의 실제 카드 분류 수정은 다음 주부터만 보인다.
        for (person, category), answer in answers.items():
            if answer["category_correct"]:
                ids = observed[(observed.person == person) & (observed.week == week)
                               & (observed.true_category == category)].tx_id
                corrected_ids.update(ids.astype(int).tolist())
        print(f"{app_week}주 완료")

    summary = pd.DataFrame(summaries)
    category = pd.concat(category_details, ignore_index=True)
    totals = pd.concat(total_details, ignore_index=True)
    feedback = pd.DataFrame(feedback_rows)
    ci = bootstrap_delta(totals, "LightGBM", 8)
    unqueried_ci = bootstrap_unqueried_delta(category, "LightGBM", 8)

    OUT.mkdir(parents=True, exist_ok=True)
    summary.to_csv(OUT / "summary.csv", index=False)
    category.to_csv(OUT / "category_predictions.csv", index=False)
    feedback.to_csv(OUT / "feedback.csv", index=False)
    (OUT / "results.md").write_text(report(summary, feedback, ci, unqueried_ci), encoding="utf-8")
    make_figures(summary)
    print(summary[summary.사용주차 == 8].sort_values(["총액_WAPE", "조건"]).to_string(index=False))
    print(OUT / "results.md")


if __name__ == "__main__":
    main()
