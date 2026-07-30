"""동일한 카드·캘린더 피처로 회귀 모델과 KB Tune 모델을 1~8주 비교한다."""
from __future__ import annotations

from bisect import bisect_left
from pathlib import Path
import warnings

import numpy as np
import pandas as pd

from card_calendar_bench import (
    FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE, N_WEEKS,
    PRIOR_STRENGTH_DAYS, SPECS, fit_priors, generate, run,
)
from metrics import wape


HERE = Path(__file__).parent
OUT = HERE / "results/model_comparison_8week"
SEED = 20260730


def indexes(tx: pd.DataFrame, calendar: pd.DataFrame):
    weekly_amount = tx.groupby(["person", "week", "category"]).amount.sum().to_dict()
    weekly_count = tx.groupby(["person", "week", "category"]).size().to_dict()
    total = tx.groupby(["person", "week"]).amount.sum().to_dict()
    days = {key: sorted(g.day.astype(int).tolist())
            for key, g in tx.groupby(["person", "category"])}
    cal_count = calendar.groupby(["person", "week", "category"]).size().to_dict()
    return weekly_amount, weekly_count, total, days, cal_count


def population_amounts(tx: pd.DataFrame) -> dict[str, float]:
    train = tx[(tx.person < N_PRIOR_PEOPLE) & (tx.week < FIRST_TEST_WEEK)]
    return train.groupby("category").amount.median().to_dict()


def build_rows(people: range, forecast_weeks: range, history_weeks: int,
               idx, pop_amount: dict[str, float]
               ) -> tuple[pd.DataFrame, np.ndarray, np.ndarray, np.ndarray]:
    weekly_amount, weekly_count, total, days, cal_count = idx
    rows, targets, persons, weeks_out = [], [], [], []
    categories = [s.category for s in SPECS]

    for person in people:
        for week in forecast_weeks:
            history = list(range(week - history_weeks, week))
            row: dict[str, float] = {"history_weeks": float(history_weeks)}
            total_lags = [float(total.get((person, w), 0)) for w in history]
            for lag, value in enumerate(reversed(total_lags), 1):
                row[f"total_lag{lag}"] = value
            row["total_mean"] = float(np.mean(total_lags))
            row["total_median"] = float(np.median(total_lags))
            row["total_std"] = float(np.std(total_lags))
            row["active_week_rate"] = float(np.mean(np.asarray(total_lags) > 0))

            expected_calendar = 0.0
            for ci, category in enumerate(categories):
                amounts = np.array([weekly_amount.get((person, w, category), 0.0)
                                    for w in history], float)
                counts = np.array([weekly_count.get((person, w, category), 0.0)
                                   for w in history], float)
                prefix = f"c{ci}"
                row[f"{prefix}_mean"] = float(amounts.mean())
                row[f"{prefix}_last"] = float(amounts[-1])
                row[f"{prefix}_occur"] = float((amounts > 0).mean())
                row[f"{prefix}_count"] = float(counts.mean())
                observed_days = days.get((person, category), [])
                pos = bisect_left(observed_days, week * 7)
                last_day = observed_days[pos - 1] if pos else None
                row[f"{prefix}_elapsed"] = float(week * 7 - last_day) if last_day is not None else 365.0
                n_calendar = float(cal_count.get((person, week, category), 0))
                row[f"{prefix}_calendar"] = n_calendar
                expected_calendar += n_calendar * float(pop_amount.get(category, 0))
            row["calendar_expected"] = expected_calendar
            row["calendar_count"] = sum(row[f"c{i}_calendar"] for i in range(len(categories)))
            rows.append(row)
            targets.append(float(total.get((person, week), 0)))
            persons.append(person)
            weeks_out.append(week)

    return (pd.DataFrame(rows).fillna(0), np.asarray(targets),
            np.asarray(persons), np.asarray(weeks_out))


