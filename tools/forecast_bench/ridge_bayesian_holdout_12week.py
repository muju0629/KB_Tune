"""Ridge + Bayesian 개인화의 신규 개발/홀드아웃 12주 검증.

단순 거래 단위 합성 실험과 달리 KB Tune의 주간 카테고리 금액·발생 예측,
질문하지 않은 카테고리 평가, 다음 주부터의 상태 갱신 규칙을 그대로 사용한다.
"""
from pathlib import Path

import pandas as pd

import persistent_defaults_holdout_12week as core


HERE = Path(__file__).parent
OUT = HERE / "results/ridge_bayesian_holdout_12week"
DEV_SEEDS = [20261011, 20261012, 20261013]
HOLDOUTS = [
    {"scenario": "기본", "seed": 20261021},
    {
        "scenario": "피드백 잡음",
        "seed": 20261022,
        "response_rate": 0.70,
        "intent_accuracy": 0.85,
        "amount_log_error": 0.20,
    },
    {"scenario": "약한 생활변화", "seed": 20261023, "lifestyle_scale": 0.55},
]


def build_report(selected, leaderboard, summary, intervals, checkpoints):
    ci8 = intervals[intervals.사용주차 == 8].iloc[0]
    ci12 = intervals[intervals.사용주차 == 12].iloc[0]
    dev_winners = int((leaderboard.improvement_vs_immediate > 0).sum())
    generalizes = bool(ci8.CI_low > 0 and ci12.CI_low > 0 and dev_winners > 0)
    decision = "승격 후보" if generalizes else "배포 보류"
    return f"""# Ridge + Bayesian 개인화 · 신규 홀드아웃 12주 검증

## 결론

- 판정: **{decision}**
- 개발 시드에서 Ridge 즉시 보정보다 나은 Bayesian 후보: **{dev_winners}/{len(leaderboard)}개**
- 선택 후보: **{selected.name}**
- 8주 추가 개선폭: **{ci8.improvement*100:.2f}%p** (95% CI {ci8.CI_low*100:.2f}~{ci8.CI_high*100:.2f}%p)
- 12주 추가 개선폭: **{ci12.improvement*100:.2f}%p** (95% CI {ci12.CI_low*100:.2f}~{ci12.CI_high*100:.2f}%p)

`추가 개선폭`은 같은 주 질문 카테고리를 제외한 뒤 `Ridge 즉시 보정 WAPE - Ridge + Bayesian WAPE`로 계산했다. 양수일수록 Bayesian 누적 상태가 더 정확하다.

## 개발 후보 비교

{leaderboard.to_markdown(index=False, floatfmt='.4f')}

## 최종 홀드아웃 8주·12주

{summary[summary.사용주차.isin([8, 12])].to_markdown(index=False, floatfmt='.4f')}

## 시나리오별 개선폭

{checkpoints.to_markdown(index=False, floatfmt='.4f')}

## 과적합·누수 방지

1. 앞선 LightGBM 홀드아웃과 겹치지 않는 개발 300명·최종 300명을 새로 생성했다.
2. 개발 시드에서 고정된 Bayesian 후보 7개만 비교하고 최종 시드는 한 번만 평가했다.
3. 해당 주의 모든 예측을 끝낸 뒤에만 피드백 상태를 갱신했다.
4. 해당 주 질문 카테고리는 주지표에서 제외했다.
5. 기본·피드백 잡음·약한 생활변화 조건과 8주·12주를 모두 보고했다.
6. 사용자 단위 bootstrap 95% 신뢰구간 하한이 0보다 클 때만 일반화로 인정했다.

## 해석 제한

- 같은 합성 생성기 계열이므로 실제 사용자 일반화를 증명하지 않는다.
- Ridge의 기존 고정 설정(Logistic C=0.7, amount alpha=20)을 사용했다. Ridge 하이퍼파라미터 탐색 결과가 아니다.
- Bayesian 후보가 통과하더라도 실제 12주 shadow-mode 파일럿 전에는 제품 기본 모델로 자동 승격하지 않는다.
"""


def main():
    dev = pd.concat([
        core.run_seed(seed, {"scenario": "개발"}, core.CANDIDATES,
                      global_model_name="Ridge")
        for seed in DEV_SEEDS
    ], ignore_index=True)
    selected, leaderboard = core.select_candidate(dev)
    print(f"선택 후보: {selected}", flush=True)

    final = pd.concat([
        core.run_seed(item["seed"], item, [selected], global_model_name="Ridge")
        for item in HOLDOUTS
    ], ignore_index=True)
    summary = core.summarize_final(final, selected)
    intervals = pd.DataFrame([
        dict(zip(
            ["사용주차", "improvement", "CI_low", "CI_high"],
            [week, *core.bootstrap_final(final, selected, week)],
        ))
        for week in range(1, core.APP_WEEKS + 1)
    ])
    checkpoints = core.scenario_checkpoints(summary)

    OUT.mkdir(parents=True, exist_ok=True)
    dev.to_csv(OUT / "development_predictions.csv", index=False)
    final.to_csv(OUT / "holdout_predictions.csv", index=False)
    leaderboard.to_csv(OUT / "development_leaderboard.csv", index=False)
    summary.to_csv(OUT / "holdout_summary.csv", index=False)
    intervals.to_csv(OUT / "holdout_bootstrap_intervals.csv", index=False)
    checkpoints.to_csv(OUT / "scenario_checkpoints.csv", index=False)
    (OUT / "results.md").write_text(
        build_report(selected, leaderboard, summary, intervals, checkpoints),
        encoding="utf-8",
    )
    core.OUT = OUT
    core.make_figures(summary, intervals, checkpoints)
    print((OUT / "results.md").resolve())


if __name__ == "__main__":
    main()
