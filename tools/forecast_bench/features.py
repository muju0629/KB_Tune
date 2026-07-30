"""월별 패널 → 설계행렬.

direct forecasting. 타깃 월 직전 LAGS 개월로 피처를 만든다.
학습은 201811 을 타깃으로, 테스트는 201812 를 타깃으로 각각 구성해서
학습이 테스트 시점 이후를 보지 못하게 한다. 랜덤 분할은 쓰지 않는다.

    학습:  201807~201810 → 201811
    테스트: 201808~201811 → 201812
"""
from __future__ import annotations

import zlib

import numpy as np
import pandas as pd

LAGS = 4
LAST_MONTH_COLS = {
    "이용후경과월_신용": "recency",
    "이용금액_신용_R3M": "amt_r3m_credit",
    "이용금액_체크_R3M": "amt_r3m_check",
    "이용금액_신용_R6M": "amt_r6m_credit",
    "이용금액_체크_R6M": "amt_r6m_check",
    "이용가맹점수": "n_merchants",
    "이용금액_온라인_B0M": "amt_online",
    "이용금액_오프라인_B0M": "amt_offline",
    "_1순위업종": "top_industry",
}


def clip_spending(df: pd.DataFrame) -> pd.DataFrame:
    """순환불 달(amount < 0, 전체의 4.0%)을 0원으로 본다.

    취소·환불이 승인을 초과한 달이다. 앱이 모델링하는 대상은 지출이고
    `weekly_available`·`probability` 모두 0원 이상만 다룬다. 예측값도 이미
    0에서 클리핑하므로 타깃 공간을 맞춘다. log1p 가 음수에서 NaN 을 내는 문제도
    여기서 사라진다 — LightGBM 은 NaN 을 삼켜서 조용히 돌지만 선형회귀·XGBoost 는
    터진다.
    """
    out = df.copy()
    out["amount"] = out["amount"].clip(lower=0)
    return out


def _panel(df: pd.DataFrame) -> tuple[pd.DataFrame, list[int]]:
    months = sorted(df.ym.unique())
    wide = df.pivot(index="user_id", columns="ym", values="amount")
    cnt = df.pivot(index="user_id", columns="ym", values="tx_count")
    wide.columns = [f"amt_{m}" for m in wide.columns]
    cnt.columns = [f"cnt_{m}" for m in cnt.columns]
    return wide.join(cnt), months


def _one_split(df: pd.DataFrame, wide: pd.DataFrame, months: list[int],
               target_ym: int) -> tuple[pd.DataFrame, pd.Series]:
    lag_months = [m for m in months if m < target_ym][-LAGS:]
    if len(lag_months) < LAGS:
        raise ValueError(f"{target_ym} 앞에 {LAGS}개월이 없다: {lag_months}")

    amt = wide[[f"amt_{m}" for m in lag_months]].to_numpy(float)
    cnt = wide[[f"cnt_{m}" for m in lag_months]].to_numpy(float)

    X = pd.DataFrame(index=wide.index)
    for i in range(LAGS):                      # lag1 = 가장 최근
        X[f"lag{i + 1}"] = amt[:, LAGS - 1 - i]
        X[f"cnt_lag{i + 1}"] = cnt[:, LAGS - 1 - i]
    X["mean"] = amt.mean(1)
    X["median"] = np.median(amt, 1)
    X["std"] = amt.std(1)
    X["min"] = amt.min(1)
    X["max"] = amt.max(1)
    X["trend"] = amt[:, -1] - amt[:, 0]
    X["zero_ratio"] = (amt == 0).mean(1)
    X["cnt_mean"] = cnt.mean(1)

    # 시점 의존 컬럼은 lag 구간의 마지막 달 값만 쓴다 (그 이후를 보면 누출)
    last = df[df.ym == lag_months[-1]].set_index("user_id")
    for src, dst in LAST_MONTH_COLS.items():
        col = last[src].reindex(X.index)
        X[dst] = col.astype("category").cat.codes if col.dtype == object else col

    y = df[df.ym == target_ym].set_index("user_id")["amount"].reindex(X.index)
    keep = y.notna() & X.notna().all(axis=1)
    return X[keep], y[keep]


def build(df: pd.DataFrame) -> dict:
    """(X_tr, y_tr, X_te, y_te, lag_amounts_te) 를 담은 dict."""
    wide, months = _panel(df)
    train_ym, test_ym = months[-2], months[-1]

    X_tr, y_tr = _one_split(df, wide, months, train_ym)
    X_te, y_te = _one_split(df, wide, months, test_ym)

    # 콜드스타트·shrinkage 용 사용자 홀드아웃 20%.
    # 회원번호를 그대로 나누면 안 된다 — 체계추출한 번호가 전부 STRIDE 의 배수라
    # 나머지가 한쪽으로 쏠린다. crc32 는 stride 와 무관하고 실행 간에도 안정적이다.
    def holdout(idx: pd.Index) -> np.ndarray:
        return np.array([zlib.crc32(u.encode()) % 5 == 0 for u in idx])

    return {
        "X_tr": X_tr, "y_tr": y_tr, "X_te": X_te, "y_te": y_te,
        "train_ym": train_ym, "test_ym": test_ym,
        "lag_cols": [f"lag{i + 1}" for i in range(LAGS)],
        "holdout_te": holdout(X_te.index),
        "holdout_tr": holdout(X_tr.index),
    }


if __name__ == "__main__":
    from pathlib import Path

    d = build(pd.read_parquet(Path(__file__).parent / "data/monthly.parquet"))
    print(f"학습 {d['X_tr'].shape} → {d['train_ym']}   테스트 {d['X_te'].shape} → {d['test_ym']}")
    print(f"피처 {list(d['X_tr'].columns)}")
    print(f"홀드아웃 사용자 {d['holdout_te'].mean():.0%}")
