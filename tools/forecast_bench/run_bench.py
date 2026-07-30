"""벤치마크 오케스트레이터.

AI Hub 월별 축에서 전 모델을 돌리고 results.csv / results.md 를 낸다.

    python run_bench.py            # Chronos 포함
    python run_bench.py --fast     # Chronos 제외 (모델 로드 5분을 건너뛴다)
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

import features
import metrics
import models

HERE = Path(__file__).parent
TARGET_COVERAGE = 0.8

# estimate.py 의 CLAMP_MULTIPLIER. 개인 관측 최대치의 2.5배를 넘는 추정을 자른다.
# 앱이 이미 쓰는 안전장치라 전 모델에 똑같이 걸어야 공정한 비교가 된다.
# 없으면 log 타깃 선형회귀가 expm1 증폭으로 실제 최대의 50배를 뱉는다.
CLAMP_MULTIPLIER = 2.5


def clamp(pred: dict, d: dict) -> dict:
    """estimate.py 와 같은 규칙 — 관측 최대치가 0인 사용자에게는 걸지 않는다."""
    hi = d["X_te"][d["lag_cols"]].to_numpy(float).max(1)
    ceiling = np.where(hi > 0, hi * CLAMP_MULTIPLIER, np.inf)
    return {a: np.minimum(q, ceiling) for a, q in pred.items()}


def evaluate(name: str, pred: dict, y: np.ndarray, y_train: np.ndarray,
             lag1: np.ndarray, secs: float) -> dict:
    # 변화량 WAPE — 수준(level)을 제거하고 "다음 달 변화"만 맞히는 능력을 본다.
    # 총액 WAPE 는 직전 달이 R²=0.96 을 설명하는 이 데이터에서 모델을 구분하지
    # 못한다. 1.0 이 naive(변화 0으로 예측)와 동등, 1.0 초과는 naive 보다 나쁨.
    return {
        "모델": name,
        "WAPE": metrics.wape(y, pred[0.5]),
        "MASE": metrics.mase(y, pred[0.5], y_train),
        "WQL": metrics.wql(y, pred),
        "커버리지80": metrics.coverage(y, pred[0.1], pred[0.9]),
        "변화WAPE": metrics.wape(y - lag1, pred[0.5] - lag1),
        "구간폭_중앙": float(np.median(pred[0.9] - pred[0.1])),
        "초": round(secs, 1),
    }


def main() -> None:
    fast = "--fast" in sys.argv
    raw = features.clip_spending(pd.read_parquet(HERE / "data/monthly.parquet"))
    d = features.build(raw)
    y = d["y_te"].to_numpy(float)
    y_train = d["y_tr"].to_numpy(float)
    lag1 = d["X_te"]["lag1"].to_numpy(float)

    print(f"학습 {d['X_tr'].shape} → {d['train_ym']} · 테스트 {d['X_te'].shape} → {d['test_ym']}")
    print(f"타깃 0원 비율 {(y == 0).mean():.1%} · 중앙값 {np.median(y):,.0f}원\n")

    runs = list(models.REGISTRY)
    if not fast:
        runs.append(("R8  Chronos-2 zero-shot (MPS)",
                     lambda dd: models.chronos2(dd, raw)))

    rows = []
    for name, fn in runs:
        t0 = time.time()
        try:
            pred = clamp(fn(d), d)
        except Exception as e:
            print(f"  {name:34s} 실패: {type(e).__name__}: {e}")
            continue
        row = evaluate(name, pred, y, y_train, lag1, time.time() - t0)
        rows.append(row)
        print(f"  {name:34s} WAPE {row['WAPE']:.4f}  MASE {row['MASE']:.3f}  "
              f"WQL {row['WQL']:.4f}  커버리지 {row['커버리지80']:.1%}  "
              f"변화 {row['변화WAPE']:.3f}  {row['초']}s")

    res = pd.DataFrame(rows)
    base = res.loc[res["모델"].str.startswith("R0"), "WAPE"]
    if len(base):
        res["R0대비"] = (base.iloc[0] - res["WAPE"]) / base.iloc[0]

    out = HERE / "results"
    out.mkdir(exist_ok=True)
    res.to_csv(out / "results.csv", index=False)
    write_md(res, d, y, out / "results.md")
    print(f"\n{out/'results.csv'}\n{out/'results.md'}")


def write_md(res: pd.DataFrame, d: dict, y: np.ndarray, path: Path) -> None:
    best = res.loc[res.WAPE.idxmin()]
    r0 = res[res["모델"].str.startswith("R0")].iloc[0]
    cov = res.assign(err=(res["커버리지80"] - TARGET_COVERAGE).abs()).sort_values("err").iloc[0]

    tbl = res.copy()
    tbl["WAPE"] = tbl.WAPE.map("{:.4f}".format)
    tbl["MASE"] = tbl.MASE.map("{:.3f}".format)
    tbl["WQL"] = tbl.WQL.map("{:.4f}".format)
    tbl["커버리지80"] = tbl["커버리지80"].map("{:.1%}".format)
    tbl["변화WAPE"] = tbl["변화WAPE"].map("{:.3f}".format)
    tbl["구간폭_중앙"] = tbl["구간폭_중앙"].map("{:,.0f}".format)
    if "R0대비" in tbl:
        tbl["R0대비"] = tbl["R0대비"].map("{:+.1%}".format)

    path.write_text(f"""# 소비 예측 모델 벤치마크 — AI Hub 월별 축