def align(train: pd.DataFrame, test: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    columns = sorted(set(train.columns) | set(test.columns))
    return train.reindex(columns=columns, fill_value=0), test.reindex(columns=columns, fill_value=0)


def fit_predict(X_train: pd.DataFrame, y_train: np.ndarray,
                X_test: pd.DataFrame):
    from lightgbm import LGBMRegressor
    from sklearn.ensemble import RandomForestRegressor
    from sklearn.linear_model import Ridge
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    models = {
        "Ridge": make_pipeline(StandardScaler(), Ridge(alpha=10.0, solver="lsqr")),
        "Random Forest": RandomForestRegressor(
            n_estimators=220, min_samples_leaf=8, max_features=0.75,
            n_jobs=-1, random_state=SEED,
        ),
        "LightGBM": LGBMRegressor(
            objective="regression_l1", n_estimators=350, learning_rate=0.04,
            num_leaves=24, min_child_samples=35, reg_lambda=1.0,
            verbose=-1, random_state=SEED,
        ),
    }
    out = {}
    for name, model in models.items():
        # macOS Accelerate가 Ridge predict의 유한 행렬곱에도 overflow 경고를 내는
        # 환경이 있다. 출력 유한성은 아래 assert로 별도 검증한다.
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=RuntimeWarning,
                                    module="sklearn.utils.extmath")
            model.fit(X_train, y_train)
            pred = model.predict(X_test)
        assert np.isfinite(pred).all(), f"{name} 예측에 비유한값"
        out[name] = np.clip(pred, 0, None)
    return out, models["LightGBM"]


def hybrid_personalize(model, X_context: pd.DataFrame, y_context: np.ndarray,
                       people_context: np.ndarray, weeks_context: np.ndarray,
                       base_test: np.ndarray, people_test: np.ndarray,
                       weeks_test: np.ndarray, history_weeks: int) -> np.ndarray:
    """LightGBM 예측의 개인별 log 잔차를 Bayesian shrinkage로 보정한다."""
    base_context = np.clip(model.predict(X_context), 0, None)
    history: dict[tuple[int, int], float] = {}
    smooth = 10_000.0
    for person, week, actual, pred in zip(
            people_context, weeks_context, y_context, base_context):
        history[(int(person), int(week))] = float(
            np.log((actual + smooth) / (pred + smooth)))

    out = np.empty_like(base_test)
    prior_weeks = 3.0
    for i, (person, week, pred) in enumerate(zip(people_test, weeks_test, base_test)):
        residuals = [history[(int(person), w)]
                     for w in range(int(week) - history_weeks, int(week))
                     if (int(person), w) in history]
        if residuals:
            weight = len(residuals) / (len(residuals) + prior_weeks)
            factor = float(np.exp(weight * np.median(residuals)))
            factor = float(np.clip(factor, 0.65, 1.55))
        else:
            factor = 1.0
        out[i] = pred * factor
    return np.clip(out, 0, None)


