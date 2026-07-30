"""피드백 누적이 다음 주의 미질문 예측을 개선하는지 12주 동안 검증한다.

세 조건은 같은 LightGBM, 같은 카드 이력, 같은 캘린더, 같은 질문/답변을 쓴다.

* 피드백 없음: 질문을 사용하지 않는다.
* 즉시 보정만: 현재 발생 여부/금액 답변을 이번 주에만 반영한다.
* 지속 개인학습: 즉시 보정에 더해 장기 기본값 답변을 기기 내 충분통계량에 저장하고
  다음 주부터 예측 확률과 조건부 금액을 보정한다.

현재 주에 질문한 카테고리는 세 조건 모두의 주지표에서 제외한다. 따라서 지속 개인학습과
즉시 보정만의 차이는 현재 정답 입력 효과가 아니라 이전 주에 저장된 피드백의 효과다.
"""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import json

import numpy as np
import pandas as pd

import active_feedback_bench as base
import personal_bayes_feedback_bench as personal_data
from card_calendar_bench import FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE


HERE = Path(__file__).parent
OUT = HERE / "results/persistent_learning_12week"
CALIBRATION = HERE / "results/local_spend_profile/calibration.json"
SEED = 20260801
APP_WEEKS = 12
COOLDOWN_WEEKS = 4

PASSIVE = "피드백 없음"
IMMEDIATE = "즉시 보정만"
PERSISTENT = "지속 개인학습"


def logistic(value):
    value = np.clip(value, -12, 12)
    return 1 / (1 + np.exp(-value))


def logit(value):
    value = np.clip(value, 0.001, 0.999)
    return np.log(value / (1 - value))


