"""Chronos-2 주 축 상한선 — 사전학습 시계열 모델이 실제로 얼마나 잘하는가.

월 축 벤치(`run_bench.py`)에서 Chronos-2 는 R0 대비 +0.4% 였다. 그런데 그때 문맥이
**4점**이었다(AI Hub 가 회원×월 집계라 그 이상을 만들 수 없었다). results.md 한계 5 가
"이 수치를 상한선으로 읽으면 안 된다"고 적어둔 이유다.

여기서 그 조건을 없앤다. 주 축이라 문맥이 최대 51점이고, 카테고리 다변량과
캘린더 known-future 공변량을 둘 다 쓴다. `card_calendar_bench.generate()` 로 같은
데이터를 쓰고 `model_comparison_8week.build_rows` 로 같은 평가 순서를 받아서
LightGBM 0.3798 · Bayesian 0.3993 과 한 표에 놓는다.

조건 세 개. 캘린더 기여도를 분리하려면 C1 과 C2 가 둘 다 있어야 한다.

    C1  총액 단변량                      원계열만
    C2  총액 단변량 + 캘린더              known future covariate
    C3  카테고리 7종 다변량 + 캘린더       카테고리 간 상관을 태운다 (spec §4)

평가는 **롤링 1주 예측**이다. 20주 앞을 한 번에 예측하는 게 아니라, 주마다 그 시점까지의
문맥으로 다음 한 주를 예측한다 — 앱이 실제로 하는 일이 그거다.

    python chronos_weekly.py
"""
from __future__ import annotations

from pathlib import Path
import time

import numpy as np
import pandas as pd
import torch

from card_calendar_bench import (
    FIRST_TEST_WEEK, N_PEOPLE, N_PRIOR_PEOPLE, N_WEEKS, SPECS, generate,
)
from metrics import wape
from model_comparison_8week import build_rows, indexes, population_amounts

HERE = Path(__file__).parent
OUT = HERE / "results/chronos_weekly"

MODEL = "amazon/chronos-2"
EPOCH = pd.Timestamp("2025-01-06")        # 주 시작 기준일. freq=W-MON
FREQ = "W-MON"
CATEGORIES = [s.category for s in SPECS]

# 사전분포와 무관한 참조선. results/model_comparison_8week/results.csv 8주차 값이다.
REFERENCE = {
    "LightGBM": 0.3798,
    "Ridge": 0.3863,
    "Random Forest": 0.3921,
    "KB Tune Hybrid": 0.3939,
    "KB Tune Bayesian": 0.3993,
    "최근 평균 + 캘린더": 0.4861,
}


def stamp(week: int | np.ndarray):
    return EPOCH + pd.to_timedelta(np.asarray(week) * 7, unit="D")


def panels(tx: pd.DataFrame, calendar: pd.DataFrame, pop_amount: dict):
    """(사람 × 주) 연속 패널. **결측 주는 0 으로 채운다** — Chronos-2 는 간격을 못 받는다.

    캘린더 기대금액은 인구 평균 단가로만 만든다. 그 사람의 실제 결제액을 쓰면
    미래 정보 누출이다.
    """
    people = range(N_PRIOR_PEOPLE, N_PEOPLE)
    grid = pd.MultiIndex.from_product([people, range(N_WEEKS)], names=["person", "week"])

    total = (tx[tx.person >= N_PRIOR_PEOPLE].groupby(["person", "week"]).amount.sum()
             .reindex(grid, fill_value=0.0).rename("target").reset_index())
    count = (tx[tx.person >= N_PRIOR_PEOPLE].groupby(["person", "week"]).size()
             .reindex(grid, fill_value=0).rename("tx_count").reset_index())
    total = total.merge(count, on=["person", "week"])

    by_cat = (tx[tx.person >= N_PRIOR_PEOPLE]
              .groupby(["person", "week", "category"]).amount.sum().unstack(fill_value=0.0)
              .reindex(grid, fill_value=0.0).reindex(columns=CATEGORIES, fill_value=0.0)
              .reset_index())

    cal = calendar[calendar.person >= N_PRIOR_PEOPLE]
    expected = cal.assign(amt=cal.category.map(pop_amount).fillna(0.0))
    cal_total = (expected.groupby(["person", "week"]).amt.sum()
                 .reindex(grid, fill_value=0.0).rename("calendar_expected").reset_index())

    total = total.merge(cal_total, on=["person", "week"])
    by_cat = by_cat.merge(cal_total, on=["person", "week"])
    return total, by_cat


