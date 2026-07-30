"""비교 대상 모델. 전부 (p10, p50, p90) 을 돌려준다 — 구간이 앱 UI 요구사항이라서.

각 줄이 답하는 질문이 다르게 배치했다. 같은 질문에 답하는 모델은 넣지 않는다.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from metrics import wape as metrics_wape

QUANTILES = [0.1, 0.5, 0.9]
RNG = np.random.default_rng(0)


def _out(p50, p10=None, p90=None) -> dict:
    p50 = np.clip(np.asarray(p50, float), 0, None)
    if p10 is None:
        p10, p90 = p50 * 0.6, p50 * 1.6      # estimate.py 의 폴백 배수와 같은 규칙
    return {0.1: np.clip(p10, 0, None), 0.5: p50, 0.9: np.clip(p90, 0, None)}


# ── R0: 현재 방식 ────────────────────────────────────────────────────────────
def r0_personal_mean(d: dict) -> dict:
    """estimate.py 이식. 같은 유형 개인 이력의 산술평균, 구간은 관측 min~max.

    주의: 중앙값이 아니라 sum()//len() 평균이다. 구간도 분위가 아니라 관측 범위다.
    """
    X, lag = d["X_te"], d["lag_cols"]
    amt = X[lag].to_numpy(float)
    return _out(amt.mean(1), amt.min(1), amt.max(1))


# ── R1: 단순 기준선 ─────────────────────────────────────────────────────────
def r1_naive(d: dict) -> dict:
    """직전 달 그대로. MASE 의 기준이기도 하다."""
    return _out(d["X_te"]["lag1"].to_numpy(float))


def r1_median(d: dict) -> dict:
    X, lag = d["X_te"], d["lag_cols"]
    amt = X[lag].to_numpy(float)
    return _out(np.median(amt, 1), amt.min(1), amt.max(1))


# ── Croston / SBA: 간헐 수요 표준 ────────────────────────────────────────────
def croston(d: dict, alpha: float = 0.3, sba: bool = False) -> dict:
    """비영(非零) 수요 크기와 발생 간격을 따로 지수평활해 나눈다.

    lag 이 4개뿐이라 거친 추정이다. 그래도 허들 모델의 직계 조상이라
    "우리 허들이 Croston 을 얼마나 이겼나"가 이 표에서 가장 설명력 있는 한 줄이다.
    """
    amt = d["X_te"][d["lag_cols"]].to_numpy(float)[:, ::-1]   # 오래된 → 최근
    n, T = amt.shape
    out = np.zeros(n)
    for i in range(n):
        nz = np.flatnonzero(amt[i])
        if not len(nz):
            continue
        z = amt[i, nz[0]]                 # 수요 크기
        p = nz[0] + 1                     # 발생 간격
        last = nz[0]
        for t in nz[1:]:
            z += alpha * (amt[i, t] - z)
            p += alpha * ((t - last) - p)
            last = t
        out[i] = z / p if p > 0 else z
    if sba:
        out *= 1 - alpha / 2
    return _out(out)


def sba(d: dict) -> dict:
    return croston(d, sba=True)


# ── ETS: 고전 통계 ──────────────────────────────────────────────────────────
def ets(d: dict) -> dict:
    """단순 지수평활. lag 4개로는 추세·계절 성분을 식별할 수 없어 level 만 쓴다."""
    from statsmodels.tsa.holtwinters import SimpleExpSmoothing

    amt = d["X_te"][d["lag_cols"]].to_numpy(float)[:, ::-1]
    out = np.empty(len(amt))
    for i, row in enumerate(amt):
        if row.std() == 0:
            out[i] = row[-1]
            continue
        try:
            fit = SimpleExpSmoothing(row, initialization_method="estimated").fit()
            out[i] = fit.forecast(1)[0]
        except Exception:
            out[i] = row.mean()
    return _out(out)


# ── 선형 회귀: 비선형이 필요한지 묻는 대조군 ──────────────────────────────────
def linear_log(d: dict) -> dict:
    """금액 피처가 백만 단위라 표준화 없이는 정규방정식이 발산한다
    (divide by zero in matmul). 트리 모델은 스케일에 둔감해서 이 처리가 필요 없다.
    """
    from sklearn.linear_model import Ridge
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    m = make_pipeline(StandardScaler(), Ridge(alpha=1.0))
    m.fit(d["X_tr"], np.log1p(d["y_tr"]))
    return _out(np.expm1(m.predict(d["X_te"])))


# ── LightGBM 단일: 허들 2단이 값을 하는지 묻는 대조군 ────────────────────────
def _lgbm(objective: str, **kw):
    from lightgbm import LGBMRegressor
    return LGBMRegressor(objective=objective, n_estimators=300, learning_rate=0.05,
                         num_leaves=31, min_child_samples=40, verbose=-1,
                         random_state=0, **kw)


def lgbm_single(d: dict) -> dict:
    m = _lgbm("regression").fit(d["X_tr"], np.log1p(d["y_tr"]))
    return _out(np.expm1(m.predict(d["X_te"])))


def lgbm_quantile(d: dict) -> dict:
    """허들 없이 분위 회귀만. 허들의 기여를 분리하기 위한 중간 단계."""
    p = {}
    for a in QUANTILES:
        m = _lgbm("quantile", alpha=a).fit(d["X_tr"], np.log1p(d["y_tr"]))
        p[a] = np.expm1(m.predict(d["X_te"]))
    return _out(p[0.5], p[0.1], p[0.9])


# ── 허들 2단 + 분위 회귀: 우리 안 ────────────────────────────────────────────
def _hurdle_fit(d: dict):
    from lightgbm import LGBMClassifier

    X, y = d["X_tr"], d["y_tr"].to_numpy(float)
    occur = (y > 0).astype(int)

    clf = None
    if occur.min() != occur.max():          # 한쪽으로 완전히 치우치면 분류기가 무의미
        clf = LGBMClassifier(n_estimators=300, learning_rate=0.05, num_leaves=31,
                             min_child_samples=40, verbose=-1, random_state=0)
        clf.fit(X, occur)

    pos = y > 0
    regs = {a: _lgbm("quantile", alpha=a).fit(X[pos], np.log1p(y[pos])) for a in QUANTILES}
    return clf, regs, occur.mean()


def _hurdle_samples(d: dict, n_draw: int = 200) -> np.ndarray:
    """(n_user, n_draw) 표본. 발생 여부를 베르누이로, 금액을 분위 보간으로 뽑는다.

    probability.py 의 rng.gauss(mu, sigma) 를 대체하는 분포가 바로 이것이다.
    정규근사 σ 고정 대신 허들 모델의 경험 분포에서 직접 뽑는다.
    """
    clf, regs, base_rate = _hurdle_fit(d)
    X = d["X_te"]
    p_occur = clf.predict_proba(X)[:, 1] if clf is not None else np.full(len(X), base_rate)
    q = np.column_stack([np.expm1(regs[a].predict(X)) for a in QUANTILES])
    q = np.clip(np.sort(q, axis=1), 0, None)

    u = RNG.random((len(X), n_draw))
    amount = np.empty_like(u)
    for i in range(len(X)):
        amount[i] = np.interp(u[i], QUANTILES, q[i])
    occur = RNG.random((len(X), n_draw)) < p_occur[:, None]
    return amount * occur


def lgbm_hurdle(d: dict) -> dict:
    s = _hurdle_samples(d)
    return _out(np.median(s, 1), np.quantile(s, 0.1, axis=1), np.quantile(s, 0.9, axis=1))


# ── XGBoost: 부스팅 구현 차이를 보는 줄 ──────────────────────────────────────
def xgb_quantile(d: dict) -> dict:
    from xgboost import XGBRegressor

    p = {}
    for a in QUANTILES:
        m = XGBRegressor(objective="reg:quantileerror", quantile_alpha=a,
                         n_estimators=300, learning_rate=0.05, max_depth=6,
                         random_state=0, verbosity=0)
        m.fit(d["X_tr"], np.log1p(d["y_tr"]))
        p[a] = np.expm1(m.predict(d["X_te"]))
    return _out(p[0.5], p[0.1], p[0.9])


# ── 계층 shrinkage: 콜드스타트 ───────────────────────────────────────────────
def _credibility(n: np.ndarray, k: float) -> np.ndarray:
    """신용도 가중 w = n/(n+k). k=0 이면 개인 추정을 그대로 쓴다."""
    if k <= 0:
        return np.ones_like(n, dtype=float)
    return n / (n + k)


def hurdle_shrinkage(d: dict) -> dict:
    """w = n/(n+k) 로 개인 추정과 인구 사전을 섞는다. n = 관측된 비영 개월 수.

    k 는 학습셋을 반으로 갈라 WAPE 를 최소화하는 값으로 고른다 — 테스트를 보지 않는다.
    관측이 4개월씩 고르게 있는 이 축에서는 k→0(=shrinkage 없음)이 뽑힐 수 있다.
    그건 실패가 아니라 "충분히 관측된 구간에서는 사전분포가 기여하지 않는다"는 결과다.
    사전분포의 값어치는 콜드스타트 실험에서 드러난다.
    """
    idx = np.arange(len(d["X_tr"]))
    RNG.shuffle(idx)
    cut = len(idx) // 2
    fit_i, tune_i = idx[:cut], idx[cut:]

    d_fit = {**d, "X_tr": d["X_tr"].iloc[fit_i], "y_tr": d["y_tr"].iloc[fit_i],
             "X_te": d["X_tr"].iloc[tune_i]}
    tune = lgbm_hurdle(d_fit)
    y_tune = d["y_tr"].iloc[tune_i].to_numpy(float)
    n_tune = (d["X_tr"].iloc[tune_i][d["lag_cols"]].to_numpy(float) > 0).sum(1)
    prior = float(np.median(d["y_tr"].iloc[fit_i]))

    def loss(k: float) -> float:
        w = _credibility(n_tune, k)
        return metrics_wape(y_tune, w * tune[0.5] + (1 - w) * prior)

    k = min([0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0], key=loss)
    hurdle_shrinkage.chosen_k = k          # 보고용

    base = lgbm_hurdle(d)
    n = (d["X_te"][d["lag_cols"]].to_numpy(float) > 0).sum(1)
    w = _credibility(n, k)
    return _out(w * base[0.5] + (1 - w) * prior,
                w * base[0.1] + (1 - w) * prior * 0.6,
                w * base[0.9] + (1 - w) * prior * 1.6)


# ── CQR: 분포 가정 없이 커버리지 보정 ────────────────────────────────────────
def cqr(d: dict, target: float = 0.8) -> dict:
    """학습셋을 fit/calib 으로 나눠 적합도 점수의 분위로 구간을 넓힌다.

    분포를 가정하지 않고 유한표본 커버리지를 보장한다 — 앱이 표시하는
    "신뢰도"가 정직하다는 증거가 이 줄에서 나온다.
    """
    idx = np.arange(len(d["X_tr"]))
    RNG.shuffle(idx)
    cut = len(idx) // 2
    fit_i, cal_i = idx[:cut], idx[cut:]

    d_fit = {**d, "X_tr": d["X_tr"].iloc[fit_i], "y_tr": d["y_tr"].iloc[fit_i],
             "X_te": d["X_tr"].iloc[cal_i]}
    cal = lgbm_hurdle(d_fit)
    y_cal = d["y_tr"].iloc[cal_i].to_numpy(float)

    score = np.maximum(cal[0.1] - y_cal, y_cal - cal[0.9])
    n = len(score)
    q = np.quantile(score, min(1.0, np.ceil((n + 1) * target) / n))

    base = lgbm_hurdle(d)
    return _out(base[0.5], base[0.1] - q, base[0.9] + q)


# ── Chronos-2 zero-shot: 사전학습 모델 상한선 ────────────────────────────────
def chronos2(d: dict, raw: pd.DataFrame, device: str = "mps") -> dict:
    """월별 축은 사용자당 문맥이 4점뿐이다. 그래도 zero-shot 이라 학습은 필요 없다.

    문맥이 짧아 계절 naive 와 무승부여도 결과다 — 우리가 가벼운 모델을 고른
    근거가 된다.
    """
    import torch
    from chronos import BaseChronosPipeline

    users = d["X_te"].index
    months = sorted(raw.ym.unique())
    ctx_months = months[-1 - len(d["lag_cols"]):-1]      # 테스트 직전 4개월

    ctx = raw[raw.user_id.isin(users) & raw.ym.isin(ctx_months)].copy()
    ctx["timestamp"] = pd.to_datetime(ctx.ym, format="%Y%m")
    ctx = ctx[["user_id", "timestamp", "amount"]].sort_values(["user_id", "timestamp"])

    if device == "mps" and not torch.backends.mps.is_available():
        device = "cpu"
    pipe = BaseChronosPipeline.from_pretrained("amazon/chronos-2", device_map=device)
    pred = pipe.predict_df(ctx, prediction_length=1, quantile_levels=QUANTILES,
                           id_column="user_id", timestamp_column="timestamp",
                           target="amount")

    p = pred.set_index("user_id")            # 분위 컬럼명은 "0.1"/"0.5"/"0.9"
    return _out(p["0.5"].reindex(users).to_numpy(float),
                p["0.1"].reindex(users).to_numpy(float),
                p["0.9"].reindex(users).to_numpy(float))


# ── 금액 + 주기 동시: 계층 marked renewal process ────────────────────────────
def marked_process(d: dict) -> dict:
    """mpp.py 의 모델. 건수(주기)와 건당금액을 각각 학습해 합성으로 총액을 낸다.

    월별 축에서는 간격을 직접 관측할 수 없어 건수로 발생률을 추정한다
    (건수 8건/월 → 0.27건/일). 그래서 여기 수치는 주기 축의 상한이 아니라
    "금액·주기를 분해해도 총액 정확도를 잃지 않는가"에 대한 답이다.
    """
    import mpp

    lag = d["lag_cols"]
    cnt_cols = [f"cnt_lag{i + 1}" for i in range(len(lag))]

    # 인구 사전분포는 학습셋에서만 뽑는다 — 테스트를 보지 않는다
    tr_cnt = d["X_tr"][cnt_cols].to_numpy(float).clip(0)
    tr_amt = d["X_tr"][lag].to_numpy(float).clip(0)
    # (회원 × 기간) 2차원으로 넘겨야 fit_prior 가 개인 내/간 분산을 분해할 수 있다
    per_tx = tr_amt / np.where(tr_cnt > 0, tr_cnt, np.nan)
    prior = mpp.fit_prior(tr_cnt.ravel(), per_tx, days=30)

    te_cnt = d["X_te"][cnt_cols].to_numpy(float).clip(0)
    te_amt = d["X_te"][lag].to_numpy(float).clip(0)

    q = np.empty((len(te_cnt), 3))
    for i in range(len(te_cnt)):
        c = mpp.Counters()
        for j in range(len(lag)):                  # 오래된 달부터 순서대로 갱신
            c.update(te_cnt[i, -1 - j], te_amt[i, -1 - j], days=30)
        s = mpp.sample_total(c, prior, days=30)
        q[i] = np.quantile(s, QUANTILES)
    return _out(q[:, 1], q[:, 0], q[:, 2])


# 표에 올라가는 순서. 각 줄이 답하는 질문을 주석으로 남긴다.
REGISTRY = [
    ("R0  개인 과거 평균 (현재 방식)", r0_personal_mean),   # 현재 방식을 이기나
    ("R1a 계절 naive (직전 달)", r1_naive),                 # 단순 기준선을 이기나
    ("R1b 과거 중앙값", r1_median),
    ("R2a Croston", croston),                              # 간헐 수요 표준을 이기나
    ("R2b SBA", sba),
    ("R2c ETS", ets),                                      # 고전 통계를 이기나
    ("R3  선형 회귀 (log)", linear_log),                    # 비선형이 필요한가
    ("R4a LightGBM 단일", lgbm_single),                     # 허들·분위가 값을 하나
    ("R4b LightGBM 분위", lgbm_quantile),
    ("R4c XGBoost 분위", xgb_quantile),                     # 부스팅 구현 차이
    ("R5  LightGBM 허들 2단 + 분위", lgbm_hurdle),          # 우리 안
    ("R6  + 계층 shrinkage", hurdle_shrinkage),             # 콜드스타트에 값을 하나
    ("R7  + CQR", cqr),                                     # 구간이 캘리브레이션되나
    ("R9  금액+주기 동시 (marked process)", marked_process),  # 분해해도 정확도를 잃지 않나
]
