"""지속 개인 성향 + 주 1회 장기 학습 피드백의 Bayesian 일반화 실험."""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import json

import numpy as np
import pandas as pd

import active_feedback_bench as base
from card_calendar_bench import (
    FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE, N_WEEKS, SPECS,
)


HERE = Path(__file__).parent
OUT = HERE / "results/personal_bayes_feedback_8week"
CALIBRATION = HERE / "results/local_spend_profile/calibration.json"
SEED = 20260731
APPLIED_PERSISTENCE = 0.65
STABLE_GLOBAL_SD = 0.16 + 0.14 * APPLIED_PERSISTENCE
STABLE_CATEGORY_SD = 0.15 + 0.20 * APPLIED_PERSISTENCE
LIFESTYLE_GLOBAL_SD = 0.18
LIFESTYLE_CATEGORY_SD = 0.35
LIFESTYLE_OCCURRENCE_SD = 0.55
PERSISTENT_QUESTION_COOLDOWN = 4


def logistic(value):
    value = np.clip(value, -12, 12)
    return 1 / (1 + np.exp(-value))


def logit(value):
    value = np.clip(value, 0.001, 0.999)
    return np.log(value / (1 - value))


def calibrated_amounts(calibration: dict) -> dict[str, float]:
    regional = calibration["regional_ticket_median"]
    amounts = {spec.category: spec.amount for spec in SPECS}
    # 단 하루의 지역값을 그대로 쓰지 않고 기존 사전값과 기하평균으로 축소한다.
    for category in ["생활", "외식", "자기관리", "카페"]:
        if category in regional:
            amounts[category] = float(np.sqrt(amounts[category] * regional[category]))
    return amounts


def generate_persistent(calibration: dict) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """개인별 안정 성향과 평가 시작 시점의 지속 생활변화를 별도 잠재값으로 둔다."""
    rng = np.random.default_rng(SEED)
    amount_prior = calibrated_amounts(calibration)
    transactions, calendar, latent_rows = [], [], []
    plan_id = 0
    horizon = N_WEEKS * 7

    def add_tx(person, week, spec, median, source_plan=None):
        day = week * 7 + int(rng.integers(0, 7))
        if day >= horizon:
            return
        transactions.append({
            "person": person, "day": day, "week": week, "weekday": day % 7,
            "category": spec.category,
            "amount": float(np.round(rng.lognormal(np.log(max(median, 100)), spec.amount_sd), -2)),
            "plan_id": source_plan,
        })

    for person in range(N_PEOPLE):
        global_scale = float(rng.normal(0, STABLE_GLOBAL_SD))
        global_shift = float(rng.normal(0, LIFESTYLE_GLOBAL_SD)) if person >= N_PRIOR_PEOPLE else 0.0
        shifted_categories = set(rng.choice(
            ["생활", "카페", "외식", "모임", "데이트", "자기관리"],
            size=2, replace=False,
        )) if person >= N_PRIOR_PEOPLE else set()

        for spec in SPECS:
            if rng.random() > spec.ownership:
                continue
            category_scale = float(rng.normal(0, STABLE_CATEGORY_SD))
            category_shift = (float(rng.normal(0, LIFESTYLE_CATEGORY_SD))
                              if spec.category in shifted_categories else 0.0)
            occurrence_shift = (float(rng.normal(0, LIFESTYLE_OCCURRENCE_SD))
                                if spec.category in shifted_categories else 0.0)
            test_typical_amount = float(np.exp(
                np.log(amount_prior[spec.category]) + global_scale + category_scale
                + global_shift + category_shift
            ))
            if spec.kind == "fixed":
                test_occurrence_probability = 0.25
            elif spec.kind == "renewal":
                test_occurrence_probability = float(logistic(
                    logit(min(0.95, 7 / spec.frequency)) + occurrence_shift
                ))
            elif spec.kind == "irregular":
                test_occurrence_probability = float(
                    1 - np.exp(-spec.frequency * np.exp(occurrence_shift))
                )
            else:
                test_occurrence_probability = float(logistic(
                    logit(min(spec.frequency, 0.95)) + occurrence_shift
                ))
            latent_rows.append({
                "person": person, "category": spec.category,
                "global_scale": global_scale, "category_scale": category_scale,
                "global_shift": global_shift, "category_shift": category_shift,
                "occurrence_shift": occurrence_shift,
                "test_typical_amount": test_typical_amount,
                "test_occurrence_probability": test_occurrence_probability,
            })

            phase = int(rng.integers(0, 4))
            for week in range(N_WEEKS):
                after_change = person >= N_PRIOR_PEOPLE and week >= FIRST_TEST_WEEK
                log_amount = (np.log(amount_prior[spec.category])
                              + global_scale + category_scale
                              + (global_shift + category_shift if after_change else 0))
                median = float(np.exp(log_amount))
                occ_delta = occurrence_shift if after_change else 0.0

                if spec.kind == "fixed":
                    count = int(week % 4 == phase)
                elif spec.kind == "renewal":
                    probability = min(0.95, 7 / spec.frequency)
                    probability = float(logistic(logit(probability) + occ_delta))
                    count = int(rng.random() < probability)
                elif spec.kind == "irregular":
                    rate = spec.frequency * float(np.exp(occ_delta))
                    count = int(rng.poisson(rate))
                else:
                    probability = float(logistic(logit(min(spec.frequency, 0.95)) + occ_delta))
                    count = int(rng.random() < probability)

                if spec.kind == "scheduled" and count:
                    if rng.random() < 0.75:
                        plan_id += 1
                        day = week * 7 + int(rng.integers(4, 7))
                        calendar.append({
                            "plan_id": plan_id, "person": person, "day": day,
                            "week": week, "category": spec.category,
                        })
                        if rng.random() < 0.10:
                            count = 0
                        else:
                            add_tx(person, week, spec, median, plan_id)
                            count -= 1
                for _ in range(max(count, 0)):
                    add_tx(person, week, spec, median)

    tx = pd.DataFrame(transactions).sort_values(["person", "day", "category"]).reset_index(drop=True)
    cal = pd.DataFrame(calendar).sort_values(["person", "day"]).reset_index(drop=True)
    latent = pd.DataFrame(latent_rows)
    return tx, cal, latent