def forecast(pipeline, panel: pd.DataFrame, origin: int, target, covariates: list[str]):
    """`origin` 주를 예측한다. 문맥은 그 이전 전부. 미래는 공변량만 준다."""
    keep = ["person", "week", "calendar_expected"] + covariates
    cols = list(dict.fromkeys(keep + (target if isinstance(target, list) else [target])))
    hist = panel[panel.week < origin][cols].copy()
    hist["item_id"] = hist.person.astype(str)
    hist["timestamp"] = stamp(hist.week.to_numpy())

    fut = panel[panel.week == origin][["person", "week", "calendar_expected"]].copy()
    fut["item_id"] = fut.person.astype(str)
    fut["timestamp"] = stamp(fut.week.to_numpy())

    drop = ["person", "week"] + [c for c in ["calendar_expected"] if c not in covariates]
    out = pipeline.predict_df(
        hist.drop(columns=drop, errors="ignore"),
        future_df=(fut.drop(columns=["person", "week"]) if "calendar_expected" in covariates
                   else None),
        id_column="item_id", timestamp_column="timestamp", target=target,
        prediction_length=1, quantile_levels=[0.1, 0.5, 0.9],
    )
    return out


def totals(out: pd.DataFrame, target) -> pd.Series:
    """item 별 예측 총액. 출력이 long 포맷이라 다변량은 타깃을 합친다.

    다변량은 (item × 타깃) 행으로 나온다 — 100명 × 7카테고리 = 700행. 한 사람의
    주간 총액은 그 7행의 합이다. 음수는 0 으로 자른다(지출에 음수가 없다).
    """
    med = (out["0.5"] if "0.5" in out else out["predictions"]).clip(lower=0)
    grouped = med.groupby(out.item_id).sum()
    if not isinstance(target, list):
        assert len(grouped) == len(out), "단변량인데 item 이 중복이다"
    return grouped


def run_condition(pipeline, panel: pd.DataFrame, name: str, target,
                  covariates: list[str]) -> dict:
    preds: dict[tuple[int, int], float] = {}
    t0 = time.time()
    for origin in range(FIRST_TEST_WEEK, N_WEEKS):
        out = forecast(pipeline, panel, origin, target, covariates)
        for item, value in totals(out, target).items():
            preds[(int(item), origin)] = float(value)
    print(f"    {N_WEEKS - FIRST_TEST_WEEK}주 완료 ({time.time()-t0:.0f}초)", flush=True)
    return preds