class PersistentResidual:
    """개인·카테고리별 로그금액/발생 log-odds 잔차의 수축 평균.

    모델 파라미터를 재학습하지 않고 합·가중치만 저장한다. 장기 기본값 답변을 받을 때의
    LightGBM 예측과 사용자 답변의 차이를 저장하고, 다음 주 같은 사용자의 예측에만 쓴다.
    """

    def __init__(self):
        self.amount_global = defaultdict(lambda: [0.0, 0.0])
        self.amount_category = defaultdict(lambda: [0.0, 0.0])
        self.occurrence_global = defaultdict(lambda: [0.0, 0.0])
        self.occurrence_category = defaultdict(lambda: [0.0, 0.0])

    @staticmethod
    def _add(store, key, residual, weight):
        store[key][0] += float(residual) * weight
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
        if target_p is not None:
            residual = float(np.clip(logit(target_p) - logit(probability), -1.2, 1.2))
            self._add(self.occurrence_global, person, residual, 0.30)
            self._add(self.occurrence_category, (person, category), residual, 1.0)
        if answer.get("reported_amount") is not None:
            residual = float(np.clip(
                np.log(answer["reported_amount"] / max(conditional_amount, 1)), -0.8, 0.8,
            ))
            self._add(self.amount_global, person, residual, 0.30)
            self._add(self.amount_category, (person, category), residual, 1.0)

    def adjust(self, meta: pd.DataFrame, probability: np.ndarray,
               conditional_amount: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        p, amount = probability.copy(), conditional_amount.copy()
        for i, row in enumerate(meta.itertuples(index=False)):
            person, category = int(row.person), str(row.category)
            amount_shift = (
                0.40 * self._mean(self.amount_global, person, 2.0)
                + 0.60 * self._mean(self.amount_category, (person, category), 1.5)
            )
            occurrence_shift = (
                0.40 * self._mean(self.occurrence_global, person, 2.0)
                + 0.60 * self._mean(self.occurrence_category, (person, category), 1.5)
            )
            amount[i] *= float(np.exp(np.clip(amount_shift, -0.5, 0.5)))
            p[i] = float(logistic(logit(p[i]) + np.clip(occurrence_shift, -1.0, 1.0)))
        return np.clip(p, 0.01, 0.99), np.clip(amount, 100, None)


def select_scopes(meta: pd.DataFrame, X: pd.DataFrame,
                  prediction: tuple[np.ndarray, np.ndarray], app_week: int,
                  persistent_history: dict[tuple[int, str], int]) -> dict[tuple[int, str], str]:
    """사용자당 현재 확인 1개와 장기 기본값 1개를 실제값을 보지 않고 고른다."""
    p, cond = prediction
    ranked = meta.copy()
    ranked["priority"] = (
        p * cond + 2 * p * (1 - p) * cond + X.calendar_expected.to_numpy(float)
    )
    scopes: dict[tuple[int, str], str] = {}
    for person, group in ranked.groupby("person"):
        ordered = group.sort_values("priority", ascending=False)
        immediate = ordered.iloc[0]
        scopes[(int(person), str(immediate.category))] = "thisOccurrence"

        remaining = ordered.iloc[1:]
        eligible = remaining[remaining.category.map(
            lambda category: app_week - persistent_history.get(
                (int(person), str(category)), -COOLDOWN_WEEKS,
            ) >= COOLDOWN_WEEKS
        )]
        persistent = eligible.iloc[0] if not eligible.empty else remaining.iloc[0]
        key = (int(person), str(persistent.category))
        scopes[key] = "futureDefault"
        persistent_history[key] = app_week
    return scopes


def simulate_answers(scopes, week, target_cat, pop_amount, pop_occurrence,
                     latent_lookup, rng):
    """현재 확인은 실제 주 결과, 장기 질문은 잠재 평소 성향에서 잡음을 넣어 만든다."""
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
                reported_amount = float(reference * rng.lognormal(0, base.AMOUNT_LOG_ERROR))
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
                float(latent["test_typical_amount"] * rng.lognormal(0, base.AMOUNT_LOG_ERROR))
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


def apply_immediate(meta, p, amount, scopes, answers):
    p, amount = p.copy(), amount.copy()
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
            amount[i] = 0.65 * answer["reported_amount"] + 0.35 * amount[i]
    return p, amount, queried, responded


def bootstrap_week(category: pd.DataFrame, week: int, n_boot: int = 2000):
    data = category[(category.사용주차 == week) & (~category.comparison_queried)]
    totals = data.groupby(["조건", "person"])[["actual", "prediction"]].sum().reset_index()
    pivot = totals.pivot(index="person", columns="조건", values=["actual", "prediction"])
    people = pivot.index.to_numpy()
    rng = np.random.default_rng(SEED + week)

    def improvement(sample):
        immediate = base.wape(pivot.loc[sample, ("actual", IMMEDIATE)],
                              pivot.loc[sample, ("prediction", IMMEDIATE)])
        persistent = base.wape(pivot.loc[sample, ("actual", PERSISTENT)],
                               pivot.loc[sample, ("prediction", PERSISTENT)])
        return immediate - persistent

    point = improvement(people)
    draws = [improvement(rng.choice(people, len(people), replace=True))
             for _ in range(n_boot)]
    low, high = np.quantile(draws, [0.025, 0.975])
    return float(point), float(low), float(high)


def user_improvement_share(category: pd.DataFrame, week: int) -> float:
    data = category[(category.사용주차 == week) & (~category.comparison_queried)]
    totals = data.groupby(["조건", "person"])[["actual", "prediction"]].sum().reset_index()
    totals["absolute_error"] = np.abs(totals.actual - totals.prediction)
    pivot = totals.pivot(index="person", columns="조건", values="absolute_error")
    return float((pivot[PERSISTENT] < pivot[IMMEDIATE]).mean())


def make_figures(summary: pd.DataFrame, intervals: pd.DataFrame) -> None:
    import matplotlib.pyplot as plt
    import matplotlib as mpl
    from matplotlib import font_manager

    mpl.rcParams["axes.unicode_minus"] = False

    font_dir = HERE.parents[1] / "KB_Tune/Fonts"
    light = font_manager.FontProperties(fname=font_dir / "KBFGText-Light.otf")
    medium = font_manager.FontProperties(fname=font_dir / "KBFGText-Medium.otf")
    ink, muted, grid, canvas = "#25241F", "#747168", "#E6E2D8", "#FBFAF7"
    palette = {PASSIVE: "#BDB9AF", IMMEDIATE: "#2A72E5", PERSISTENT: "#7A5CF0"}
    figures = OUT / "figures"
    figures.mkdir(parents=True, exist_ok=True)

    def frame(title, subtitle):
        fig = plt.figure(figsize=(13.333, 7.5), dpi=144, facecolor=canvas)
        fig.text(0.06, 0.91, title, fontproperties=medium, fontsize=24, color=ink)
        fig.text(0.06, 0.865, subtitle, fontproperties=light, fontsize=11.5, color=muted)
        return fig

    fig = frame(
        "1~12주 미질문 예측 오차",
        "합성 카드 거래 · 평가 사용자 100명 · 현재 주 질문 카테고리 제외 · WAPE, 낮을수록 정확",
    )
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    for condition in [PASSIVE, IMMEDIATE, PERSISTENT]:
        group = summary[summary.조건 == condition].sort_values("사용주차")
        ax.plot(group.사용주차, group.미질문_WAPE * 100, label=condition,
                color=palette[condition], linewidth=3 if condition == PERSISTENT else 2.2,
                marker="o", markersize=5.5)
    ax.set_xticks(range(1, APP_WEEKS + 1)); ax.set_xlim(0.7, APP_WEEKS + 0.3)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("미질문 WAPE (%)", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.legend(frameon=False, prop=medium)
    fig.text(0.08, 0.07, "실사용자 성능이 아닌 합성 실험 결과",
             fontproperties=light, fontsize=10, color=muted)
    fig.savefig(figures / "01_unqueried_wape_12week.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "01_unqueried_wape_12week.svg", facecolor=canvas)
    plt.close(fig)

    fig = frame(
        "지속 개인학습의 주차별 추가 개선폭",
        "즉시 보정만 WAPE 빼기 지속 개인학습 WAPE · 양수면 누적 학습 우세 · 사용자 bootstrap 95% 구간",
    )
    ax = fig.add_axes([0.08, 0.16, 0.84, 0.64])
    x = intervals.사용주차.to_numpy(float)
    y = intervals.개선폭.to_numpy(float) * 100
    low = intervals.CI_low.to_numpy(float) * 100
    high = intervals.CI_high.to_numpy(float) * 100
    ax.axhline(0, color=ink, linewidth=1.2)
    ax.fill_between(x, low, high, color=palette[PERSISTENT], alpha=0.16)
    ax.plot(x, y, color=palette[PERSISTENT], linewidth=3, marker="o", markersize=6)
    ax.set_xticks(range(1, APP_WEEKS + 1)); ax.set_xlim(0.7, APP_WEEKS + 0.3)
    ax.set_xlabel("앱 사용 기간(주)", fontproperties=light, color=muted, labelpad=12)
    ax.set_ylabel("미질문 WAPE 개선폭 (%p)", fontproperties=light, color=muted, labelpad=12)
    ax.grid(axis="y", color=grid); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    fig.text(0.08, 0.07, "신뢰구간이 0을 넘을 때만 지속 학습 효과로 판정",
             fontproperties=light, fontsize=10, color=muted)
    fig.savefig(figures / "02_persistent_lift_12week.png", dpi=144, facecolor=canvas)
    fig.savefig(figures / "02_persistent_lift_12week.svg", facecolor=canvas)
    plt.close(fig)


def report(summary, intervals, feedback, shares) -> str:
    checkpoints = summary[summary.사용주차.isin([8, 12])].sort_values(["사용주차", "조건"])
    ci8 = intervals[intervals.사용주차 == 8].iloc[0]
    ci12 = intervals[intervals.사용주차 == 12].iloc[0]
    passed8 = ci8.CI_low > 0
    passed12 = ci12.CI_low > 0
    verdict = (
        "8주와 12주 모두 미질문 일반화가 확인됐다."
        if passed8 and passed12 else
        "12주 시점에서만 미질문 일반화가 확인됐다."
        if passed12 else
        "미질문 일반화가 통계적으로 확인되지 않았다."
    )
    return f"""# 지속 개인학습 1~12주 3그룹 실험

## 결론

- 판정: **{verdict}**
- 8주차 지속학습 추가 개선폭: **{ci8.개선폭*100:.2f}%p** (95% CI {ci8.CI_low*100:.2f}~{ci8.CI_high*100:.2f}%p)
- 12주차 지속학습 추가 개선폭: **{ci12.개선폭*100:.2f}%p** (95% CI {ci12.CI_low*100:.2f}~{ci12.CI_high*100:.2f}%p)
- 개인별 절대오차 개선 사용자 비율: 8주 **{shares[8]*100:.1f}%**, 12주 **{shares[12]*100:.1f}%**
- 응답률: **{feedback.responded.mean()*100:.1f}%**, 사용자당 주 2회 질문

## 8주·12주 결과

{checkpoints.to_markdown(index=False, floatfmt='.4f')}

## 주차별 지속학습 추가 개선폭

{intervals.to_markdown(index=False, floatfmt='.4f')}

## 실험 계약

- 데이터: 지속 개인 성향과 평가 시작 시 생활변화를 포함한 합성 카드 거래 400명 × 52주.
- 분할: 인구 모델 학습 300명, 순차 평가 100명. 현금·미관측 결제는 사용하지 않음.
- 공통 입력: 최근 카드 이력 8주 + 캘린더. 세 조건 모두 시간이 지나며 같은 카드 이력을 봄.
- 피드백 없음: 사용자 답변을 사용하지 않음.
- 즉시 보정만: 현재 발생 여부·금액 확인을 이번 주에만 반영하고 저장하지 않음.
- 지속 개인학습: 즉시 보정 + 장기 기본값 답변의 로그금액·발생 log-odds 잔차를 기기 내 충분통계량에 저장.
- 시간 순서: 예측 → 평가 → 개인 상태 갱신. 이번 주 장기 답변은 다음 주부터만 사용.
- 주지표: 현재 주에 질문한 카테고리를 세 조건 모두에서 제외한 사용자 합산 WAPE.
- 질문 선택은 기본 LightGBM의 영향도·불확실성·캘린더만 사용하며 실제값을 보지 않음.

## 판정 기준

- 지속학습 효과 = `즉시 보정만 WAPE − 지속 개인학습 WAPE`.
- 사용자 bootstrap 95% 구간의 하한이 0보다 클 때만 미질문 일반화로 인정.
- 8주와 12주를 사전에 정한 판정점으로 함께 보고하고 유리한 한 주만 고르지 않음.

## 제한

- 합성 데이터이므로 실제 사용자 성능이나 인과효과를 주장할 수 없음.
- 장기 기본값 답변은 생성기에 숨겨진 개인 성향에서 잡음을 넣어 생성함.
- 개인 잔차 보정의 가중치·수축 강도는 이 평가 결과로 튜닝하지 않은 고정 설계값임.
- 실제 발표의 최종 주장은 20~50명 12주 파일럿에서 같은 프로토콜로 재검증해야 함.
"""


def main() -> None:
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
    lgbm = next(model for model in base.models(seed=SEED) if model.name == "LightGBM")
    lgbm.fit(X_train, y_train)
    sigma = base.conditional_sigma(lgbm, X_train, y_train)

    learner = PersistentResidual()
    persistent_history: dict[tuple[int, str], int] = {}
    answer_rng = np.random.default_rng(SEED + 99)
    summaries, details, feedback_rows = [], [], []

    for app_week in range(1, APP_WEEKS + 1):
        week = FIRST_TEST_WEEK + app_week - 1
        X, meta, actual = base.build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), [week], index, target_cat,
            pop_amount, pop_occurrence,
        )
        base_p, base_amount = lgbm.predict(X)
        scopes = select_scopes(meta, X, (base_p, base_amount), app_week, persistent_history)
        answers = simulate_answers(
            scopes, week, target_cat, pop_amount, pop_occurrence, latent_lookup, answer_rng,
        )
        comparison_queried = np.array([
            (int(row.person), str(row.category)) in scopes
            for row in meta.itertuples(index=False)
        ], bool)

        immediate = apply_immediate(meta, base_p, base_amount, scopes, answers)
        learned_p, learned_amount = learner.adjust(meta, base_p, base_amount)
        persistent = apply_immediate(meta, learned_p, learned_amount, scopes, answers)
        conditions = [
            (PASSIVE, base_p, base_amount, np.zeros(len(meta), bool), np.zeros(len(meta), bool)),
            (IMMEDIATE, *immediate),
            (PERSISTENT, *persistent),
        ]
        for condition_index, (condition, p, amount, queried, responded) in enumerate(conditions):
            summary, detail, _ = base.summarize_week(
                "LightGBM", condition, app_week, meta, actual, p, amount,
                queried, responded, comparison_queried, sigma,
                seed=SEED + app_week * 100 + condition_index,
            )
            summaries.append(summary)
            details.append(detail)

        # 엄격한 시간 분리: 이번 주 평가가 끝난 뒤에만 장기 상태를 갱신한다.
        lookup = {(int(row.person), str(row.category)): i
                  for i, row in enumerate(meta.itertuples(index=False))}
        for key, scope in scopes.items():
            feedback_rows.append({
                "사용주차": app_week, "person": key[0], "category": key[1],
                "scope": scope, **answers[key],
            })
            if scope == "futureDefault":
                i = lookup[key]
                learner.update(key[0], key[1], base_p[i], base_amount[i], answers[key])
        print(f"{app_week}주 완료")

    summary = pd.DataFrame(summaries)
    category = pd.concat(details, ignore_index=True)
    feedback = pd.DataFrame(feedback_rows)
    interval_rows = []
    shares = {}
    for week in range(1, APP_WEEKS + 1):
        point, low, high = bootstrap_week(category, week)
        interval_rows.append({"사용주차": week, "개선폭": point, "CI_low": low, "CI_high": high})
        shares[week] = user_improvement_share(category, week)
    intervals = pd.DataFrame(interval_rows)

    OUT.mkdir(parents=True, exist_ok=True)
    summary.to_csv(OUT / "summary.csv", index=False)
    category.to_csv(OUT / "category_predictions.csv", index=False)
    feedback.to_csv(OUT / "feedback.csv", index=False)
    intervals.to_csv(OUT / "bootstrap_intervals.csv", index=False)
    (OUT / "results.md").write_text(
        report(summary, intervals, feedback, shares), encoding="utf-8",
    )
    make_figures(summary, intervals)
    print(summary[summary.사용주차.isin([8, 12])].to_string(index=False))
    print(OUT / "results.md")


if __name__ == "__main__":
    main()