class PersonalBayes:
    """개인·카테고리 보정을 Normal-Normal 충분통계량으로 수축한다."""
    def __init__(self):
        self.amount_global = defaultdict(lambda: [0.0, 0.0])
        self.amount_category = defaultdict(lambda: [0.0, 0.0])
        self.occurrence_global = defaultdict(lambda: [0.0, 0.0])
        self.occurrence_category = defaultdict(lambda: [0.0, 0.0])

    @staticmethod
    def _add(store, key, residual, weight=1.0):
        store[key][0] += float(np.clip(residual, -1.5, 1.5)) * weight
        store[key][1] += weight

    @staticmethod
    def _mean(store, key, prior_weight):
        total, weight = store[key]
        return total / (weight + prior_weight)

    def update(self, person: int, category: str, probability: float,
               conditional_amount: float, answer: dict) -> None:
        if not answer["responded"]:
            return
        target_p = answer.get("reported_probability")
        if target_p is None:
            target_p = 0.88 if answer["reported_occurrence"] else 0.12
        occ_residual = float(logit(target_p) - logit(probability))
        self._add(self.occurrence_global, person, occ_residual, 0.35)
        self._add(self.occurrence_category, (person, category), occ_residual, 1.0)
        if answer["reported_amount"] is not None:
            amount_residual = float(np.log(answer["reported_amount"]
                                           / max(conditional_amount, 1)))
            self._add(self.amount_global, person, amount_residual, 0.35)
            self._add(self.amount_category, (person, category), amount_residual, 1.0)

    def adjust(self, meta: pd.DataFrame, probability: np.ndarray,
               conditional_amount: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        p, amount = probability.copy(), conditional_amount.copy()
        for i, row in enumerate(meta.itertuples(index=False)):
            person, category = int(row.person), str(row.category)
            amount_shift = (0.35 * self._mean(self.amount_global, person, 2.5)
                            + 0.65 * self._mean(self.amount_category, (person, category), 1.5))
            occ_shift = (0.35 * self._mean(self.occurrence_global, person, 2.5)
                         + 0.65 * self._mean(self.occurrence_category, (person, category), 1.5))
            amount[i] *= float(np.exp(np.clip(amount_shift, -0.7, 0.7)))
            p[i] = float(logistic(logit(p[i]) + np.clip(occ_shift, -1.5, 1.5)))
        return np.clip(p, 0.01, 0.99), np.clip(amount, 100, None)


def select_scopes(meta: pd.DataFrame, X: pd.DataFrame,
                  prediction: tuple[np.ndarray, np.ndarray], app_week: int,
                  persistent_history: dict[tuple[int, str], int]
                  ) -> dict[tuple[int, str], str]:
    p, cond = prediction
    ranked = meta.copy()
    ranked["priority"] = p * cond + 2 * p * (1 - p) * cond + X.calendar_expected.to_numpy(float)
    scopes = {}
    for person, group in ranked.groupby("person"):
        ordered = group.sort_values("priority", ascending=False)
        immediate = ordered.iloc[0]
        immediate_key = (int(person), str(immediate.category))
        scopes[immediate_key] = "thisOccurrence"
        candidates = ordered.iloc[1:]
        eligible = candidates[candidates.category.map(
            lambda category: app_week - persistent_history.get(
                (int(person), str(category)), -PERSISTENT_QUESTION_COOLDOWN
            ) >= PERSISTENT_QUESTION_COOLDOWN
        )]
        persistent = (eligible.iloc[0] if not eligible.empty else candidates.iloc[0])
        persistent_key = (int(person), str(persistent.category))
        scopes[persistent_key] = "futureDefault"
        persistent_history[persistent_key] = app_week
    return scopes


def simulate_scoped_answers(scopes, week, target_cat, pop_amount,
                            pop_occurrence, latent_lookup, rng):
    """즉시 확인은 현재 사건, 장기 기본값은 잠재 개인 성향에서 응답을 만든다."""
    answers = {}
    for person, category in sorted(scopes):
        scope = scopes[(person, category)]
        actual = float(target_cat.get((person, week, category), 0))
        responded = bool(rng.random() < base.RESPONSE_RATE)
        reported_probability = None

        if scope == "thisOccurrence":
            reported_occurrence = actual > 0
            if responded and rng.random() > base.INTENT_ACCURACY:
                reported_occurrence = not reported_occurrence
            reported_amount = None
            if responded and reported_occurrence:
                reference = actual if actual > 0 else float(pop_amount[category])
                reported_amount = float(
                    reference * rng.lognormal(0, base.AMOUNT_LOG_ERROR)
                )
        else:
            latent = latent_lookup.get((person, category), {
                "test_typical_amount": float(pop_amount[category]),
                "test_occurrence_probability": float(pop_occurrence[category]),
            })
            reported_probability = float(np.clip(
                latent["test_occurrence_probability"] + rng.normal(0, 0.08),
                0.05, 0.95,
            )) if responded else None
            reported_occurrence = bool(
                reported_probability is not None and reported_probability >= 0.5
            )
            reported_amount = (float(
                latent["test_typical_amount"]
                * rng.lognormal(0, base.AMOUNT_LOG_ERROR)
            ) if responded else None)

        answers[(person, category)] = {
            "actual": actual,
            "responded": responded,
            "reported_occurrence": reported_occurrence,
            "reported_probability": reported_probability,
            "reported_amount": reported_amount,
            "category_correct": bool(
                responded and rng.random() < base.CATEGORY_CORRECTION_ACCURACY
            ),
        }
    return answers


def apply_answers_conservatively(meta, p, cond, scopes, answers):
    p, cond = p.copy(), cond.copy()
    queried = np.zeros(len(meta), bool)
    responded = np.zeros(len(meta), bool)
    for i, row in enumerate(meta.itertuples(index=False)):
        key = (int(row.person), str(row.category))
        if key not in scopes:
            continue
        queried[i] = True
        answer = answers[key]
        responded[i] = answer["responded"]
        if not answer["responded"] or scopes[key] != "thisOccurrence":
            continue
        p[i] = 0.88 if answer["reported_occurrence"] else 0.12
        if answer["reported_amount"] is not None:
            cond[i] = 0.65 * answer["reported_amount"] + 0.35 * cond[i]
    return p, cond, queried, responded


def bootstrap_condition_delta(category: pd.DataFrame, left: str, right: str,
                              metric_scope: str, n_boot=1500):
    data = category[(category.모델.isin([left, right])) & (category.사용주차 == 8)]
    if metric_scope == "unqueried":
        data = data[~data.comparison_queried]
    totals = data.groupby(["모델", "person"])[["actual", "prediction"]].sum().reset_index()
    pivot = totals.pivot(index="person", columns="모델", values=["actual", "prediction"])
    people = pivot.index.to_numpy()
    rng = np.random.default_rng(SEED + (1 if metric_scope == "unqueried" else 0))

    def delta(sample):
        left_wape = base.wape(pivot.loc[sample, ("actual", left)],
                              pivot.loc[sample, ("prediction", left)])
        right_wape = base.wape(pivot.loc[sample, ("actual", right)],
                               pivot.loc[sample, ("prediction", right)])
        return left_wape - right_wape

    point = delta(people)
    draws = [delta(rng.choice(people, len(people), replace=True)) for _ in range(n_boot)]
    low, high = np.quantile(draws, [0.025, 0.975])
    return float(point), float(low), float(high)


def make_figures(summary: pd.DataFrame) -> None:
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    ink, muted, line, canvas = "#25241F", "#747168", "#E6E2D8", "#FBFAF7"
    palette = {"LightGBM Passive": "#BDB9AF", "LightGBM Active": "#2A72E5",
               "KB Tune Personal": "#7A5CF0"}
    figures = OUT / "figures"; figures.mkdir(parents=True, exist_ok=True)

    def chart(metric, title, subtitle, stem, ylabel):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.91, title, fontproperties=medium, fontsize=24, color=ink)
        fig.text(0.06, 0.865, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
        for model in palette:
            g = summary[summary.모델 == model].sort_values("사용주차")
            ax.plot(g.사용주차, g[metric] * 100, label=model, color=palette[model],
                    linewidth=3 if model == "KB Tune Personal" else 2.2,
                    marker="o", markersize=6)
        ax.set_xticks(range(1, 9)); ax.set_xlim(0.8, 8.2)
        ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
        ax.set_ylabel(ylabel, fontproperties=light, color=muted, labelpad=12)
        ax.grid(axis="y", color=line); ax.set_axisbelow(True)
        for spine in ax.spines.values(): spine.set_visible(False)
        ax.legend(frameon=False, prop=medium)
        fig.savefig(figures / f"{stem}.png", dpi=144, facecolor=canvas)
        fig.savefig(figures / f"{stem}.svg", facecolor=canvas)
        plt.close(fig)

    chart("총액_WAPE", "개인 Bayesian 보정 검증: 8주차 성능 악화",
          "LightGBM + 주 1회 장기 학습 · 8주차 Active 34.1%, Personal 36.4% · 낮을수록 정확 · 확대 축",
          "01_total_wape", "총액 WAPE")
    chart("미질문_WAPE", "미질문 일반화는 확인되지 않음",
          "현재 주 질문 카테고리 제외 · 8주차 Active 55.6%, Personal 57.6% · 낮을수록 정확 · 확대 축",
          "02_unqueried_wape", "미질문 WAPE")


def main() -> None:
    calibration = json.loads(CALIBRATION.read_text(encoding="utf-8"))
    true_tx, calendar, latent = generate_persistent(calibration)
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
    passive_idx = base.make_index(observed, calendar)

    X_train, _, y_train = base.build_rows(
        range(N_PRIOR_PEOPLE), range(base.HISTORY_WEEKS, FIRST_TEST_WEEK),
        passive_idx, target_cat, pop_amount, pop_occurrence,
    )
    fitted = [model for model in base.models(seed=SEED) if model.name == "LightGBM"]
    for model in fitted:
        model.fit(X_train, y_train)
    lgbm = next(model for model in fitted if model.name == "LightGBM")
    sigma = base.conditional_sigma(lgbm, X_train, y_train)

    corrected_ids: set[int] = set()
    bayes = PersonalBayes()
    persistent_history: dict[tuple[int, str], int] = {}
    answer_rng = np.random.default_rng(SEED + 99)
    summaries, details, feedback_rows = [], [], []

    for app_week in range(1, base.APP_WEEKS + 1):
        week = FIRST_TEST_WEEK + app_week - 1
        active_observed = observed.copy()
        if corrected_ids:
            mask = active_observed.tx_id.isin(corrected_ids)
            active_observed.loc[mask, "category"] = active_observed.loc[mask, "true_category"]
        active_idx = base.make_index(active_observed, calendar)
        X_passive, meta, actual = base.build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], passive_idx, target_cat,
            pop_amount, pop_occurrence,
        )
        X_active, active_meta, active_actual = base.build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], active_idx, target_cat,
            pop_amount, pop_occurrence,
        )
        assert meta.equals(active_meta) and np.array_equal(actual, active_actual)
        passive_p, passive_amount = lgbm.predict(X_passive)
        active_p, active_amount = lgbm.predict(X_active)
        scopes = select_scopes(
            meta, X_passive, (passive_p, passive_amount), app_week,
            persistent_history,
        )
        selected = set(scopes)
        answers = simulate_scoped_answers(
            scopes, week, target_cat, pop_amount, pop_occurrence,
            latent_lookup, answer_rng,
        )
        comparison_queried = np.array([
            (int(row.person), str(row.category)) in selected
            for row in meta.itertuples(index=False)
        ], bool)

        # 장기 적용에 명시 동의한 한 질문만 개인 상태를 갱신한다.
        lookup = {(int(row.person), str(row.category)): i
                  for i, row in enumerate(meta.itertuples(index=False))}
        for key, scope in scopes.items():
            if scope == "futureDefault":
                i = lookup[key]
                bayes.update(key[0], key[1], active_p[i], active_amount[i], answers[key])
            feedback_rows.append({
                "사용주차": app_week, "person": key[0], "category": key[1],
                "scope": scope, **answers[key],
            })

        active_direct = apply_answers_conservatively(
            meta, active_p, active_amount, scopes, answers,
        )
        personal_p, personal_amount = bayes.adjust(meta, active_p, active_amount)
        personal = apply_answers_conservatively(
            meta, personal_p, personal_amount, scopes, answers,
        )
        conditions = [
            ("LightGBM Passive", passive_p, passive_amount,
             np.zeros(len(meta), bool), np.zeros(len(meta), bool)),
            ("LightGBM Active", *active_direct),
            ("KB Tune Personal", *personal),
        ]
        for model_index, (name, p, amount, queried, responded) in enumerate(conditions):
            summary, detail, _ = base.summarize_week(
                name, name, app_week, meta, actual, p, amount,
                queried, responded, comparison_queried, sigma,
                seed=SEED + app_week * 100 + model_index,
            )
            summary["모델"] = name
            summaries.append(summary)
            detail["모델"] = name
            details.append(detail)

        for key, answer in answers.items():
            if answer["category_correct"]:
                ids = observed[(observed.person == key[0]) & (observed.week == week)
                               & (observed.true_category == key[1])].tx_id
                corrected_ids.update(ids.astype(int).tolist())
        print(f"{app_week}주 완료")

    summary = pd.DataFrame(summaries)
    category = pd.concat(details, ignore_index=True)
    feedback = pd.DataFrame(feedback_rows)
    total_ci = bootstrap_condition_delta(
        category, "LightGBM Active", "KB Tune Personal", "total",
    )
    unqueried_ci = bootstrap_condition_delta(
        category, "LightGBM Active", "KB Tune Personal", "unqueried",
    )
    week8 = summary[summary.사용주차 == 8].sort_values("총액_WAPE")

    OUT.mkdir(parents=True, exist_ok=True)
    summary.to_csv(OUT / "summary.csv", index=False)
    category.to_csv(OUT / "category_predictions.csv", index=False)
    feedback.to_csv(OUT / "feedback.csv", index=False)
    latent.to_csv(OUT / "latent_personality.csv", index=False)
    make_figures(summary)

    report = f"""# 개인 Bayesian 피드백 1~8주 재실험

## 결론

- LightGBM Active 대비 KB Tune Personal의 8주차 총액 WAPE 개선폭: **{total_ci[0]*100:.2f}%p**
- 총액 개선폭 사용자 bootstrap 95% 구간: **{total_ci[1]*100:.2f}~{total_ci[2]*100:.2f}%p**
- 현재 주 질문을 제외한 일반화 개선폭: **{unqueried_ci[0]*100:.2f}%p**
- 일반화 개선폭 사용자 bootstrap 95% 구간: **{unqueried_ci[1]*100:.2f}~{unqueried_ci[2]*100:.2f}%p**
- 판정: **미질문 일반화가 확인되지 않았으므로 '빠르게 개인화된다'는 주장을 사용하지 않는다.**
- 개인 Bayesian 레이어는 실제 파일럿에서 사용자에게 노출하지 않고 shadow mode로 검증한다.

## 8주차 결과

{week8.to_markdown(index=False, floatfmt='.4f')}

## 실험 변경점

- 주 2회 중 1회는 `thisOccurrence`, 1회는 `futureDefault`로 분리.
- `thisOccurrence` 응답은 현재 발생 사실에서 생성하고 현재 주 예측에만 즉시 반영.
- `futureDefault` 응답은 잠재 개인의 평소 금액·발생률에서 생성하며 현재 주 예측을 직접 덮어쓰지 않음.
- `futureDefault` 응답만 개인 발생 odds와 로그금액 Bayesian 상태에 반영.
- 글로벌 LightGBM은 재학습하지 않고 기기 내 충분통계량만 갱신.
- 평가 시작 시 일부 사용자의 생활 규모와 두 카테고리 성향이 바뀌고 8주간 지속되는 상황을 포함.
- 현재 주에 직접 질문한 동일 카테고리를 모든 조건의 미질문 지표에서 제외.
- 장기 학습 질문은 같은 사용자×카테고리에 {PERSISTENT_QUESTION_COOLDOWN}주 동안 다시 묻지 않음.

## 로컬 데이터 보정

- 경기 하루 집계에서 카페·외식·생활·자기관리 객단가를 기존 사전값과 기하평균으로 축소 결합.
- AI Hub 합성 월 패널의 개인 지속성은 원 상관 0.938을 그대로 쓰지 않고 **{APPLIED_PERSISTENCE:.2f} 상한의 보수적 설계 근거**로만 사용.
- 평가 시점 생활변화 SD: 전체 {LIFESTYLE_GLOBAL_SD:.2f}, 카테고리 금액 {LIFESTYLE_CATEGORY_SD:.2f}, 발생 log-odds {LIFESTYLE_OCCURRENCE_SD:.2f}.

## 제한

- 지속 생활변화는 실제 관측이 아니라 명시적인 합성 가정이다.
- 지역 원자료는 하루·한 지역이고 AI Hub 자료도 합성 월 집계다.
- 따라서 일반화가 유의하더라도 제품 가능성의 시뮬레이션 증거이며, ‘빠르게 개인화된다’는 대외 주장은 20~50명 파일럿 전에는 조건부로만 표현해야 한다.
- 현재 Bayesian 금액 상태는 사용자의 평소 건당 금액과 모델의 주간 조건부 카테고리 금액 사이 단위 차이에 민감할 수 있다. 이는 성능 저하의 가능한 원인이며 실제 파일럿에서는 두 값을 별도 필드로 수집·평가한다.
"""
    (OUT / "results.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
