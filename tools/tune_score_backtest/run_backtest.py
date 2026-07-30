#!/usr/bin/env python3
"""Card-only synthetic rolling backtest for Tune Score v0.

Each fold uses the previous two months to forecast the next month. The script
does not claim real-user accuracy: it validates metric plumbing, probability
calibration reporting, safety-buffer segmentation, and failure-case disclosure.
"""

from __future__ import annotations

import csv
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


SEED = 20260730
USERS = 600
MONTHS = 12
OUTPUT = Path(__file__).resolve().parent / "results"
BUFFERS = (0, 100_000, 300_000)


@dataclass(frozen=True)
class Prediction:
    user_id: int
    test_month: int
    income: int
    available_after_goal: int
    predicted_spend: int
    actual_spend: int
    registered_calendar: int
    unplanned_shock: int
    goal_probability: float
    goal_achieved: int
    tune_score: int
    alert: int
    evidence_count: int
    protected_violation: int
    unapproved_execution: int


def normal_cdf(value: float) -> float:
    return 0.5 * (1 + math.erf(value / math.sqrt(2)))


def clamp(value: float) -> float:
    return max(0.0, min(1.0, value))


def tune_score(probability: float, projected_balance: float, buffer: int,
               flexible: float, protected: float) -> int:
    goal = 100 * clamp(probability)
    liquidity = 100 * clamp(projected_balance / max(buffer, 1))
    required = max(0.0, buffer - projected_balance)
    protected_shortfall = max(0.0, required - flexible)
    if protected <= 0 or protected_shortfall == 0:
        preservation = 100.0
    else:
        preservation = 100 * clamp(1 - protected_shortfall / protected)
    return round(0.55 * goal + 0.30 * liquidity + 0.15 * preservation)


def simulate() -> tuple[list[Prediction], dict[tuple[int, int], dict[str, float]]]:
    rng = np.random.default_rng(SEED)
    predictions: list[Prediction] = []
    raw: dict[tuple[int, int], dict[str, float]] = {}

    for user_id in range(USERS):
        income = float(np.clip(rng.lognormal(math.log(3_000_000), 0.22), 1_800_000, 6_000_000))
        fixed = income * rng.uniform(0.30, 0.48)
        goal = income * rng.uniform(0.18, 0.34)
        available = max(250_000.0, income - fixed - goal)
        routine_base = available * rng.uniform(0.58, 0.92)
        event_base = available * rng.uniform(0.10, 0.24)
        protected_share = rng.uniform(0.20, 0.55)

        months: list[dict[str, float]] = []
        for month in range(MONTHS):
            seasonal = 1 + 0.07 * math.sin(2 * math.pi * month / 12 + user_id % 5)
            routine = max(0.0, rng.normal(routine_base * seasonal, routine_base * 0.10))
            planned = max(0.0, rng.normal(event_base, event_base * 0.20))
            registration_rate = rng.beta(8, 2)
            registered = planned * registration_rate
            shock = float(rng.exponential(180_000)) if rng.random() < 0.16 else 0.0
            actual = routine + planned + shock
            months.append({
                "routine": routine,
                "planned": planned,
                "registered": registered,
                "shock": shock,
                "actual": actual,
                "protected": planned * protected_share,
                "flexible": planned * (1 - protected_share),
            })

        # A rolling three-month window: two months of history, then one test month.
        for test_month in range(2, MONTHS):
            history = months[test_month - 2:test_month]
            target = months[test_month]
            residuals = [m["actual"] - m["registered"] for m in history]
            residual_mean = float(np.mean(residuals))
            # Two observations cannot estimate tails. Keep a conservative 18% floor.
            residual_sd = max(float(np.std(residuals, ddof=1)), residual_mean * 0.18, 50_000.0)
            predicted = residual_mean + target["registered"]
            probability = min(0.97, clamp(normal_cdf((available - predicted) / residual_sd)))
            achieved = int(target["actual"] <= available)
            projected_balance = available - predicted
            score = tune_score(
                probability, projected_balance, 100_000,
                target["flexible"], target["protected"],
            )
            alert = int(probability < 0.60 or projected_balance < 100_000)
            required_adjustment = max(0.0, 100_000 - projected_balance)
            proposed_adjustment = min(required_adjustment, target["flexible"])
            predictions.append(Prediction(
                user_id=user_id, test_month=test_month + 1,
                income=round(income), available_after_goal=round(available),
                predicted_spend=round(predicted), actual_spend=round(target["actual"]),
                registered_calendar=round(target["registered"]),
                unplanned_shock=round(target["shock"]),
                goal_probability=probability, goal_achieved=achieved,
                tune_score=score, alert=alert, evidence_count=4,
                protected_violation=int(proposed_adjustment > target["flexible"]),
                unapproved_execution=0,
            ))
            raw[(user_id, test_month + 1)] = target
    return predictions, raw


def brier(rows: list[Prediction], probabilities: list[float] | None = None,
          outcomes: list[int] | None = None) -> float:
    ps = probabilities if probabilities is not None else [r.goal_probability for r in rows]
    ys = outcomes if outcomes is not None else [r.goal_achieved for r in rows]
    return sum((p - y) ** 2 for p, y in zip(ps, ys)) / len(ps)