## 설정

- 데이터: AI Hub 117 금융합성데이터 `03.카드 승인매출정보`, 300만 명 중 체계추출 5,000명
- 타깃: 회원별 당월 카드 이용금액 (`이용금액_신용_B0M + 이용금액_체크_B0M`)
- 분할: **시간 순.** 학습 {d['train_ym']}, 테스트 {d['test_ym']}. 각각 직전 4개월로 피처 구성
- 타깃 0원 비율 {(y == 0).mean():.1%} · 중앙값 {np.median(y):,.0f}원

### 데이터 처리 두 가지 (둘 다 결과에 영향을 준다)

1. **순환불 달을 0원으로 클리핑했다.** 원본의 4.0%(1,195행·407명)가 음수다 —
   취소·환불이 승인을 초과한 달이다. 앱이 모델링하는 대상은 지출이고 예측값도
   0에서 자르므로 타깃 공간을 맞췄다. 이 처리로 0원 비율이 21.7% → {(y == 0).mean():.1%}로 올랐다
2. **전 모델에 `estimate.py` 의 `CLAMP_MULTIPLIER = 2.5`를 걸었다.** 개인 관측
   최대치의 2.5배에서 자른다. 앱이 이미 쓰는 안전장치를 한 모델만 빼면 비교가
   공정하지 않다. 트리 모델에는 거의 걸리지 않고, log 타깃 선형회귀에만 크게
   작용한다 (WAPE 0.95 → 0.60)

## 결과

{tbl.to_markdown(index=False)}

- **WAPE** 가중절대오차율 (낮을수록 좋음). MAPE 는 소액에서 발산하므로 쓰지 않았다
- **MASE** 1보다 크면 직전 달 그대로 쓰는 것보다 못한 것
- **WQL** 분위 기반 CRPS 근사. α=0.1/0.5/0.9 는 거친 근사라 절대값보다 모델 간 비교용
- **커버리지80** 80% 구간이 실제값을 덮은 비율. {TARGET_COVERAGE:.0%}에 가까울수록 정직하다

## 해석

- 최저 WAPE: **{best['모델']}** ({best['WAPE']:.4f}), R0 대비 {(r0.WAPE - best.WAPE) / r0.WAPE:+.1%}
- 커버리지가 80%에 가장 가까운 모델: **{cov['모델']}** ({cov['커버리지80']:.1%})

## 한계

1. **AI Hub 데이터 자체가 합성이다.** 실사용자 소비 패턴이 아니다
2. **월 단위다.** 앱 화면의 주지표는 주간 총 지출인데, 이 데이터는 최소 단위가
   월이라 주간 축을 복원할 수 없다. 12개 zip 전부 회원×월 집계 패널이고
   거래 단위 레코드가 없다
3. **일정 단건 금액(T2)은 이 데이터로 평가할 수 없다.** 거래 단건 금액이 없고
   있는 것은 월 합계와 건수뿐이라 분위 회귀의 타깃이 존재하지 않는다
4. **R0 은 앱의 예측 모델이 아니다.** 앱에는 시계열 예측이 없다.
   `estimate.py` 는 일정 단건 추정이고 `budget.py::weekly_available` 은
   남은예산÷남은주수 배분 산수다. 여기서 R0 은 그 추정 구조(개인 이력 산술평균,
   관측 min~max 구간)를 월 축으로 이식한 것이다
5. **문맥 4개월.** Chronos-2 는 최대 8192 문맥을 쓸 수 있는데 여기서는 4점뿐이다.
   사전학습 모델에 불리한 조건이고, 이 표의 Chronos 수치를 "상한선"으로
   읽으면 안 된다
6. 2018년 하반기 데이터다. 현재 물가 수준과 다르다

## 재현

```sh
/opt/anaconda3/envs/pt_env/bin/python load_aihub.py     # zip 스트림 → parquet (~20분)
/opt/anaconda3/envs/pt_env/bin/python metrics.py        # 지표 단위 검증
/opt/anaconda3/envs/pt_env/bin/python run_bench.py      # 전 모델 (Chronos 포함)
```
""", encoding="utf-8")


if __name__ == "__main__":
    main()
