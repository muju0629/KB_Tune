"""인구 사전분포 무게 스윕 — Bayesian 갈래가 핸디캡을 달고 뛰었는지 확인한다.

`model_comparison_8week` 은 `strength_days=28` 로 "순수 renewal Bayesian 이 더
정확하다는 주장을 기각한다" 는 결론을 냈다. 그런데 `coldstart.py` 스윕에서 무게 30 이
무게 5 대비 26주차 WAPE 를 7.3% 악화시키는 것으로 측정됐다. LightGBM 과의 격차가
9.1% 라서 **같은 자리수**다 — 결론이 설정 하나에 매달려 있다.

여기서는 Bayesian 갈래만 다시 돈다. LightGBM·Ridge·RF 는 사전분포를 쓰지 않으므로
값이 바뀌지 않는다. 재학습은 낭비다.

    python sweep_prior_strength.py
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

from card_calendar_bench import (
    FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE, N_WEEKS,
    fit_priors, generate, run,
)
from metrics import wape
from model_comparison_8week import build_rows, indexes, population_amounts

HERE = Path(__file__).parent
OUT = HERE / "results/model_comparison_8week"

STRENGTHS = (3.0, 5.0, 10.0, 20.0, 28.0)
WEEKS = (1, 4, 8)

# model_comparison_8week/results.csv 의 LightGBM 값. 사전분포와 무관해 재계산하지 않는다.
LGBM = {1: 0.3886, 4: 0.3873, 8: 0.3798}


def bayesian_wape(tx, calendar, priors, idx, pop_amount, history_weeks: int) -> float:
    """`model_comparison_8week` 과 같은 방식으로 Bayesian 갈래의 WAPE 를 낸다."""
    _X, y_test, _people, _weeks = build_rows(
        range(N_PRIOR_PEOPLE, N_PEOPLE), range(FIRST_TEST_WEEK, N_WEEKS),
        history_weeks, idx, pop_amount,
    )
    pred, _ = run(tx, calendar, priors, lookback_weeks=history_weeks, n_draws=120)
    kb = (pred[pred.model == "R2 + 캘린더"]
          .sort_values(["person", "week"]).p50.to_numpy(float))
    assert len(kb) == len(y_test), f"정렬 불일치 {len(kb)} vs {len(y_test)}"
    return float(wape(y_test, kb))


def main() -> None:
    tx, calendar = generate()
    idx = indexes(tx, calendar)
    pop_amount = population_amounts(tx)

    rows = []
    for s in STRENGTHS:
        priors = fit_priors(tx, strength_days=s)
        for w in WEEKS:
            rows.append({"무게": s, "사용주차": w,
                         "WAPE": bayesian_wape(tx, calendar, priors, idx, pop_amount, w)})
        print(f"무게 {s:.0f} 완료", flush=True)

    df = pd.DataFrame(rows)
    piv = df.pivot(index="무게", columns="사용주차", values="WAPE")
    OUT.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT / "prior_strength_sweep.csv", index=False)

    print("\n=== Bayesian 갈래 WAPE (사전분포 무게 × 사용주차) ===")
    head = "".join(f"{w:>10}주차" for w in WEEKS)
    print(f"  {'무게(일)':>9}{head}   {'8주차 LightGBM 대비':>20}")
    print("  " + "-" * (9 + 12 * len(WEEKS) + 23))
    for s in piv.index:
        line = "".join(f"{piv.loc[s, w]:>12.4f}" for w in WEEKS)
        vs = (piv.loc[s, 8] - LGBM[8]) / LGBM[8]
        mark = "  ← 현재" if s == 28.0 else ""
        print(f"  {s:>9.0f}{line}   {vs:>+19.1%}{mark}")
    print(f"  {'LightGBM':>9}" + "".join(f"{LGBM[w]:>12.4f}" for w in WEEKS))

    best = piv[8].idxmin()
    print(f"\n  8주차 최적 무게 {best:.0f}일 · WAPE {piv.loc[best, 8]:.4f}")
    print(f"  현재(28일) {piv.loc[28.0, 8]:.4f} → 개선 "
          f"{(piv.loc[28.0, 8] - piv.loc[best, 8]) / piv.loc[28.0, 8]:.1%}")
    gap_now = (piv.loc[28.0, 8] - LGBM[8]) / LGBM[8]
    gap_best = (piv.loc[best, 8] - LGBM[8]) / LGBM[8]
    print(f"  LightGBM 격차 {gap_now:+.1%} → {gap_best:+.1%}")
    if piv.loc[best, 8] < LGBM[8]:
        print("  → 결론 뒤집힘. Bayesian 기각을 철회해야 한다.")
    else:
        print("  → 결론 유지. 격차가 줄어도 LightGBM 이 이긴다.")


if __name__ == "__main__":
    main()