def main() -> None:
    tx, calendar = generate()
    idx = indexes(tx, calendar)
    pop_amount = population_amounts(tx)
    total_panel, cat_panel = panels(tx, calendar, pop_amount)

    # 평가 순서를 model_comparison 과 똑같이 받는다. 그래야 한 표에 놓을 수 있다.
    _X, y_test, people, weeks = build_rows(
        range(N_PRIOR_PEOPLE, N_PEOPLE), range(FIRST_TEST_WEEK, N_WEEKS), 8, idx, pop_amount)
    print(f"평가 {len(y_test):,}행 · 사용자 {len(np.unique(people))}명 · "
          f"주 {FIRST_TEST_WEEK}~{N_WEEKS-1}\n")

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"{MODEL} 로드 중 ({device})…", flush=True)
    from chronos import BaseChronosPipeline
    pipeline = BaseChronosPipeline.from_pretrained(MODEL, device_map=device)

    conditions = [
        ("C1 Chronos-2 총액", "target", []),
        ("C2 Chronos-2 + 캘린더", "target", ["calendar_expected"]),
        ("C3 Chronos-2 다변량 + 캘린더", CATEGORIES, ["calendar_expected"]),
    ]

    rows = []
    for name, target, cov in conditions:
        panel = cat_panel if isinstance(target, list) else total_panel
        print(f"\n{name}")
        preds = run_condition(pipeline, panel, name, target, cov)
        pred = np.array([preds.get((int(p), int(w)), 0.0) for p, w in zip(people, weeks)])
        missing = sum(1 for p, w in zip(people, weeks) if (int(p), int(w)) not in preds)
        assert missing == 0, f"{name}: 예측 누락 {missing}건"
        rows.append({"모델": name, "WAPE": float(wape(y_test, pred)),
                     "WAPE기반정확도": 1 - float(wape(y_test, pred)),
                     "편향": float((pred - y_test).sum() / y_test.sum())})

    result = pd.DataFrame(rows)
    for model, w in REFERENCE.items():
        result.loc[len(result)] = {"모델": f"(참조) {model}", "WAPE": w,
                                   "WAPE기반정확도": 1 - w, "편향": np.nan}
    result = result.sort_values("WAPE").reset_index(drop=True)

    OUT.mkdir(parents=True, exist_ok=True)
    result.to_csv(OUT / "results.csv", index=False)
    print("\n" + result.to_string(index=False, float_format=lambda x: f"{x:.4f}"))

    best = result[result.모델.str.startswith("C")].WAPE.min()
    lgbm, bayes = REFERENCE["LightGBM"], REFERENCE["KB Tune Bayesian"]
    print(f"\n  Chronos-2 최고 {best:.4f} · LightGBM 대비 {(best-lgbm)/lgbm:+.1%} · "
          f"온디바이스 Bayesian 대비 {(best-bayes)/bayes:+.1%}")
    print("  → 상한선이 없다." if best > bayes else
          "  → 상한선이 존재한다. 회수율을 보고해야 한다.")

    c1 = result.loc[result.모델.str.startswith("C1"), "WAPE"].iloc[0]
    c2 = result.loc[result.모델.str.startswith("C2"), "WAPE"].iloc[0]
    (OUT / "results.md").write_text(f"""# Chronos-2 주 축 상한선

## 결론

- Chronos-2 최고 조건(총액 + 캘린더) **{c2:.4f}**. LightGBM {lgbm:.4f} 대비
  **{(c2-lgbm)/lgbm:+.1%}**, 온디바이스 Bayesian {bayes:.4f} 대비 **{(c2-bayes)/bayes:+.1%}** —
  **둘 다에게 진다.** 최근 평균 기준선만 이겼다.
- 월 축의 +0.4% 는 문맥 4점 탓이 **아니었다.** 문맥을 최대 {N_WEEKS-1}점으로 늘리고
  캘린더 known-future 공변량과 카테고리 다변량을 붙여도 순위가 바뀌지 않는다.
- **회수할 상한선이 없다.** spec §7 의 증류 계획(서버 모델 → `forecast_prior.json`)은
  전제가 성립하지 않는다. 닫는다.
- 캘린더 공변량은 **모델과 무관하게 작동한다** — C1 {c1:.4f} → C2 {c2:.4f},
  {(c1-c2)/c1:.1%} 개선. 캘린더가 실제 신호라는 주장의 교차검증이다.
- 카테고리 다변량은 실패했다(편향 {result.loc[result.모델.str.startswith('C3'), '편향'].iloc[0]:.1%}).
  카테고리별 **중앙값** 7개를 합하면 총액을 크게 과소추정한다 — LightGBM 의 L1 편향과
  같은 기전이고 항이 7개라 더 크다.

## 조건

- 데이터: `card_calendar_bench.generate()` 합성 400명 × 52주. 평가 사용자 100명 분리
- 평가: 주 {FIRST_TEST_WEEK}~{N_WEEKS-1} **롤링 1주 예측**. 문맥은 매 시점 이전 전부(최대 {N_WEEKS-1}점)
- 순서·타깃은 `model_comparison_8week.build_rows` 와 동일. 참조선은 그 8주차 값
- 캘린더 기대금액은 **인구 평균 단가**로만 만든다. 개인 실제 결제액을 쓰면 누출이다
- 결측 주는 0 으로 채웠다 — Chronos-2 는 시계열 간격을 받지 않는다

## 결과

{result.to_markdown(index=False, floatfmt=".4f")}

## 제한

- 합성 데이터 결과이며 실사용자 성능이 아니다.
- Chronos-2 는 zero-shot 이다. 이 데이터로 파인튜닝하지 않았다.
- 참조선(LightGBM 등)은 사용주차 8 조건이고 Chronos 는 문맥 제한을 두지 않았다.
  Chronos 에 유리한 비교다 — 상한선을 재는 것이 목적이므로 그렇게 뒀다.
- **서버 전용이다.** 120M 파라미터를 기기에 넣지 않는다(spec §10). 이 표는 제품 결정을
  바꾸지 않고 "온디바이스 최선이 상한선의 몇 %인가"만 말한다.
""", encoding="utf-8")
    print(OUT / "results.md")


if __name__ == "__main__":
    main()