def main() -> None:
    tx, calendar = generate()
    priors = fit_priors(tx)
    idx = indexes(tx, calendar)
    pop_amount = population_amounts(tx)
    rows = []

    for history_weeks in range(1, 9):
        # 인구 모델은 평가 시점 이전의 여러 주차를 사용한다. 평가 사용자는 들어가지 않는다.
        train_start = max(history_weeks, 8)
        X_train, y_train, _, _ = build_rows(
            range(N_PRIOR_PEOPLE), range(train_start, FIRST_TEST_WEEK),
            history_weeks, idx, pop_amount,
        )
        X_test, y_test, people, test_weeks = build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), range(FIRST_TEST_WEEK, N_WEEKS),
            history_weeks, idx, pop_amount,
        )
        X_train, X_test = align(X_train, X_test)

        naive = np.clip(X_test["total_mean"].to_numpy(float) +
                        X_test["calendar_expected"].to_numpy(float), 0, None)
        regression, lgbm = fit_predict(X_train, y_train, X_test)
        predictions = {"최근 평균 + 캘린더": naive, **regression}

        context_start = FIRST_TEST_WEEK - history_weeks
        X_context, y_context, context_people, context_weeks = build_rows(
            range(N_PRIOR_PEOPLE, N_PEOPLE), range(context_start, N_WEEKS),
            history_weeks, idx, pop_amount,
        )
        X_context = X_context.reindex(columns=X_train.columns, fill_value=0)
        predictions["KB Tune Hybrid"] = hybrid_personalize(
            lgbm, X_context, y_context, context_people, context_weeks,
            regression["LightGBM"], people, test_weeks, history_weeks,
        )

        kb_pred, _ = run(tx, calendar, priors, lookback_weeks=history_weeks, n_draws=120)
        kb = (kb_pred[kb_pred.model == "R2 + 캘린더"]
              .sort_values(["person", "week"]).p50.to_numpy(float))
        predictions["KB Tune Bayesian"] = kb

        for model, pred in predictions.items():
            rows.append({
                "사용주차": history_weeks, "모델": model,
                "WAPE": wape(y_test, pred), "WAPE기반정확도": 1 - wape(y_test, pred),
                "편향": float((pred - y_test).sum() / y_test.sum()),
                "평가행": len(y_test), "평가사용자": len(np.unique(people)),
                "학습행": len(y_train),
            })
        print(f"{history_weeks}주 완료")

    result = pd.DataFrame(rows)
    OUT.mkdir(parents=True, exist_ok=True)
    result.to_csv(OUT / "results.csv", index=False)
    week8 = result[result.사용주차 == 8].sort_values("WAPE")
    report = f"""# 1~8주 모델 비교

## 조건

- 모든 모델에 동일한 카드 이력·카테고리 요약·경과일·다음 주 캘린더 피처 제공
- 인구 학습 300명과 평가 100명 완전 분리
- 평가 사용자 100명의 미래 20주, 총 {int(week8.평가행.iloc[0]):,}행
- 타깃: 다음 주 총 카드 소비, 지표: WAPE

## 8주 결과

{week8.to_markdown(index=False, floatfmt=".4f")}

## 전체 곡선

{result.to_markdown(index=False, floatfmt=".4f")}

## 모델 정의

- Ridge: 표준화된 선형 L2 회귀
- Random Forest: 220개 트리, leaf 최소 8
- LightGBM: L1 목적함수 gradient boosting
- KB Tune Bayesian: Gamma-Poisson/Weibull 발생 + 로그정규 금액 사후분포 + 캘린더 일정
- KB Tune Hybrid: LightGBM 인구 예측 + 최근 개인 log 잔차의 온디바이스 Bayesian 보정

## 제한

- 합성 데이터 결과이며 실사용자 성능이 아니다.
- 생성 구조가 반복 소비와 예정 소비를 명시하므로 구조 모델에 유리할 수 있다.
- 회귀 모델의 하이퍼파라미터는 테스트셋으로 튜닝하지 않았다.
- Bayesian 갈래의 인구 사전분포 무게는 `sweep_prior_strength.py` 로 고른
  {PRIOR_STRENGTH_DAYS:.0f}일이다. 첫 실행은 28일이었고 그 설정에서는 8주차 WAPE가
  0.4176, LightGBM 격차가 +9.9%였다. 무게를 고친 뒤 격차는 +5.1%로 줄었다.

## 현재 판단

- 점예측은 LightGBM이 가장 좋다. 순수 renewal Bayesian 모델이 더 정확하다는 주장은 기각한다.
  **사전분포 무게를 스윕한 뒤에도 기각은 유지된다** — 격차가 절반으로 줄지만 뒤집히지 않는다.
- 시험한 개인 잔차 보정 Hybrid도 LightGBM 단독을 이기지 못했다.
- 제품 후보는 LightGBM 점예측 + Bayesian 발생확률·구간·온디바이스 상태 갱신의 역할 분담이다.
- **미해결**: LightGBM은 인구 300명으로 학습한 전역 모델이다. 온디바이스 배포 경로
  (서버 학습 → 모델 파일 배포 vs 피처 전송)를 정하지 않으면 제품 후보로 확정할 수 없다.
  피처 전송은 앱의 "나가는 것 0건" 설계와 충돌한다.
"""
    (OUT / "results.md").write_text(report, encoding="utf-8")
    print("\n" + week8.to_string(index=False, float_format=lambda x: f"{x:.4f}"))
    print(OUT / "results.md")


if __name__ == "__main__":
    main()
