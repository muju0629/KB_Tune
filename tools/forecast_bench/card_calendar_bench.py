"""카드 결제 + 캘린더만으로 다음 주 소비를 예측하는 롤링 벤치마크.

현금·미관측 소비·질문 답변 복원은 넣지 않는다. 비교 대상은 세 가지다.

    R0 recent_mean   최근 8주 개인×카테고리 주간 평균
    R1 personal      온디바이스 발생확률 × 개인 금액 사후분포
    R2 + calendar    R1에 이미 잡힌 미래 일정을 known future signal로 결합

합성 데이터는 모델과 별도로 생성한다. 반복 소비는 독립 주별 Poisson이 아니라
실제 발생 간격을 순차적으로 뽑는 renewal process다.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

import mpp
from metrics import coverage, wape


HERE = Path(__file__).parent
OUT = HERE / "results/card_calendar"
SEED = 20260730
N_PEOPLE = 400
N_PRIOR_PEOPLE = 300
N_WEEKS = 52
FIRST_TEST_WEEK = 32
LOOKBACK_WEEKS = 26
N_DRAWS = 200


@dataclass(frozen=True)
class Spec:
    category: str
    kind: str
    amount: float
    amount_sd: float
    ownership: float
    frequency: float


SPECS = [
    Spec("구독", "fixed", 9_900, 0.03, 0.75, 30.0),
    Spec("생활", "renewal", 35_000, 0.18, 0.85, 10.0),
    Spec("자기관리", "renewal", 32_000, 0.15, 0.65, 42.0),
    Spec("카페", "irregular", 5_500, 0.40, 0.92, 2.2),
    Spec("외식", "irregular", 17_000, 0.38, 0.88, 0.9),
    Spec("모임", "scheduled", 45_000, 0.30, 0.60, 0.55),
    Spec("데이트", "scheduled", 70_000, 0.25, 0.42, 0.40),
]
SPEC_BY_CAT = {s.category: s for s in SPECS}


def _amount(rng: np.random.Generator, median: float, log_sd: float) -> float:
    return float(np.round(rng.lognormal(np.log(median), log_sd), -2))


def generate() -> tuple[pd.DataFrame, pd.DataFrame]:
    """모든 실제 소비가 카드에 남는 거래와, 미리 알려진 일정 두 표를 만든다."""
    rng = np.random.default_rng(SEED)
    tx: list[dict] = []
    calendar: list[dict] = []
    horizon = N_WEEKS * 7
    plan_id = 0

    def add_tx(person: int, day: int, spec: Spec, personal_amount: float,
               source_plan: int | None = None) -> None:
        if 0 <= day < horizon:
            tx.append({"person": person, "day": day, "week": day // 7,
                       "weekday": day % 7, "category": spec.category,
                       "amount": _amount(rng, personal_amount, spec.amount_sd),
                       "plan_id": source_plan})

    for person in range(N_PEOPLE):
        for spec in SPECS:
            if rng.random() > spec.ownership:
                continue
            personal_amount = spec.amount * float(rng.lognormal(0, 0.28))

            if spec.kind == "fixed":
                day = int(rng.integers(1, 29))
                while day < horizon:
                    add_tx(person, day, spec, personal_amount)
                    day += 30

            elif spec.kind == "renewal":
                # Gamma 간격: 평균은 개인 주기, CV는 0.30. 이전 발생일에서 순차 생성한다.
                mean_gap = spec.frequency * float(rng.uniform(0.75, 1.30))
                shape = 1 / 0.30**2
                day = float(rng.uniform(0, mean_gap))
                while day < horizon:
                    add_tx(person, int(round(day)), spec, personal_amount)
                    day += float(rng.gamma(shape, mean_gap / shape))

            elif spec.kind == "irregular":
                personal_rate = spec.frequency * float(rng.lognormal(0, 0.25))
                for week in range(N_WEEKS):
                    for _ in range(int(rng.poisson(personal_rate))):
                        add_tx(person, week * 7 + int(rng.integers(0, 7)),
                               spec, personal_amount)

            else:  # scheduled
                preferred_day = int(rng.integers(4, 7))
                personal_rate = min(0.95, spec.frequency * float(rng.uniform(0.75, 1.25)))
                for week in range(N_WEEKS):
                    # 일정에 없는 즉흥 소비도 소량 남겨 캘린더가 정답표가 되지 않게 한다.
                    if rng.random() < 0.07:
                        add_tx(person, week * 7 + int(rng.integers(0, 7)),
                               spec, personal_amount)
                    if rng.random() >= personal_rate:
                        continue
                    day = week * 7 + int(np.clip(preferred_day + rng.choice([-1, 0, 0, 0, 1]), 0, 6))
                    # 실제 약속의 75%만 앱 캘린더에 잡혀 있다.
                    if rng.random() < 0.75:
                        plan_id += 1
                        calendar.append({"plan_id": plan_id, "person": person, "day": day,
                                         "week": week, "category": spec.category})
                        # 등록된 일정도 10%는 취소된다.
                        if rng.random() >= 0.10:
                            add_tx(person, day, spec, personal_amount, plan_id)
                    else:
                        add_tx(person, day, spec, personal_amount)

    tx_df = pd.DataFrame(tx).sort_values(["person", "day", "category"]).reset_index(drop=True)
    cal_df = pd.DataFrame(calendar).sort_values(["person", "day"]).reset_index(drop=True)
    return tx_df, cal_df


# sweep_prior_strength.py 가 고른 값. 28 일은 어느 주차에서도 최적이 아니었다 —
# 8주차 WAPE 를 4.4% 악화시키고 1~8주 학습 곡선을 1.1% 로 눌러 평평하게 만들었다.
# 10 일에서 8주차가 최소이고 학습 곡선이 8.6% 로 살아난다. 1주차는 20 일 대비
# 3.7% 손해인데, 그 구간은 구간폭으로 불확실성을 알리므로 후반 정확도를 택했다.
PRIOR_STRENGTH_DAYS = 10.0


def fit_priors(tx: pd.DataFrame,
               strength_days: float = PRIOR_STRENGTH_DAYS) -> dict[str, mpp.Prior]:
    """테스트 시작 전 데이터에서만 카테고리별 인구 사전분포를 적합한다.

    `strength_days` 는 인구 사전분포를 관측 며칠 상당으로 믿는가다. 발생률 사후가
    `(a + n) / (b + days)` 라서 `b = strength_days` 가 개인 관측과 직접 경쟁한다.
    크면 콜드스타트가 안전해지고 개인화가 늦어진다 — 두 끝이 이 숫자 하나에
    매달려 있어 하드코딩하면 안 된다.
    """
    train = tx[(tx.week < FIRST_TEST_WEEK) & (tx.person < N_PRIOR_PEOPLE)]
    priors: dict[str, mpp.Prior] = {}
    for spec in SPECS:
        sub = train[train.category == spec.category]
        logs = np.log(sub.amount.clip(lower=1).to_numpy(float))
        by_person = sub.assign(log_amount=np.log(sub.amount.clip(lower=1))).groupby("person")
        personal_means = by_person.log_amount.mean()
        within = by_person.log_amount.var().dropna()
        mu0 = float(np.median(logs)) if len(logs) else np.log(spec.amount)
        tau2 = max(float(personal_means.var()), 0.05) if len(personal_means) > 1 else 0.20
        sigma2 = max(float(within.mean()), 0.01) if len(within) else spec.amount_sd**2

        counts = sub.groupby("person").size().reindex(range(N_PRIOR_PEOPLE), fill_value=0)
        mean_rate = float(counts.mean() / (FIRST_TEST_WEEK * 7))
        gap_shape = {"fixed": 5.0, "renewal": 3.0}.get(spec.kind, 1.0)
        priors[spec.category] = mpp.Prior(
            a=max(mean_rate * strength_days, 0.01), b=strength_days,
            mu0=mu0, tau2=tau2, sigma2=sigma2, gap_shape=gap_shape,
        )
    return priors


def counters(history: pd.DataFrame, start_day: int,
             lookback_weeks: int = LOOKBACK_WEEKS) -> mpp.Counters:
    """최근 거래 원자료를 온디바이스 충분통계량으로 접는다."""
    c = mpp.Counters()
    if history.empty:
        c.days = lookback_weeks * 7
        c.last_gap = lookback_weeks * 7
        return c
    rows = history.sort_values("day")
    first_observed = start_day - lookback_weeks * 7
    previous = first_observed
    previous_event: int | None = None
    for day, group in rows.groupby("day"):
        gap = [] if previous_event is None else [float(day - previous_event)]
        c.update(len(group), float(group.amount.sum()), max(float(day - previous), 0), gaps=gap)
        previous = int(day)
        previous_event = int(day)
    idle = max(float(start_day - previous), 0)
    if idle:
        c.update(0, 0, idle)
    return c


def amount_draws(c: mpp.Counters, prior: mpp.Prior,
                 rng: np.random.Generator, n: int = N_DRAWS) -> np.ndarray:
    mu, sd = mpp.posterior_log_amount(c, prior)
    return rng.lognormal(mu, sd, n)


def personal_draws(c: mpp.Counters, prior: mpp.Prior, kind: str,
                   rng: np.random.Generator,
                   n_draws: int = N_DRAWS) -> tuple[np.ndarray, float]:
    """다음 7일 총액 표본과 1회 이상 발생 확률."""
    learned = mpp.Prior(**{**prior.__dict__, "gap_shape": mpp.estimate_shape(c, prior)})
    if kind in {"fixed", "renewal"}:
        p = mpp.prob_within(c, learned, 7, elapsed=c.last_gap)
        draws = amount_draws(c, learned, rng, n_draws) * (rng.random(n_draws) < p)
        return draws, p
    lam = mpp.posterior_rate(c, learned) * 7
    counts = rng.poisson(lam, n_draws)
    amounts = amount_draws(c, learned, rng, n_draws * max(int(counts.max()), 1))
    amounts = amounts.reshape(n_draws, -1)
    mask = np.arange(amounts.shape[1])[None, :] < counts[:, None]
    return (amounts * mask).sum(1), float(1 - np.exp(-lam))


def recent_stats(history: pd.DataFrame, current_week: int) -> tuple[float, float, int]:
    """현재 시점 직전 8주의 평균액·발생률·대표 요일."""
    weeks = range(current_week - 8, current_week)
    if history.empty:
        return 0.0, 0.0, 0
    weekly = history.groupby("week").amount.sum().reindex(weeks, fill_value=0)
    recent = history[history.week.isin(weeks)]
    weekday = int(recent.weekday.mode().iloc[0]) if not recent.empty else 0
    return float(weekly.mean()), float((weekly > 0).mean()), weekday


def predicted_weekday(history: pd.DataFrame, c: mpp.Counters,
                      prior: mpp.Prior, kind: str) -> int:
    """발생한다고 가정했을 때 다음 주 안의 대표 발생일(0=월)을 고른다."""
    if kind in {"fixed", "renewal"}:
        learned = mpp.Prior(**{**prior.__dict__, "gap_shape": mpp.estimate_shape(c, prior)})
        hazard = [mpp.prob_within(c, learned, 1, elapsed=c.last_gap + d) for d in range(7)]
        return int(np.argmax(hazard))
    return int(history.weekday.mode().iloc[0]) if not history.empty else 0


def run(tx: pd.DataFrame, calendar: pd.DataFrame,
        priors: dict[str, mpp.Prior], lookback_weeks: int = LOOKBACK_WEEKS,
        n_draws: int = N_DRAWS) -> tuple[pd.DataFrame, pd.DataFrame]:
    rng = np.random.default_rng(SEED + 1)
    rows: list[dict] = []
    occurrence_rows: list[dict] = []
    categories = [s.category for s in SPECS]

    # 등록 일정이 실제 결제로 이어지는 비율도 테스트 이전 카드 데이터에서만 학습한다.
    train_plans = calendar[(calendar.week < FIRST_TEST_WEEK) &
                           (calendar.person < N_PRIOR_PEOPLE)]
    converted = set(tx.loc[(tx.week < FIRST_TEST_WEEK) &
                           (tx.person < N_PRIOR_PEOPLE), "plan_id"].dropna().astype(int))
    plan_conversion = (train_plans.plan_id.isin(converted).mean()
                       if len(train_plans) else 0.85)

    for week in range(FIRST_TEST_WEEK, N_WEEKS):
        start = week * 7
        floor = start - lookback_weeks * 7
        hist_window = tx[(tx.day >= floor) & (tx.day < start)]
        actual_week = tx[tx.week == week]
        plans_week = calendar[calendar.week == week]

        for person in range(N_PRIOR_PEOPLE, N_PEOPLE):
            total_r0 = 0.0
            total_r1 = np.zeros(n_draws)
            total_r2 = np.zeros(n_draws)
            actual = float(actual_week.loc[actual_week.person == person, "amount"].sum())
            person_hist = hist_window[hist_window.person == person]

            for category in categories:
                spec = SPEC_BY_CAT[category]
                h = person_hist[person_hist.category == category]
                c = counters(h, start, lookback_weeks)
                base_draws, personal_p = personal_draws(
                    c, priors[category], spec.kind, rng, n_draws)
                r0_mean, r0_p, r0_weekday = recent_stats(h, week)
                personal_weekday = predicted_weekday(h, c, priors[category], spec.kind)
                total_r0 += r0_mean
                total_r1 += base_draws

                plans = plans_week[(plans_week.person == person) &
                                   (plans_week.category == category)]
                if plans.empty:
                    total_r2 += base_draws
                    calendar_p = personal_p
                    calendar_weekday = personal_weekday
                else:
                    # 캘린더 일정은 기존 카테고리 예측을 대체한다. 중복 계상을 막는다.
                    scheduled = np.zeros(n_draws)
                    for _ in range(len(plans)):
                        scheduled += amount_draws(c, priors[category], rng, n_draws) * (
                            rng.random(n_draws) < plan_conversion)
                    total_r2 += scheduled
                    calendar_p = float(1 - (1 - plan_conversion) ** len(plans))
                    calendar_weekday = int(plans.iloc[0].day % 7)

                actual_cat = actual_week[(actual_week.person == person) &
                                         (actual_week.category == category)]
                occurred = not actual_cat.empty
                actual_weekday = int(actual_cat.iloc[0].weekday) if occurred else -1
                for model, probability, weekday in [
                    ("R0 최근 8주 평균", r0_p, r0_weekday),
                    ("R1 개인 발생×금액", personal_p, personal_weekday),
                    ("R2 + 캘린더", calendar_p, calendar_weekday),
                ]:
                    occurrence_rows.append({
                        "person": person, "week": week, "category": category,
                        "model": model, "probability": probability,
                        "predicted_weekday": weekday, "occurred": occurred,
                        "actual_weekday": actual_weekday,
                    })

            for model, pred in [("R0 최근 8주 평균", np.full(n_draws, total_r0)),
                                ("R1 개인 발생×금액", total_r1),
                                ("R2 + 캘린더", total_r2)]:
                rows.append({"person": person, "week": week, "model": model,
                             "actual": actual, "p10": float(np.quantile(pred, 0.1)),
                             "p50": float(np.quantile(pred, 0.5)),
                             "mean": float(pred.mean()),
                             "p90": float(np.quantile(pred, 0.9)),
                             "has_calendar": bool((plans_week.person == person).any())})
    return pd.DataFrame(rows), pd.DataFrame(occurrence_rows)


def build_learning_curve(tx: pd.DataFrame, calendar: pd.DataFrame,
                         priors: dict[str, mpp.Prior]) -> pd.DataFrame:
    """앱 사용 이력이 늘 때 동일한 평가 사용자들의 예측 성능 변화를 측정한다."""
    rows = []
    for weeks in [1, 2, 4, 6, 8, 12, 16, 20, 26, 32]:
        pred, occurrence = run(tx, calendar, priors, lookback_weeks=weeks, n_draws=120)
        summary = summarize(pred).set_index("모델")
        occ = summarize_occurrence(occurrence).set_index("모델")
        for model in ["R1 개인 발생×금액", "R2 + 캘린더"]:
            rows.append({
                "사용주차": weeks, "모델": model,
                "WAPE": float(summary.loc[model, "WAPE"]),
                "WAPE기반정확도": 1 - float(summary.loc[model, "WAPE"]),
                "커버리지80": float(summary.loc[model, "커버리지80"]),
                "발생정밀도": float(occ.loc[model, "정밀도@0.6"]),
            })
    return pd.DataFrame(rows)


def summarize(pred: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for model, g in pred.groupby("model", sort=False):
        rows.append({
            "모델": model,
            "WAPE": wape(g.actual, g.p50),
            "커버리지80": coverage(g.actual, g.p10, g.p90),
            "구간폭중앙": float(np.median(g.p90 - g.p10)),
            "편향": float((g.p50 - g.actual).sum() / max(g.actual.sum(), 1)),
            "캘린더주_WAPE": wape(g.loc[g.has_calendar, "actual"],
                                    g.loc[g.has_calendar, "p50"]),
        })
    return pd.DataFrame(rows)


def summarize_occurrence(pred: pd.DataFrame, threshold: float = 0.6) -> pd.DataFrame:
    rows = []
    for model, g in pred.groupby("model", sort=False):
        asked = g[g.probability >= threshold]
        true_positive = asked[asked.occurred]
        rows.append({
            "모델": model,
            "Brier": float(np.mean((g.probability - g.occurred.astype(float)) ** 2)),
            "정밀도@0.6": float(asked.occurred.mean()) if len(asked) else np.nan,
            "재현율@0.6": float(true_positive.shape[0] / max(g.occurred.sum(), 1)),
            "날짜MAE일": float(np.abs(true_positive.predicted_weekday -
                                     true_positive.actual_weekday).mean())
                         if len(true_positive) else np.nan,
            "제안수": int(len(asked)),
        })
    return pd.DataFrame(rows)


def paired_bootstrap(pred: pd.DataFrame, left: str, right: str,
                     n: int = 1_000) -> tuple[float, float, float]:
    """사용자를 재표집해 right의 left 대비 WAPE 개선률 신뢰구간을 낸다."""
    users = np.array(sorted(pred.person.unique()))
    actual = (pred[pred.model == left].groupby("person").actual.sum()
              .reindex(users).to_numpy(float))
    left_error = (pred[pred.model == left].assign(
        error=lambda x: (x.actual - x.p50).abs()).groupby("person").error.sum()
                  .reindex(users).to_numpy(float))
    right_error = (pred[pred.model == right].assign(
        error=lambda x: (x.actual - x.p50).abs()).groupby("person").error.sum()
                   .reindex(users).to_numpy(float))
    rng = np.random.default_rng(SEED + 2)
    lifts = []
    for _ in range(n):
        idx = rng.integers(0, len(users), len(users))
        denom = actual[idx].sum()
        l = left_error[idx].sum() / denom
        r = right_error[idx].sum() / denom
        lifts.append((l - r) / l)
    return tuple(np.quantile(lifts, [0.025, 0.5, 0.975]))


def write_report(result: pd.DataFrame, occurrence: pd.DataFrame,
                 learning: pd.DataFrame, pred: pd.DataFrame,
                 tx: pd.DataFrame, calendar: pd.DataFrame) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    result.to_csv(OUT / "results.csv", index=False)
    occurrence.to_csv(OUT / "occurrence_results.csv", index=False)
    learning.to_csv(OUT / "learning_curve.csv", index=False)
    r0 = result.iloc[0]
    r1 = result.iloc[1]
    r2 = result.iloc[2]
    ci_personal = paired_bootstrap(pred, "R0 최근 8주 평균", "R1 개인 발생×금액")
    ci_calendar = paired_bootstrap(pred, "R1 개인 발생×금액", "R2 + 캘린더")
    report = f"""# 카드 + 캘린더 주간 예측 벤치마크