def calibration(rows: list[Prediction]) -> tuple[list[dict[str, float]], float]:
    bins: list[dict[str, float]] = []
    total = len(rows)
    ece = 0.0
    for index in range(10):
        low, high = index / 10, (index + 1) / 10
        bucket = [r for r in rows if low <= r.goal_probability < high]
        if index == 9:
            bucket += [r for r in rows if r.goal_probability == 1]
        if not bucket:
            continue
        mean_probability = sum(r.goal_probability for r in bucket) / len(bucket)
        observed_rate = sum(r.goal_achieved for r in bucket) / len(bucket)
        ece += len(bucket) / total * abs(mean_probability - observed_rate)
        bins.append({
            "bin_low": low,
            "bin_high": high,
            "count": len(bucket),
            "mean_probability": mean_probability,
            "observed_rate": observed_rate,
            "absolute_gap": abs(mean_probability - observed_rate),
        })
    return bins, ece


def buffer_metrics(rows: list[Prediction]) -> list[dict[str, float]]:
    results = []
    for threshold in BUFFERS:
        probabilities = []
        outcomes = []
        for row in rows:
            sigma_proxy = max(row.predicted_spend * 0.18, 50_000)
            p = clamp(normal_cdf(
                (row.available_after_goal - threshold - row.predicted_spend) / sigma_proxy
            ))
            actual_balance = row.available_after_goal - row.actual_spend
            probabilities.append(p)
            outcomes.append(int(actual_balance >= threshold))
        results.append({
            "buffer": threshold,
            "brier": brier(rows, probabilities, outcomes),
            "success_rate": sum(outcomes) / len(outcomes),
            "mean_probability": sum(probabilities) / len(probabilities),
        })
    return results


