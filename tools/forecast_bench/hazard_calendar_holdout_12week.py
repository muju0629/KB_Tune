"""다음 7일 소비 발생·결제일·주기를 일별 hazard로 검증한다.

금액은 예측하지 않는다. 합성 카드 결제와 이미 등록된 캘린더 일정만 사용한다.
학습 240명, 확률 보정 60명, 신규 평가 100명을 사용자 단위로 완전히 분리하고
세 개의 신규 생성 시드에서 12주 롤링 평가한다.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

import active_feedback_bench as base
import card_calendar_bench as generator


HERE = Path(__file__).parent
OUT = HERE / "results/hazard_calendar_holdout_12week"
SEEDS = [20270121, 20270122, 20270123]
TRAIN_PEOPLE = range(0, 240)
CALIBRATION_PEOPLE = range(240, 300)
EVALUATION_PEOPLE = range(300, 400)
TRAIN_WEEKS = range(base.HISTORY_WEEKS, generator.FIRST_TEST_WEEK)
CALIBRATION_WEEKS = range(generator.FIRST_TEST_WEEK - 8, generator.FIRST_TEST_WEEK)
EVALUATION_WEEKS = range(generator.FIRST_TEST_WEEK, generator.FIRST_TEST_WEEK + 12)
CATEGORIES = [spec.category for spec in generator.SPECS]
SCHEDULED = {spec.category for spec in generator.SPECS if spec.kind == "scheduled"}
MODELS = ["주기 기준선", "주간 LightGBM", "일별 Hazard", "Hazard + 캘린더"]
CALENDAR_COLUMNS = ["calendar_count", "calendar_expected", "calendar_today", "calendar_near"]


def population_stats(tx: pd.DataFrame) -> tuple[dict, dict]:
    train = tx[(tx.person.isin(TRAIN_PEOPLE)) & (tx.week < generator.FIRST_TEST_WEEK)]
    amount = train.groupby("category").amount.median().to_dict()
    grids = pd.MultiIndex.from_product(
        [TRAIN_PEOPLE, range(generator.FIRST_TEST_WEEK), CATEGORIES],
        names=["person", "week", "category"],
    ).to_frame(index=False)
    weekly = train.groupby(["person", "week", "category"]).amount.sum().reset_index()
    grids = grids.merge(weekly, how="left").fillna({"amount": 0})
    occurrence = grids.groupby("category").amount.apply(lambda x: float((x > 0).mean())).to_dict()
    return amount, occurrence


def first_event_lookup(tx: pd.DataFrame) -> dict[tuple[int, int, str], int]:
    first = tx.groupby(["person", "week", "category"]).day.min()
    return {(int(p), int(w), str(c)): int(day) for (p, w, c), day in first.items()}


def weekly_rows(people, weeks, index, targets, pop_amount, pop_occurrence):
    X, meta, amount = base.build_rows(
        people, weeks, index, targets, pop_amount, pop_occurrence,
    )
    return X, meta, (amount > 0).astype(int)


def history_features(person: int, week: int, category: str, index) -> dict[str, float]:
    start = week * 7
    days = np.asarray([d for d in index.days.get((person, category), []) if d < start], int)
    recent = days[days >= start - base.HISTORY_WEEKS * 7]
    gaps = np.diff(days[-9:]) if len(days) >= 2 else np.asarray([], float)
    median_gap = float(np.median(gaps)) if len(gaps) else 28.0
    gap_cv = float(np.std(gaps) / max(np.mean(gaps), 1)) if len(gaps) >= 2 else 1.0
    modal_weekday = int(pd.Series(days % 7).mode().iloc[0]) if len(days) else 0
    return {
        "last_day": float(days[-1]) if len(days) else np.nan,
        "median_gap": median_gap,
        "gap_cv": gap_cv,
        "event_count": float(len(recent)),
        "modal_weekday": float(modal_weekday),
    }


def day_row(person: int, week: int, category: str, offset: int, weekly: dict,
            history: dict, calendar_days: set[int]) -> dict[str, float]:
    absolute_day = week * 7 + offset
    last_day = history["last_day"]
    elapsed = absolute_day - last_day if np.isfinite(last_day) else 365.0
    row = dict(weekly)
    row.update({
        "weekday_sin": float(np.sin(2 * np.pi * offset / 7)),
        "weekday_cos": float(np.cos(2 * np.pi * offset / 7)),
        "days_since_last": float(elapsed),
        "median_gap": history["median_gap"],
        "gap_deviation": float(abs(elapsed - history["median_gap"])),
        "gap_cv": history["gap_cv"],
        "history_event_count": history["event_count"],
        "modal_weekday_match": float(offset == int(history["modal_weekday"])),
        "calendar_today": float(absolute_day in calendar_days),
        "calendar_near": float(any(abs(absolute_day - day) <= 1 for day in calendar_days)),
    })
    return row


def daily_rows(people, weeks, index, first_events, pop_amount, pop_occurrence,
               calendar: pd.DataFrame, training: bool):
    calendar_lookup = {
        (int(p), int(w), str(c)): set(g.day.astype(int))
        for (p, w, c), g in calendar.groupby(["person", "week", "category"])
    }
    rows, meta, targets = [], [], []
    for person in people:
        for week in weeks:
            for category in CATEGORIES:
                weekly = base.feature_row(
                    person, week, category, index, pop_amount, pop_occurrence,
                )
                history = history_features(person, week, category, index)
                event_day = first_events.get((person, week, category))
                event_offset = None if event_day is None else int(event_day - week * 7)
                final_offset = event_offset if training and event_offset is not None else 6
                calendar_days = calendar_lookup.get((person, week, category), set())
                for offset in range(final_offset + 1):
                    rows.append(day_row(
                        person, week, category, offset, weekly, history, calendar_days,
                    ))
                    meta.append((person, week, category, offset))
                    targets.append(int(event_offset is not None and offset == event_offset))
    return (
        pd.DataFrame(rows),
        pd.DataFrame(meta, columns=["person", "week", "category", "offset"]),
        np.asarray(targets, int),
    )


class WeeklyModel:
    def __init__(self, seed: int):
        from lightgbm import LGBMClassifier

        self.model = LGBMClassifier(
            n_estimators=220, learning_rate=0.04, num_leaves=24,
            min_child_samples=50, reg_lambda=1.5, verbose=-1,
            random_state=seed,
        )

    def fit(self, X: pd.DataFrame, y: np.ndarray):
        self.columns = [c for c in X.columns if c not in CALENDAR_COLUMNS]
        self.model.fit(X[self.columns], y)

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        return np.clip(self.model.predict_proba(X[self.columns])[:, 1], 0.001, 0.999)


class HazardModel:
    def __init__(self, seed: int, calendar: bool):
        from lightgbm import LGBMClassifier

        self.calendar = calendar
        self.model = LGBMClassifier(
            n_estimators=240, learning_rate=0.04, num_leaves=24,
            min_child_samples=60, reg_lambda=1.5, verbose=-1,
            random_state=seed,
        )

    def fit(self, X: pd.DataFrame, y: np.ndarray):
        self.columns = list(X.columns)
        if not self.calendar:
            self.columns = [c for c in self.columns if c not in CALENDAR_COLUMNS]
        self.model.fit(X[self.columns], y)

    def predict_week(self, X: pd.DataFrame, meta: pd.DataFrame) -> pd.DataFrame:
        hazard = np.clip(self.model.predict_proba(X[self.columns])[:, 1], 0.001, 0.999)
        raw = meta.copy()
        raw["hazard"] = hazard
        rows = []
        for key, group in raw.groupby(["person", "week", "category"], sort=False):
            group = group.sort_values("offset")
            h = group.hazard.to_numpy(float)
            survival_before = np.r_[1.0, np.cumprod(1 - h[:-1])]
            mass = survival_before * h
            rows.append((*key, float(1 - np.prod(1 - h)), int(group.offset.iloc[np.argmax(mass)])))
        return pd.DataFrame(rows, columns=["person", "week", "category", "raw_probability", "predicted_offset"])


class ProbabilityCalibrator:
    def fit(self, probability: np.ndarray, y: np.ndarray):
        from sklearn.linear_model import LogisticRegression

        p = np.clip(probability, 0.001, 0.999)
        self.model = LogisticRegression(C=1.0, max_iter=500)
        self.model.fit(np.log(p / (1 - p)).reshape(-1, 1), y)

    def predict(self, probability: np.ndarray) -> np.ndarray:
        p = np.clip(probability, 0.001, 0.999)
        return self.model.predict_proba(np.log(p / (1 - p)).reshape(-1, 1))[:, 1]


def heuristic_offset(person: int, week: int, category: str, index) -> int:
    start = week * 7
    history = history_features(person, week, category, index)
    if np.isfinite(history["last_day"]):
        candidate = int(round(history["last_day"] + history["median_gap"] - start))
        if 0 <= candidate <= 6:
            return candidate
    return int(history["modal_weekday"])


def recent_probability(meta: pd.DataFrame, X: pd.DataFrame) -> np.ndarray:
    return np.clip(
        (X.occur_rate.to_numpy(float) * base.HISTORY_WEEKS
         + X.population_occurrence.to_numpy(float) * 2) / (base.HISTORY_WEEKS + 2),
        0.001, 0.999,
    )


def heuristic_offsets(meta: pd.DataFrame, index) -> np.ndarray:
    return np.asarray([
        heuristic_offset(int(row.person), int(row.week), str(row.category), index)
        for row in meta.itertuples(index=False)
    ], int)


def raw_predictions(models, weekly_X, weekly_meta, daily_X, daily_meta, index):
    offsets = heuristic_offsets(weekly_meta, index)
    result = {
        "주기 기준선": (recent_probability(weekly_meta, weekly_X), offsets),
        "주간 LightGBM": (models["weekly"].predict(weekly_X), offsets),
    }
    for name, key in [("일별 Hazard", "hazard"), ("Hazard + 캘린더", "calendar")]:
        pred = models[key].predict_week(daily_X, daily_meta)
        merged = weekly_meta.merge(pred, on=["person", "week", "category"], validate="one_to_one")
        result[name] = (
            merged.raw_probability.to_numpy(float), merged.predicted_offset.to_numpy(int),
        )
    return result


def run_seed(seed: int) -> pd.DataFrame:
    generator.SEED = seed
    base.SEED = seed + 10_000
    true_tx, calendar = generator.generate()
    observed = base.add_observation_noise(true_tx)
    index = base.make_index(observed, calendar)
    target_amount, _ = base.true_targets(true_tx)
    pop_amount, pop_occurrence = population_stats(true_tx)
    first_events = first_event_lookup(true_tx)

    train_X, _, train_y = weekly_rows(
        TRAIN_PEOPLE, TRAIN_WEEKS, index, target_amount, pop_amount, pop_occurrence,
    )
    train_day_X, train_day_meta, train_day_y = daily_rows(
        TRAIN_PEOPLE, TRAIN_WEEKS, index, first_events, pop_amount, pop_occurrence,
        calendar, training=True,
    )
    models = {
        "weekly": WeeklyModel(seed),
        "hazard": HazardModel(seed, calendar=False),
        "calendar": HazardModel(seed, calendar=True),
    }
    models["weekly"].fit(train_X, train_y)
    models["hazard"].fit(train_day_X, train_day_y)
    models["calendar"].fit(train_day_X, train_day_y)

    cal_X, cal_meta, cal_y = weekly_rows(
        CALIBRATION_PEOPLE, CALIBRATION_WEEKS, index, target_amount,
        pop_amount, pop_occurrence,
    )
    cal_day_X, cal_day_meta, _ = daily_rows(
        CALIBRATION_PEOPLE, CALIBRATION_WEEKS, index, first_events,
        pop_amount, pop_occurrence, calendar, training=False,
    )
    cal_raw = raw_predictions(models, cal_X, cal_meta, cal_day_X, cal_day_meta, index)
    calibrators = {}
    for name, (probability, _) in cal_raw.items():
        calibrators[name] = ProbabilityCalibrator()
        calibrators[name].fit(probability, cal_y)

    eval_X, eval_meta, eval_y = weekly_rows(
        EVALUATION_PEOPLE, EVALUATION_WEEKS, index, target_amount,
        pop_amount, pop_occurrence,
    )
    eval_day_X, eval_day_meta, _ = daily_rows(
        EVALUATION_PEOPLE, EVALUATION_WEEKS, index, first_events,
        pop_amount, pop_occurrence, calendar, training=False,
    )
    predictions = raw_predictions(models, eval_X, eval_meta, eval_day_X, eval_day_meta, index)

    rows = []
    for name, (raw_probability, predicted_offset) in predictions.items():
        probability = calibrators[name].predict(raw_probability)
        for i, item in enumerate(eval_meta.itertuples(index=False)):
            key = (int(item.person), int(item.week), str(item.category))
            actual_day = first_events.get(key)
            history = history_features(*key, index)
            start = int(item.week) * 7
            rows.append({
                "seed": seed,
                "model": name,
                "person": int(item.person),
                "week": int(item.week),
                "app_week": int(item.week) - generator.FIRST_TEST_WEEK + 1,
                "category": str(item.category),
                "segment": "일정형" if item.category in SCHEDULED else "비일정형",
                "actual": int(eval_y[i]),
                "raw_probability": float(raw_probability[i]),
                "probability": float(probability[i]),
                "predicted_offset": int(predicted_offset[i]),
                "actual_offset": np.nan if actual_day is None else int(actual_day - start),
                "last_observed_day": history["last_day"],
            })
        print(f"seed {seed} · {name} 평가 완료", flush=True)
    detail = pd.DataFrame(rows)
    occurred = detail.actual.eq(1)
    has_last = detail.last_observed_day.notna() & occurred
    detail["date_error"] = np.where(
        occurred, np.abs(detail.predicted_offset - detail.actual_offset), np.nan,
    )
    detail["predicted_cycle"] = np.where(
        detail.last_observed_day.notna(),
        detail.week * 7 + detail.predicted_offset - detail.last_observed_day,
        np.nan,
    )
    detail["actual_cycle"] = np.where(
        has_last, detail.week * 7 + detail.actual_offset - detail.last_observed_day, np.nan,
    )
    detail["cycle_error"] = np.where(
        has_last, np.abs(detail.predicted_cycle - detail.actual_cycle), np.nan,
    )
    return detail


def expected_calibration_error(y: np.ndarray, probability: np.ndarray, bins: int = 10) -> float:
    edges = np.linspace(0, 1, bins + 1)
    ids = np.clip(np.digitize(probability, edges[1:-1]), 0, bins - 1)
    error = 0.0
    for bin_id in range(bins):
        selected = ids == bin_id
        if selected.any():
            error += selected.mean() * abs(probability[selected].mean() - y[selected].mean())
    return float(error)


def summarize(detail: pd.DataFrame, by_segment: bool = False) -> pd.DataFrame:
    from sklearn.metrics import average_precision_score

    group_columns = ["model", "segment"] if by_segment else ["model"]
    rows = []
    for key, group in detail.groupby(group_columns, sort=False):
        y = group.actual.to_numpy(int)
        probability = group.probability.to_numpy(float)
        occurred = group[group.actual == 1]
        key = key if isinstance(key, tuple) else (key,)
        row = {
            "model": key[0],
            "brier": float(np.mean((probability - y) ** 2)),
            "pr_auc": float(average_precision_score(y, probability)),
            "ece": expected_calibration_error(y, probability),
            "date_mae": float(occurred.date_error.mean()),
            "within_1d": float((occurred.date_error <= 1).mean()),
            "cycle_mae": float(occurred.cycle_error.mean()),
            "false_positive_rate": float(((probability >= 0.5) & (y == 0)).sum() / max((y == 0).sum(), 1)),
            "recall": float(((probability >= 0.5) & (y == 1)).sum() / max((y == 1).sum(), 1)),
            "rows": len(group),
            "events": int(y.sum()),
        }
        if by_segment:
            row["segment"] = key[1]
        rows.append(row)
    return pd.DataFrame(rows)


def bootstrap_calendar_lift(detail: pd.DataFrame, repeats: int = 1000) -> pd.DataFrame:
    paired = detail[detail.model.isin(["일별 Hazard", "Hazard + 캘린더"])].copy()
    users = paired[["seed", "person"]].drop_duplicates().to_records(index=False)
    rng = np.random.default_rng(20270199)
    rows = []
    for _ in range(repeats):
        sampled = users[rng.integers(0, len(users), len(users))]
        pieces = []
        for draw_id, (seed, person) in enumerate(sampled):
            piece = paired[(paired.seed == seed) & (paired.person == person)].copy()
            piece["draw_id"] = draw_id
            pieces.append(piece)
        sample = pd.concat(pieces, ignore_index=True)
        metrics = summarize(sample).set_index("model")
        rows.append({
            "brier_lift": float(metrics.loc["일별 Hazard", "brier"] - metrics.loc["Hazard + 캘린더", "brier"]),
            "date_mae_lift": float(metrics.loc["일별 Hazard", "date_mae"] - metrics.loc["Hazard + 캘린더", "date_mae"]),
        })
    boot = pd.DataFrame(rows)
    return pd.DataFrame({
        "metric": ["brier_lift", "date_mae_lift"],
        "mean": [boot.brier_lift.mean(), boot.date_mae_lift.mean()],
        "ci_low": [boot.brier_lift.quantile(0.025), boot.date_mae_lift.quantile(0.025)],
        "ci_high": [boot.brier_lift.quantile(0.975), boot.date_mae_lift.quantile(0.975)],
    })


def make_figures(summary: pd.DataFrame, segments: pd.DataFrame):
    import matplotlib as mpl
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    mpl.rcParams["axes.unicode_minus"] = False
    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    canvas, ink, muted, grid = "#FBFAF7", "#25241F", "#747168", "#E6E2D8"
    yellow, violet, blue, gray = "#FFCC00", "#7A5CF0", "#2A72E5", "#BDB9AF"
    colors = [gray, blue, violet, yellow]
    figures = OUT / "figures"
    figures.mkdir(parents=True, exist_ok=True)

    def frame(title, subtitle):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.90, title, fontproperties=medium, fontsize=22, color=ink)
        fig.text(0.06, 0.85, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        return fig

    ordered = summary.set_index("model").reindex(MODELS)
    # Figure 1: occurrence quality.
    fig = frame("다음 7일 발생 예측: 일별 Hazard가 더 정확한가",
                "신규 홀드아웃 300명·12주·7개 카테고리 · 확률은 별도 60명으로 보정")
    axes = [fig.add_axes([0.12, 0.16, 0.35, 0.60]), fig.add_axes([0.57, 0.16, 0.38, 0.60])]
    specs = [("brier", "Brier ↓", "낮을수록 정확"), ("pr_auc", "PR-AUC ↑", "높을수록 정확")]
    for ax, (column, title, note) in zip(axes, specs):
        values = ordered[column].to_numpy(float)
        bars = ax.barh(np.arange(4), values, color=colors, height=0.58)
        ax.set_yticks(np.arange(4), MODELS)
        ax.invert_yaxis(); ax.set_title(f"{title}  ·  {note}", loc="left", fontproperties=medium, color=ink, pad=12)
        ax.grid(axis="x", color=grid, linewidth=0.8); ax.set_axisbelow(True)
        ax.tick_params(colors=muted)
        for label in [*ax.get_xticklabels(), *ax.get_yticklabels()]: label.set_fontproperties(light)
        for bar, value in zip(bars, values):
            ax.text(value, bar.get_y() + bar.get_height()/2, f"  {value:.3f}", va="center", fontproperties=medium, color=ink)
        ax.set_xlim(0, max(values) * 1.22)
        for spine in ax.spines.values(): spine.set_visible(False)
    fig.savefig(figures / "01_occurrence_performance.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "01_occurrence_performance.svg", facecolor=canvas)
    plt.close(fig)

    # Figure 2: date quality.
    fig = frame("결제일 예측: 오차와 ±1일 적중률을 함께 본다",
                "실제로 결제가 발생한 건만 평가 · 주기는 마지막 관측일부터 예측일까지의 간격")
    axes = [fig.add_axes([0.12, 0.16, 0.35, 0.60]), fig.add_axes([0.57, 0.16, 0.38, 0.60])]
    specs = [("date_mae", "날짜 MAE ↓", "일"), ("within_1d", "±1일 적중률 ↑", "%")]
    for ax, (column, title, unit) in zip(axes, specs):
        raw = ordered[column].to_numpy(float)
        values = raw * 100 if unit == "%" else raw
        bars = ax.barh(np.arange(4), values, color=colors, height=0.58)
        ax.set_yticks(np.arange(4)); ax.set_yticklabels([]); ax.invert_yaxis()
        ax.set_title(title, loc="left", fontproperties=medium, color=ink, pad=12)
        ax.grid(axis="x", color=grid, linewidth=0.8); ax.set_axisbelow(True)
        ax.tick_params(colors=muted)
        for label in [*ax.get_xticklabels(), *ax.get_yticklabels()]: label.set_fontproperties(light)
        for bar, value in zip(bars, values):
            label = f"  {value:.1f}%" if unit == "%" else f"  {value:.2f}일"
            ax.text(value, bar.get_y() + bar.get_height()/2, label, va="center", fontproperties=medium, color=ink)
        ax.set_xlim(0, max(values) * 1.22)
        for spine in ax.spines.values(): spine.set_visible(False)
    for position, name in enumerate(MODELS):
        axes[0].text(-0.035, position, name, transform=axes[0].get_yaxis_transform(),
                     ha="right", va="center", fontproperties=light, fontsize=10.5,
                     color=muted, clip_on=False)
    fig.savefig(figures / "02_date_performance.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "02_date_performance.svg", facecolor=canvas)
    plt.close(fig)

    # Figure 3: calendar ablation by category type.
    focus = segments[segments.model.isin(["일별 Hazard", "Hazard + 캘린더"])]
    pivot = focus.pivot(index="segment", columns="model", values="date_mae").reindex(["일정형", "비일정형"])
    fig = frame("캘린더는 일정형 소비에서 날짜를 좁혀준다",
                "같은 일별 Hazard 구조에서 캘린더 특징만 켜고 끈 ablation · 낮을수록 정확")
    ax = fig.add_axes([0.13, 0.17, 0.76, 0.58])
    x = np.arange(2); width = 0.28
    for j, (name, color) in enumerate([("일별 Hazard", violet), ("Hazard + 캘린더", yellow)]):
        values = pivot[name].to_numpy(float)
        bars = ax.bar(x + (j - 0.5) * width, values, width=width, color=color, label=name)
        for bar, value in zip(bars, values):
            ax.text(bar.get_x() + bar.get_width()/2, value + 0.035, f"{value:.2f}일", ha="center", fontproperties=medium, color=ink)
    ax.set_xticks(x, pivot.index); ax.set_ylim(0, pivot.to_numpy().max() * 1.24)
    ax.grid(axis="y", color=grid, linewidth=0.8); ax.set_axisbelow(True)
    ax.tick_params(colors=muted)
    for label in [*ax.get_xticklabels(), *ax.get_yticklabels()]: label.set_fontproperties(light)
    legend = ax.legend(frameon=False, prop=light, loc="upper right")
    for spine in ax.spines.values(): spine.set_visible(False)
    fig.savefig(figures / "03_calendar_ablation.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "03_calendar_ablation.svg", facecolor=canvas)
    plt.close(fig)


def write_report(summary, segments, bootstrap):
    ordered = summary.set_index("model").reindex(MODELS).reset_index()
    hazard = ordered.set_index("model").loc["일별 Hazard"]
    calendar = ordered.set_index("model").loc["Hazard + 캘린더"]
    scheduled = segments[(segments.model == "Hazard + 캘린더") & (segments.segment == "일정형")].iloc[0]
    scheduled_base = segments[(segments.model == "일별 Hazard") & (segments.segment == "일정형")].iloc[0]
    brier_ci = bootstrap[bootstrap.metric == "brier_lift"].iloc[0]
    date_ci = bootstrap[bootstrap.metric == "date_mae_lift"].iloc[0]
    table = ordered[["model", "brier", "pr_auc", "ece", "date_mae", "within_1d", "cycle_mae"]].copy()
    table["within_1d"] *= 100
    lines = [
        "# 일별 Hazard + 캘린더 신규 홀드아웃 12주 검증",
        "",
        "## 결론",
        "",
        (f"Hazard + 캘린더는 캘린더 없는 동일 Hazard 대비 Brier를 "
         f"{hazard.brier - calendar.brier:.4f}, 날짜 MAE를 {hazard.date_mae - calendar.date_mae:.2f}일 개선했다. "
         f"일정형 카테고리의 날짜 MAE는 {scheduled_base.date_mae:.2f}일에서 {scheduled.date_mae:.2f}일로 줄었다."),
        "",
        (f"사용자 단위 bootstrap 95% CI: Brier 개선 [{brier_ci.ci_low:.4f}, {brier_ci.ci_high:.4f}], "
         f"날짜 MAE 개선 [{date_ci.ci_low:.2f}, {date_ci.ci_high:.2f}]일."),
        "",
        "## 전체 결과",
        "",
        "| 모델 | Brier ↓ | PR-AUC ↑ | ECE ↓ | 날짜 MAE ↓ | ±1일 적중률 ↑ | 주기 MAE ↓ |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in table.itertuples(index=False):
        lines.append(
            f"| {row.model} | {row.brier:.4f} | {row.pr_auc:.4f} | {row.ece:.4f} | "
            f"{row.date_mae:.2f}일 | {row.within_1d:.1f}% | {row.cycle_mae:.2f}일 |"
        )
    lines.extend([
        "",
        "## 실험 계약",
        "",
        "- 데이터: 카드 결제 + 이미 등록된 캘린더 일정만 사용. 현금·자유 텍스트·LLM 입력 없음.",
        "- 분리: 학습 240명 / 확률 보정 60명 / 신규 평가 100명 × 3개 신규 시드.",
        "- 기간: 테스트 시작 전 기록만 특징으로 만들고 신규 사용자의 12주를 롤링 평가.",
        "- 비교: 주기 휴리스틱, 주간 LightGBM, 일별 Hazard, 동일 Hazard + 캘린더.",
        "- 발생: Brier·PR-AUC·ECE. 날짜: 실제 발생 건의 MAE·±1일 적중률.",
        "- 주기: 마지막 관측 결제일부터 예측 결제일까지의 간격. 같은 기준점을 쓰므로 날짜 MAE와 수치적으로 같다.",
        "",
        "## 해석 제한",
        "",
        "이 결과는 구조를 검증하는 합성 데이터 통제 실험이다. 실제 고객 성능이나 운영 임계값을 확정하지 않는다. "
        "실데이터에서는 시간 순 홀드아웃과 사용자 동의 기반 캘린더 범위로 동일 프로토콜을 재실행해야 한다.",
    ])
    (OUT / "results.md").write_text("\n".join(lines), encoding="utf-8")


def validate(detail: pd.DataFrame):
    expected = len(SEEDS) * len(EVALUATION_PEOPLE) * len(EVALUATION_WEEKS) * len(CATEGORIES) * len(MODELS)
    assert len(detail) == expected, (len(detail), expected)
    key = ["seed", "model", "person", "week", "category"]
    assert not detail.duplicated(key).any()
    assert detail.probability.between(0, 1).all()
    assert set(detail.person).isdisjoint(TRAIN_PEOPLE)
    assert set(detail.person).isdisjoint(CALIBRATION_PEOPLE)
    assert detail.actual_offset.dropna().between(0, 6).all()
    assert detail.predicted_offset.between(0, 6).all()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    parts = [run_seed(seed) for seed in SEEDS]
    detail = pd.concat(parts, ignore_index=True)
    validate(detail)
    summary = summarize(detail)
    segments = summarize(detail, by_segment=True)
    bootstrap = bootstrap_calendar_lift(detail)
    detail.to_csv(OUT / "predictions.csv", index=False)
    summary.to_csv(OUT / "summary.csv", index=False)
    segments.to_csv(OUT / "segment_summary.csv", index=False)
    bootstrap.to_csv(OUT / "bootstrap_calendar_lift.csv", index=False)
    make_figures(summary, segments)
    write_report(summary, segments, bootstrap)
    print(summary.to_string(index=False), flush=True)
    print(bootstrap.to_string(index=False), flush=True)


if __name__ == "__main__":
    main()