## 범위

- 현금·미관측 소비·질문 답변 없음. 실제 소비는 전부 카드 거래로 관측
- 합성 {N_PEOPLE}명 × {N_WEEKS}주. {N_PRIOR_PEOPLE}명으로 인구 사전분포 적합
- 별도 평가 사용자 {N_PEOPLE-N_PRIOR_PEOPLE}명의 마지막 {N_WEEKS-FIRST_TEST_WEEK}주를 롤링 평가
- 거래 {len(tx):,}건, 미래 캘린더 일정 {len(calendar):,}건

## 결과

{result.to_markdown(index=False, floatfmt=".4f")}

### 발생 여부·날짜

{occurrence.to_markdown(index=False, floatfmt=".4f")}

### 사용 기간별 학습 곡선

{learning.to_markdown(index=False, floatfmt=".4f")}

## 읽는 법

- 개인화 모델의 R0 대비 WAPE 변화: {(r0.WAPE-r1.WAPE)/r0.WAPE:+.1%}
- 사용자 bootstrap 95% 구간: {ci_personal[0]:+.1%}~{ci_personal[2]:+.1%}
- 캘린더 결합 모델의 R1 대비 전체 WAPE 변화: {(r1.WAPE-r2.WAPE)/r1.WAPE:+.1%}
- 사용자 bootstrap 95% 구간: {ci_calendar[0]:+.1%}~{ci_calendar[2]:+.1%}
- 캘린더가 있는 주의 R1 대비 WAPE 변화: {(r1['캘린더주_WAPE']-r2['캘린더주_WAPE'])/r1['캘린더주_WAPE']:+.1%}