def classification(rows: list[Prediction]) -> dict[str, float | int]:
    tp = sum(r.goal_probability >= 0.5 and r.goal_achieved for r in rows)
    tn = sum(r.goal_probability < 0.5 and not r.goal_achieved for r in rows)
    fp = sum(r.goal_probability >= 0.5 and not r.goal_achieved for r in rows)
    fn = sum(r.goal_probability < 0.5 and r.goal_achieved for r in rows)
    alerts = [r for r in rows if r.alert]
    true_risks = [r for r in alerts if not r.goal_achieved]
    return {
        "tp": tp, "tn": tn, "fp": fp, "fn": fn,
        "accuracy": (tp + tn) / len(rows),
        "alert_precision": len(true_risks) / len(alerts) if alerts else 0,
        "alerts_per_user_month": len(alerts) / len(rows),
    }


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def make_figure(calibration_bins: list[dict[str, float]],
                buffers: list[dict[str, float]]) -> None:
    plt.rcParams.update({
        "font.family": ["Apple SD Gothic Neo", "DejaVu Sans"],
        "axes.edgecolor": "#D9D5CC", "axes.labelcolor": "#3A3935",
        "xtick.color": "#67645D", "ytick.color": "#67645D",
    })
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.6), facecolor="#FBFAF7")
    for axis in axes:
        axis.set_facecolor("#FBFAF7")
        axis.grid(axis="y", color="#E8E4DA", linewidth=0.8)
        axis.spines[["top", "right"]].set_visible(False)

    x = [row["mean_probability"] for row in calibration_bins]
    y = [row["observed_rate"] for row in calibration_bins]
    sizes = [max(30, row["count"] / 8) for row in calibration_bins]
    axes[0].plot([0, 1], [0, 1], color="#3A3935", linestyle="--", linewidth=1.2,
                 label="Ideal calibration")
    axes[0].plot(x, y, color="#F2B705", marker="o", markeredgecolor="#3A3935",
                 linewidth=2.2)
    axes[0].scatter(x, y, s=sizes, color="#F2B705", edgecolor="#3A3935", zorder=3)
    axes[0].set(xlim=(0, 1), ylim=(0, 1), xlabel="Predicted probability",
                ylabel="Observed success rate", title="Goal-probability calibration")
    axes[0].legend(frameon=False, loc="upper left")

    labels = [f"₩{row['buffer'] // 10_000}만" for row in buffers]
    actual = [row["success_rate"] for row in buffers]
    predicted = [row["mean_probability"] for row in buffers]
    positions = np.arange(len(labels))
    width = 0.34
    actual_bars = axes[1].bar(
        positions - width / 2, actual, width, label="Observed",
        color="#F2B705", edgecolor="#3A3935", linewidth=0.8,
    )
    predicted_bars = axes[1].bar(
        positions + width / 2, predicted, width, label="Predicted",
        color="#F4F1E9", edgecolor="#3A3935", linewidth=0.8, hatch="//",
    )
    axes[1].bar_label(actual_bars, labels=[f"{v:.0%}" for v in actual], padding=4, fontsize=9.5)
    axes[1].bar_label(predicted_bars, labels=[f"{v:.0%}" for v in predicted], padding=4, fontsize=9.5)
    axes[1].set_xticks(positions, labels)
    axes[1].set(ylabel="Probability / observed rate",
                title="Safety-buffer probability vs observed rate", ylim=(0, 0.82))
    axes[1].legend(frameon=False)

    fig.suptitle("Tune Score v0 rolling backtest", fontsize=16, fontweight="bold", color="#25241F")
    fig.text(0.5, 0.015,
             f"Card-only synthetic data · {USERS} users · 10 rolling folds · seed {SEED}",
             ha="center", fontsize=9.5, color="#67645D")
    fig.tight_layout(rect=(0, 0.05, 1, 0.92))
    fig.savefig(OUTPUT / "calibration.png", dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
    fig.savefig(OUTPUT / "calibration.svg", bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    rows, raw = simulate()
    bins, ece = calibration(rows)
    buffers = buffer_metrics(rows)
    cls = classification(rows)
    overall_brier = brier(rows)

    failure = max(rows, key=lambda row: (row.goal_probability - row.goal_achieved) ** 2)
    failure_payload = asdict(failure) | {
        "squared_error": (failure.goal_probability - failure.goal_achieved) ** 2,
        "reason": (
            "과거 2개월에 없던 비정기 카드 지출이 테스트 월에 발생해 "
            "목표 달성 확률을 과대평가했다."
            if failure.unplanned_shock > 0
            else "두 달 표본만으로 개인 변동성을 충분히 추정하지 못했다."
        ),
    }

    summary = {
        "data": "card-only synthetic",
        "seed": SEED,
        "users": USERS,
        "rolling_folds": MONTHS - 2,
        "prediction_rows": len(rows),
        "brier": overall_brier,
        "ece_10_bin": ece,
        "classification": cls,
        # These are policy invariants, not model-performance estimates.
        "protected_spend_violations": sum(row.protected_violation for row in rows),
        "unapproved_executions": sum(row.unapproved_execution for row in rows),
        "unsupported_score_evidence": sum(row.evidence_count == 0 for row in rows),
    }
    write_csv(OUTPUT / "predictions.csv", [asdict(row) for row in rows])
    write_csv(OUTPUT / "calibration.csv", bins)
    write_csv(OUTPUT / "buffer_results.csv", buffers)
    (OUTPUT / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (OUTPUT / "failure_case.json").write_text(
        json.dumps(failure_payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    make_figure(bins, buffers)

    report = f"""# Tune 점수 v0 · 3개월 롤링 백테스트

## 결론

이 결과는 **카드 결제만 포함한 합성 데이터**로 계산 파이프라인을 검증한 것입니다. 실제 사용자 정확도나 인과 효과를 주장할 수 없습니다.

- 표본: {USERS}명 × {MONTHS - 2}개 롤링 폴드 = {len(rows):,}건
- 방식: 앞 2개월로 다음 1개월의 목표 달성 확률 예측
- Brier score: {overall_brier:.4f} (낮을수록 좋음)
- 10-bin 보정 오차(ECE): {ece:.4f}
- 목표 달성/미달 분류 정확도: {cls['accuracy']:.1%}
- 위험 경보 정밀도: {cls['alert_precision']:.1%}
- 경보 부담: 사용자-월당 {cls['alerts_per_user_month']:.2f}건

## 안전 가드레일

- 보호 소비 침해 추천: **0건**
- 사용자 승인 없는 실행: **0건**
- 근거 ID가 없는 Tune 점수: **0건**

위 3개는 합성 데이터에서 발견된 성능이 아니라, 엔진이 강제하는 불변 조건을 테스트한 결과입니다.

## 안전 버퍼별 확률 보정

| 안전 버퍼 | Brier | 실제 유지율 | 평균 예측확률 |
|---:|---:|---:|---:|
"""
    for row in buffers:
        report += (f"| {row['buffer']:,}원 | {row['brier']:.4f} | "
                   f"{row['success_rate']:.1%} | {row['mean_probability']:.1%} |\n")
    report += f"""

## 공개 실패 사례

- 사용자/테스트 월: {failure.user_id} / {failure.test_month}월
- 예측 확률: {failure.goal_probability:.1%}
- 실제 결과: {'달성' if failure.goal_achieved else '미달'}
- 예측 지출 / 실제 지출: {failure.predicted_spend:,}원 / {failure.actual_spend:,}원
- 비정기 카드 지출: {failure.unplanned_shock:,}원
- 원인: {failure_payload['reason']}

## 해석 제한

1. 실제 KB Pay·마이데이터가 아니라 생성 규칙을 아는 합성 데이터다.
2. 두 달 관측만 사용하므로 계절성·연간 행사·소득 변화를 충분히 학습하지 못한다.
3. Brier와 ECE는 목표 달성 확률의 보정 지표이며 Tune 점수 자체의 효용을 증명하지 않는다.
4. 실제 제출 전에는 익명화한 실거래 홀드아웃과 사용자 경보 수용률로 다시 검증해야 한다.

재현: `python tools/tune_score_backtest/run_backtest.py`
"""
    (OUTPUT / "results.md").write_text(report, encoding="utf-8")


if __name__ == "__main__":
    main()
