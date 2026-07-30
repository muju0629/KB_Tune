"""예측 평가 지표. MAPE 는 넣지 않았다 — 소액 거래에서 발산한다.

점 예측  WAPE, MASE
분위 예측 pinball, WQL(분위 기반 CRPS 근사)
구간     coverage
"""
from __future__ import annotations

import numpy as np


def wape(y: np.ndarray, pred: np.ndarray) -> float:
    """가중 절대오차율. 분모가 실제값 합이라 소액에서 발산하지 않는다."""
    y, pred = np.asarray(y, float), np.asarray(pred, float)
    denom = np.abs(y).sum()
    return float(np.abs(y - pred).sum() / denom) if denom else float("nan")


def mase(y: np.ndarray, pred: np.ndarray, y_train: np.ndarray, season: int = 1) -> float:
    """계절 naive 대비 MAE 비율. 1 보다 크면 naive 에게 진 것."""
    y, pred, y_train = np.asarray(y, float), np.asarray(pred, float), np.asarray(y_train, float)
    if len(y_train) <= season:
        return float("nan")
    scale = np.abs(y_train[season:] - y_train[:-season]).mean()
    return float(np.abs(y - pred).mean() / scale) if scale else float("nan")


def pinball(y: np.ndarray, q: np.ndarray, alpha: float) -> float:
    """분위 α 손실. α=0.5 면 MAE 의 절반."""
    y, q = np.asarray(y, float), np.asarray(q, float)
    d = y - q
    return float(np.maximum(alpha * d, (alpha - 1) * d).mean())


def wql(y: np.ndarray, quantiles: dict[float, np.ndarray]) -> float:
    """가중 분위 손실 — CRPS 의 분위 근사. Chronos 계열 벤치마크의 표준 지표.

    분위 수준이 [0,1] 을 촘촘히 덮을 때만 CRPS 에 수렴한다. α=0.1/0.5/0.9 는
    거친 근사라 절대값보다 모델 간 비교에 쓴다.
    """
    y = np.asarray(y, float)
    denom = np.abs(y).sum()
    if not denom:
        return float("nan")
    total = sum(pinball(y, q, a) * len(y) for a, q in quantiles.items())
    return float(2 * total / (len(quantiles) * denom))


def coverage(y: np.ndarray, lo: np.ndarray, hi: np.ndarray) -> float:
    """구간이 실제값을 덮은 비율. 80% 구간이면 0.8 에 가까워야 정직한 것."""
    y, lo, hi = np.asarray(y, float), np.asarray(lo, float), np.asarray(hi, float)
    return float(((y >= lo) & (y <= hi)).mean())


def _selfcheck() -> None:
    # WAPE: (10+20)/300
    assert abs(wape([100, 200], [110, 180]) - 0.1) < 1e-12

    # pinball α=0.5 는 MAE 의 절반
    assert abs(pinball([10], [8], 0.5) - 1.0) < 1e-12
    # 과소예측(y>q)일 때 α 가 크면 손실이 크다
    assert pinball([10], [8], 0.9) > pinball([10], [8], 0.1)

    # MASE: 학습 naive MAE=1, 테스트 MAE=1 → 1.0
    assert abs(mase([5], [6], [1, 2, 3, 4]) - 1.0) < 1e-12
    # 완벽 예측은 0
    assert mase([5], [5], [1, 2, 3, 4]) == 0.0

    # coverage: 3개 중 2개 포함
    assert abs(coverage([1, 2, 3], [0, 0, 0], [2, 2, 2]) - 2 / 3) < 1e-12

    # WQL: 완벽 예측이면 0
    perfect = {0.1: np.array([5.0]), 0.5: np.array([5.0]), 0.9: np.array([5.0])}
    assert wql([5.0], perfect) == 0.0
    # 빗나가면 커진다
    off = {0.1: np.array([1.0]), 0.5: np.array([1.0]), 0.9: np.array([1.0])}
    assert wql([5.0], off) > 0

    # 실제값이 전부 0 이면 비율 지표는 정의되지 않는다
    assert np.isnan(wape([0, 0], [1, 1]))

    print("metrics selfcheck ok")


if __name__ == "__main__":
    _selfcheck()