## 제한

- 합성 데이터 결과이며 실사용자 성능이 아니다.
- 캘린더 등록률 75%, 등록 일정 취소율 10%라는 생성 가정에 결과가 의존한다.
- 일정 제목 분류 오류와 카드 가맹점 카테고리 오류는 이번 실험에서 제외했다.
- 80% 구간은 별도 conformal calibration 전의 모델 구간이다.
"""
    (OUT / "results.md").write_text(report, encoding="utf-8")


def selfcheck(tx: pd.DataFrame, calendar: pd.DataFrame,
              pred: pd.DataFrame, occurrence: pd.DataFrame) -> None:
    assert not tx.empty and not calendar.empty
    assert tx.amount.gt(0).all()
    assert tx.week.between(0, N_WEEKS - 1).all()
    assert set(pred.model.unique()) == {"R0 최근 8주 평균", "R1 개인 발생×금액", "R2 + 캘린더"}
    n_eval = N_PEOPLE - N_PRIOR_PEOPLE
    assert len(pred) == n_eval * (N_WEEKS - FIRST_TEST_WEEK) * 3
    assert (pred.p10 <= pred.p50).all() and (pred.p50 <= pred.p90).all()
    assert pred[["p10", "p50", "mean", "p90"]].ge(0).all().all()
    assert occurrence.probability.between(0, 1).all()
    assert len(occurrence) == n_eval * (N_WEEKS - FIRST_TEST_WEEK) * len(SPECS) * 3


def main() -> None:
    tx, calendar = generate()
    priors = fit_priors(tx)
    pred, occurrence_pred = run(tx, calendar, priors)
    selfcheck(tx, calendar, pred, occurrence_pred)
    result = summarize(pred)
    occurrence = summarize_occurrence(occurrence_pred)
    learning = build_learning_curve(tx, calendar, priors)
    write_report(result, occurrence, learning, pred, tx, calendar)
    print(result.to_string(index=False, float_format=lambda x: f"{x:.4f}"))
    print("\n" + occurrence.to_string(index=False, float_format=lambda x: f"{x:.4f}"))
    print(f"\n{OUT / 'results.md'}")


if __name__ == "__main__":
    main()
