"""금액과 주기를 한 모델로 — 계층 marked renewal process.

두 축을 따로 두지 않는다. (사용자 × 카테고리) 하나당 카운터 몇 개만 들고,
거기서 "언제"와 "얼마"가 같이 나온다. 주간 총액은 두 축의 합성이라 세 번째
모델이 필요 없다.

    빈도  count ~ Poisson(λ · days),  λ ~ Gamma(a, b)        ← 개인이 학습
    금액  log(건당금액) ~ Normal(μ, σ²),  μ ~ Normal(μ₀, τ²)  ← 개인이 학습
    규칙성 간격 분포의 형태(shape)                              ← 카테고리 사전분포에 고정

규칙성을 개인이 학습하지 않는 이유: 미용실은 누구에게나 주기적이고 카페는
누구에게나 불규칙하다. 형태를 고정하면 rate 만 남아서 켤레가 되고, 온라인
업데이트가 닫힌 형태가 된다 — 폰에서 카운터 두 개 올리면 끝이고 서버가 필요 없다.

이 구조가 허들 모델을 대체하는 게 아니라 일반화한다. 허들 1단 P(주내 발생)은
여기서 1 − S(7일) 로 유도되고, 2단 금액 분위는 로그정규 posterior 의 분위다.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

RNG = np.random.default_rng(0)


@dataclass
class Prior:
    """인구 사전분포. 카테고리별로 하나. 이 표가 forecast_prior.json 이 된다."""
    a: float           # λ 의 Gamma 사전 shape
    b: float           # λ 의 Gamma 사전 rate (일 단위)
    mu0: float         # log 건당금액의 사전 평균
    tau2: float        # 그 사전 분산 (개인차)
    sigma2: float      # 개인 내부 분산 (같은 사람의 건별 흔들림)
    gap_shape: float = 1.0   # 간격 분포 형태. 1=무작위, >1=주기적


@dataclass
class Counters:
    """폰에 저장되는 개인 상태. 관측 하나당 덧셈 몇 번.

    카운터를 그냥 누적하면 습관이 바뀌어도 사후분포가 안 움직인다.
    관측 100개가 쌓인 뒤의 새 관측 하나는 1% 가중치밖에 못 갖는다 —
    금주를 시작해도 λ 가 내려오는 데 몇 달 걸린다는 뜻이다.
    그래서 갱신 전에 decay 를 곱한다. 유효 기억 길이는 대략 1/(1−decay) 관측.
    """
    n_tx: float = 0.0        # 누적 건수 (감쇠하므로 실수)
    days: float = 0.0        # 관측 기간(일)
    sum_log: float = 0.0     # Σ log(건당금액)
    n_amt: float = 0.0       # 금액 관측 수
    last_gap: float = 0.0    # 마지막 발생 이후 경과일 (종료 판정용)
    sum_log2: float = 0.0    # Σ log(건당금액)²  — 개인 내 분산 추정용
    n_gap: float = 0.0       # 관측된 간격 수        ┐ 개인 규칙성(shape) 추정용.
    sum_gap: float = 0.0     # Σ 간격                │ 간격의 변동계수가 shape 만의
    sum_gap2: float = 0.0    # Σ 간격²               ┘ 함수라서 이 셋으로 역산된다.

    def update(self, count: int, total_amount: float, days: float,
               decay: float = 1.0, gaps: list[float] | None = None) -> None:
        """온라인 업데이트. 재학습이 아니라 카운터 증가다. decay=1 이면 무한 기억.

        gaps 는 이 기간에 **실제로 관측된** 발생 간격(일)이다. 규칙성 추정에만 쓴다.
        넘기지 않으면 규칙성을 추정하지 않는다 — 집계 건수에서 간격을 만들어내면
        안 된다. days/count 로 균등 분할하면 분산이 인위적으로 줄어 shape 가
        부풀려지고(카페가 1.0 대신 1.7 로 나왔다), 그 때문에 종료 판정이 오작동한다.
        앱에서는 일정에 날짜가 있으니 실제 간격을 넘길 수 있다.
        """
        if decay < 1.0:
            self.n_tx *= decay
            self.days *= decay
            self.sum_log *= decay
            self.sum_log2 *= decay
            self.n_amt *= decay
            self.n_gap *= decay
            self.sum_gap *= decay
            self.sum_gap2 *= decay
        self.n_tx += count
        self.days += days
        for g in gaps or ():
            if g > 0:
                self.n_gap += 1
                self.sum_gap += g
                self.sum_gap2 += g * g
        if count > 0 and total_amount > 0:
            lg = np.log(total_amount / count)
            self.sum_log += lg * count
            self.sum_log2 += lg * lg * count
            self.n_amt += count
            self.last_gap = 0.0
        else:
            self.last_gap += days


def posterior_rate(c: Counters, p: Prior) -> float:
    """일당 발생률의 사후 평균. Gamma-Poisson 켤레."""
    return (p.a + c.n_tx) / (p.b + c.days)


@dataclass
class Tracker:
    """습관 변화를 따라가는 이중 추정기.

    decay 하나로는 적응 속도와 안정성을 동시에 얻을 수 없다 — 자체검증에서
    decay=0.85 단일 추정이 금주 감지에 24주 걸리는 것으로 잡혔다.
    빠르게 잊으면 포아송 잡음에 흔들리고, 느리게 잊으면 변화를 놓친다.

    그래서 둘을 같이 든다. 느린 쪽이 평소 예측을 하고(안정), 빠른 쪽이 변화를
    감지한다(민감). 둘이 배수 이상 벌어지면 습관이 바뀐 것으로 보고 느린 쪽을
    빠른 쪽으로 재설정한다 — 새 수준을 즉시 채택하고 다시 안정 상태로 간다.

    감소 방향에는 확인을 요구한다. 예산 앱에서 과소 배정은 초과 지출을 부르고
    과대 배정은 기회손실에 그친다 — 위험이 비대칭이라 대응도 비대칭이어야 한다.
    """
    slow: Counters = field(default_factory=Counters)
    fast: Counters = field(default_factory=Counters)
    decay_slow: float = 0.95
    decay_fast: float = 0.6
    ratio: float = 2.5          # 이 배수 이상 벌어지면 변화로 판정
    switches: int = 0           # 재설정 횟수 (거짓경보 진단용)
    ended: bool = False         # 종료 확정. 참이면 빈도 추정을 동결한다

    def memory_scale(self, p: Prior) -> float:
        """기억 길이를 그 카테고리의 주기 단위로 맞추는 보정.

        decay 를 주 단위로 고정하면 저빈도 카테고리가 불리하다 — 유효 창 20주 안에
        미용실(6주 주기)은 관측이 3~4건뿐이라 추정이 흔들린다(35일 → 23일).
        주기가 길수록 감쇠를 약하게 해서 "관측 N건" 기준으로 기억하게 만든다.
        """
        gap = 1.0 / max(p.a / p.b, 1e-9)
        return min(7.0 / max(gap, 7.0), 1.0)

    def update(self, count: int, total_amount: float, days: float,
               p: Prior | None = None, end_threshold: float = 0.9,
               gaps: list[float] | None = None) -> None:
        # 종료가 확정된 뒤에도 빈 주를 계속 누적하면 추정 주기가 무한히 늘어난다.
        # 끝난 걸 아는데 "이제 16일 주기"라고 갱신하는 건 의미가 없다. 동결한다.
        # 다시 발생하면 즉시 해제하고 학습을 재개한다.
        if self.ended and count == 0:
            return
        if count > 0:
            self.ended = False

        # memory_scale 은 slow(안정 추정)에만 걸어야 한다. fast 까지 늘리면
        # 변화 감지가 함께 느려진다 — 자체검증에서 새 습관 감지가 6주 → 15주로
        # 악화되는 것으로 잡혔다. fast 의 임무는 민감도이므로 창을 짧게 유지한다.
        s = self.memory_scale(p) if p is not None else 1.0
        self.slow.update(count, total_amount, days, self.decay_slow ** s, gaps)
        self.fast.update(count, total_amount, days, self.decay_fast, gaps)
        if p is not None:
            if self._diverged(p):
                self.slow = Counters(**self.fast.__dict__)
                self.switches += 1
            if self.quit_signal(p) >= end_threshold:
                self.ended = True

    def _diverged(self, p: Prior) -> bool:
        """변화 판정은 사전분포를 섞지 않은 원시 관측률로 한다.

        사후분포로 비교하면 안 된다 — 사전분포 무게(b일 상당)가 유효 창이 짧은
        빠른 추정을 훨씬 강하게 끌어당겨서, 습관이 그대로인 정상 상태에서도
        두 추정이 배수로 벌어진다. 그러면 판정이 편향을 재는 셈이 된다.
        +0.5 는 관측이 0건일 때 비가 발산하지 않게 하는 가드다.
        """
        if min(self.fast.days, self.slow.days) < 14:      # 표본이 없으면 판정 보류
            return False
        rf = (self.fast.n_tx + 0.5) / self.fast.days
        rs = (self.slow.n_tx + 0.5) / self.slow.days
        return max(rf, rs) / max(min(rf, rs), 1e-9) > self.ratio

    def rate(self, p: Prior) -> float:
        return posterior_rate(self.slow, p)

    def rising(self, p: Prior) -> bool:
        """늘어나는 방향의 변화인가. 늘어난 건 바로 반영해도 안전하다."""
        return posterior_rate(self.fast, p) > posterior_rate(self.slow, p)

    def dropped(self, p: Prior, ratio: float = 2.0) -> bool:
        """빈도가 급감했는가. **불규칙 카테고리의 "그만뒀다"는 이 신호로 잡는다.**

        prob_ended 는 규칙적인 카테고리에만 쓸 수 있다 — 무기억 분포에서는 긴 공백이
        증거가 못 되기 때문이다. 그런데 술 모임처럼 불규칙한 습관도 끊을 수 있다.
        그건 "때를 넘겼다"가 아니라 "빈도가 떨어졌다"로 나타난다.

        즉 종료 감지에 경로가 둘이다:
          규칙적(shape ≥ 1.3)  → prob_ended,  경과일 기반
          불규칙(shape < 1.3)  → dropped,     빈도 변화 기반
        """
        if self.fast.days < 14 or self.slow.n_amt < MIN_EVENTS_FOR_ENDING:
            return False
        rf = (self.fast.n_tx + 0.5) / self.fast.days
        rs = (self.slow.n_tx + 0.5) / self.slow.days
        return rs / max(rf, 1e-9) > ratio

    def quit_signal(self, p: Prior) -> float:
        """"그만둔 것 같다"의 통합 신호. 카테고리 성질에 따라 경로를 고른다."""
        if p.gap_shape >= MIN_SHAPE_FOR_ENDING:
            return prob_ended(self.slow, p)
        return 1.0 if self.dropped(p) else 0.0


# 개인 내 분산 추정에 쓰는 가상 관측 수. 이만큼은 인구값을 믿는다.
SIGMA2_PSEUDO = 3.0


def effective_sigma2(c: Counters, p: Prior) -> float:
    """개인 내 분산을 관측에서 추정하고 인구값으로 shrink 한다.

    인구값을 그대로 쓰면 안정적인 반복 일정에 과대하다 — 카드 거래 일반의
    분산(0.16)을 "와드 42,000/38,000원" 같은 패턴에 적용하면 80% 구간이
    21,800~73,400원까지 벌어진다. 반대로 관측만 쓰면 2건에서 분산이 0 에 가까워져
    구간이 붕괴한다. 그래서 섞는다.
    """
    if c.n_amt < 2:
        return p.sigma2
    mean = c.sum_log / c.n_amt
    obs = max(c.sum_log2 / c.n_amt - mean * mean, 0.0)
    obs *= c.n_amt / max(c.n_amt - 1, 1)        # 표본분산 보정
    w = c.n_amt / (c.n_amt + SIGMA2_PSEUDO)
    return float(w * obs + (1 - w) * p.sigma2)


def posterior_log_amount(c: Counters, p: Prior) -> tuple[float, float]:
    """log 건당금액의 사후 (평균, 표준편차). Normal-Normal 켤레.

    관측이 없으면 사전분포를 그대로 쓴다 — 콜드스타트가 여기서 자동 처리된다.
    """
    if c.n_amt == 0:
        return p.mu0, np.sqrt(p.tau2 + p.sigma2)
    s2 = effective_sigma2(c, p)
    prec0, prec = 1 / p.tau2, c.n_amt / s2
    mu = (p.mu0 * prec0 + c.sum_log / s2) / (prec0 + prec)
    var = 1 / (prec0 + prec) + s2            # 사후 불확실성 + 개인 내부 분산
    return mu, np.sqrt(var)


def _weibull_scale(lam: float, k: float) -> float:
    """평균 간격을 1/lam 으로 유지하는 Weibull scale.

    Weibull 평균은 scale·Γ(1+1/k) 다. scale 을 k/lam 같은 걸로 두면 형태를
    바꿀 때 평균 빈도까지 따라 움직인다 — 규칙성과 빈도는 직교해야 한다.
    미용실을 "더 주기적"으로 만들었다고 방문 횟수가 변하면 안 된다.
    """
    return 1.0 / (max(lam, 1e-12) * math.gamma(1 + 1 / k))


def _survival(gap: float, lam: float, k: float) -> float:
    """간격이 gap 을 넘길 확률. k=1 이면 지수분포(무기억)."""
    gap = max(gap, 0.0)
    if k == 1.0:
        return float(np.exp(-lam * gap))
    return float(np.exp(-((gap / _weibull_scale(lam, k)) ** k)))


def prob_within(c: Counters, p: Prior, days: float, elapsed: float = 0.0) -> float:
    """다음 `days` 일 안에 발생할 확률. 추천 임계값을 여기 건다.

    형태가 1 이면 무기억(포아송)이라 elapsed 가 영향을 주지 않는다.
    형태가 1 보다 크면 주기적이라 경과일이 길수록 확률이 올라간다 —
    "보통 12일마다 가시는데 오늘 14일째예요" 가 이 항에서 나온다.
    """
    lam, k = posterior_rate(c, p), p.gap_shape
    if k == 1.0:
        return float(1 - np.exp(-lam * days))
    s_now = _survival(elapsed, lam, k)
    return float(1 - _survival(elapsed + days, lam, k) / s_now) if s_now > 0 else 1.0


# 종료 판정을 걸 수 있는 최소 규칙성. 이 아래는 판정하지 않는다.
#
# 무기억 분포(shape=1)에서는 긴 공백이 종료의 증거가 되지 못한다 — 지수분포는
# 원래 긴 간격을 자연스럽게 낳기 때문이다. 카페(3일 주기)를 한 주 안 갔을 때
# 계산해 보면 종료 확률이 37% 로 튀는데, 그건 습관이 끝난 게 아니라 그냥 한 주다.
# 그 상태로 "이제 안 가시나요?" 를 띄우면 오작동으로 보인다.
MIN_SHAPE_FOR_ENDING = 1.3
MIN_EVENTS_FOR_ENDING = 3.0     # 표본이 이보다 적으면 판정 보류


def prob_ended(c: Counters, p: Prior, prior_end: float = 0.05) -> float:
    """습관이 끝났을 확률. "미용실 보통 6주인데 14주 됐어요" 를 수치화한다.

    가설 둘을 놓고 베이즈로 가른다 — 끝났다 vs 아직인데 운이 없었다.
    경과일이 간격 분포의 꼬리로 갈수록 S(elapsed) 가 0 에 가까워져 확률이 1 로 간다.

    규칙적인 카테고리에만 걸린다 (MIN_SHAPE_FOR_ENDING 참조).
    그리고 예산에서 자동으로 빼는 데 쓰면 안 된다 — 사용자에게 물어보는 트리거다.
    한 주 안 갔다고 술값을 예산에서 빼면 다음 주에 마시고 초과한다.
    """
    if c.n_tx <= 0 or p.gap_shape < MIN_SHAPE_FOR_ENDING:
        return 0.0
    if c.n_amt < MIN_EVENTS_FOR_ENDING:
        return 0.0
    surv = _survival(c.last_gap, posterior_rate(c, p), p.gap_shape)
    denom = prior_end + (1 - prior_end) * surv
    return float(prior_end / denom) if denom > 0 else 1.0


# 간격 변동계수 → shape 역산표. Weibull 의 CV 는 shape 만의 함수라서
# 개인 간격 몇 개만 있으면 "이 사람에게 이 카테고리가 얼마나 규칙적인가"가 나온다.
# 서버 전송이 필요 없다 — 폰에서 합 세 개(n_gap, sum_gap, sum_gap2)로 계산된다.
_SHAPE_GRID = np.linspace(0.5, 6.0, 111)
_CV_GRID = np.array([
    np.sqrt(math.gamma(1 + 2 / k) / math.gamma(1 + 1 / k) ** 2 - 1) for k in _SHAPE_GRID
])


def estimate_shape(c: Counters, p: Prior, min_gaps: float = 5.0) -> float:
    """개인 간격의 변동계수에서 shape 를 역산한다. 표본이 적으면 사전분포를 쓴다.

    CV 가 작다 = 간격이 일정하다 = 주기적 = shape 큼
    CV 가 1 근처 = 무작위(지수분포) = shape 1
    """
    if c.n_gap < min_gaps:
        return p.gap_shape
    mean = c.sum_gap / c.n_gap
    var = max(c.sum_gap2 / c.n_gap - mean * mean, 0.0)
    if mean <= 0 or var <= 0:
        return p.gap_shape
    cv = np.sqrt(var) / mean
    # CV_GRID 는 shape 에 대해 단조감소라 뒤집어서 보간한다
    k = float(np.interp(cv, _CV_GRID[::-1], _SHAPE_GRID[::-1]))
    # 표본이 적을 때는 사전분포와 섞는다 (w = n/(n+k), 여기서 k=5 관측 상당)
    w = c.n_gap / (c.n_gap + 5.0)
    return float(w * k + (1 - w) * p.gap_shape)


def sample_total(c: Counters, p: Prior, days: float, n_draw: int = 500,
                 rng: np.random.Generator = RNG) -> np.ndarray:
    """기간 총액의 표본. 건수와 건당금액을 각각 뽑아 합친다.

    probability.py 의 rng.gauss(mu, SPEND_SIGMA) 를 대체하는 분포가 이것이다.
    σ 를 고정하지 않고 두 축의 사후분포에서 직접 나온다.
    """
    # λ 를 점추정으로 쓰면 Poisson 분산=평균이라 건수 과산포를 못 잡는다.
    # 사후 Gamma 에서 매번 뽑으면 예측분포가 음이항이 되어 산포가 맞는다.
    lam = rng.gamma(p.a + c.n_tx, 1.0 / (p.b + c.days), n_draw)
    mu, sd = posterior_log_amount(c, p)
    counts = rng.poisson(lam * days)
    out = np.zeros(n_draw)
    hit = counts > 0
    if hit.any():
        # 건수가 다 다르므로 최대 건수만큼 뽑아 놓고 마스크로 더한다
        top = int(counts.max())
        amt = rng.lognormal(mu, sd, (n_draw, top))
        mask = np.arange(top)[None, :] < counts[:, None]
        out = (amt * mask).sum(1)
    return out


def fit_prior(counts: np.ndarray, per_tx_by_user: np.ndarray, days: float,
              gap_shape: float = 1.0) -> Prior:
    """인구 사전분포를 적률법으로 맞춘다.

    counts          회원-기간별 건수 (1차원)
    per_tx_by_user  (회원 × 기간) 건당 금액. 관측 없는 칸은 nan
    days            한 관측의 기간(일)

    tau2 와 sigma2 를 분산분해로 나눈다 — 인구 분산을 반씩 쪼개면 개인 내부
    분산이 과대해져서 로그정규 표본이 폭발한다.
    """
    counts = np.asarray(counts, float)
    rates = counts / days
    m, v = rates.mean(), rates.var()
    # Gamma(a,b): 평균 a/b, 분산 a/b². 관측 자체의 Poisson 잡음(m/days)을 뺀다.
    if v > m / days and m > 0:
        b = m / (v - m / days)
        a = m * b
    else:
        a, b = max(m, 1e-6), 1.0

    logs = np.log(np.asarray(per_tx_by_user, float))
    logs[~np.isfinite(logs)] = np.nan
    with np.errstate(invalid="ignore"):
        mean_i = np.nanmean(logs, axis=1)          # 개인별 평균
        within_i = np.nanvar(logs, axis=1, ddof=1)  # 개인 내부 분산
    mean_i = mean_i[np.isfinite(mean_i)]
    within_i = within_i[np.isfinite(within_i)]

    sigma2 = float(within_i.mean()) if len(within_i) else 0.1
    # 개인 평균의 관측 분산에는 개인 내부 잡음이 섞여 있다. 대략 빼준다.
    n_obs = np.isfinite(logs).sum(1).mean()
    tau2 = max(float(mean_i.var() - sigma2 / max(n_obs, 1)), 1e-3)

    return Prior(a=float(a), b=float(b), mu0=float(mean_i.mean()),
                 tau2=tau2, sigma2=max(sigma2, 1e-3), gap_shape=gap_shape)


def _selfcheck() -> None:
    p = Prior(a=2.0, b=30.0, mu0=np.log(10_000), tau2=0.25, sigma2=0.25)

    # 관측 없으면 사전분포 그대로 — 콜드스타트
    c0 = Counters()
    mu, sd = posterior_log_amount(c0, p)
    assert abs(mu - p.mu0) < 1e-12
    assert sd > np.sqrt(p.sigma2)                     # 불확실성이 더 크다

    # 관측이 쌓이면 개인값으로 끌려간다 (shrinkage 가 자동)
    c = Counters()
    for _ in range(20):
        c.update(count=4, total_amount=4 * 30_000, days=30)
    mu_n, sd_n = posterior_log_amount(c, p)
    assert mu_n > mu, "개인 금액이 높으면 사후 평균이 올라가야 한다"
    assert mu_n < np.log(30_000), "사전분포 쪽으로 일부는 남아야 한다 (완전 이동 금지)"
    assert sd_n < sd, "관측이 쌓이면 불확실성이 줄어야 한다"

    # 온라인 업데이트가 순서에 무관 (합만 쓰므로)
    c1, c2 = Counters(), Counters()
    c1.update(2, 20_000, 30); c1.update(5, 100_000, 30)
    c2.update(5, 100_000, 30); c2.update(2, 20_000, 30)
    assert posterior_rate(c1, p) == posterior_rate(c2, p)
    assert abs(c1.sum_log - c2.sum_log) < 1e-9

    # 발생률이 높으면 기간 내 발생 확률도 높다
    hi, lo = Counters(n_tx=60, days=30), Counters(n_tx=1, days=30)
    assert prob_within(hi, p, 7) > prob_within(lo, p, 7)
    # 기간이 길면 확률이 올라간다
    assert prob_within(lo, p, 30) > prob_within(lo, p, 7)
    # 확률은 [0,1]
    assert 0 <= prob_within(lo, p, 7) <= 1

    # 주기적(shape>1)이면 경과일이 길수록 확률이 올라간다. 무작위면 변하지 않는다.
    per = Prior(**{**p.__dict__, "gap_shape": 3.0})
    assert prob_within(lo, per, 7, elapsed=30) > prob_within(lo, per, 7, elapsed=0)
    assert abs(prob_within(lo, p, 7, elapsed=30) - prob_within(lo, p, 7, elapsed=0)) < 1e-9

    # 총액 표본: 발생률 0 에 가까우면 0원이 많고, 높으면 양수
    s_lo = sample_total(Counters(n_tx=0, days=300), p, 7)
    s_hi = sample_total(Counters(n_tx=300, days=30), p, 7)
    assert s_hi.mean() > s_lo.mean()
    assert (s_lo == 0).mean() > 0.5, "저빈도 사용자는 0원 주가 많아야 한다"
    assert (s_hi > 0).all()

    # 사전분포 적률법이 평균과 분산분해를 복원한다
    rng = np.random.default_rng(1)
    true_rate, n, periods = 0.2, 5000, 6
    cnt = rng.poisson(true_rate * 30, n * periods)
    # 개인 간 분산 0.30, 개인 내부 분산 0.10 으로 만들어 넣는다
    mu_i = rng.normal(np.log(12_000), np.sqrt(0.30), (n, 1))
    amt = np.exp(rng.normal(mu_i, np.sqrt(0.10), (n, periods)))
    fp = fit_prior(cnt, amt, days=30)
    assert abs(fp.a / fp.b - true_rate) < 0.05, f"rate 복원 실패: {fp.a / fp.b:.3f}"
    assert abs(np.exp(fp.mu0) - 12_000) / 12_000 < 0.1
    assert abs(fp.sigma2 - 0.10) < 0.02, f"개인 내부 분산 복원 실패: {fp.sigma2:.3f}"
    assert abs(fp.tau2 - 0.30) < 0.05, f"개인 간 분산 복원 실패: {fp.tau2:.3f}"

    # 예측분포가 음이항(과산포)이어야 한다 — Poisson 이면 분산=평균
    c_mid = Counters(n_tx=30, days=120)
    draws = sample_total(c_mid, p, 30, n_draw=20_000)
    assert draws.var() > draws.mean(), "예측 산포가 과소하다 (λ 점추정 회귀)"

    _check_regime_change(p)
    print("mpp selfcheck ok")


def _in_ballpark(rate: float, target: float, fold: float) -> bool:
    """추정이 실제의 fold 배 안에 들어왔는가.

    "정확히 수렴했는가"를 재면 안 된다 — 사후분포는 인구 사전분포에 붙어 있고
    관측 몇 주로 그걸 버리지 않는 게 올바른 동작이다. 사전 평균이 새 실제값보다
    높으면 정확 수렴은 사전분포를 이겨야 하는 문제가 되어 감지 성능과 무관해진다.
    제품이 필요한 건 "10배 틀린 상태를 몇 주 만에 벗어나는가"다.
    """
    lo, hi = min(rate, target), max(rate, target)
    return hi / max(lo, 1e-12) <= fold


def _lag_single(p: Prior, before: float, after: float, decay: float,
                fold: float = 2.0, warmup: int = 20, limit: int = 60) -> int:
    """단일 decay 추정기의 감지 지연. Tracker 와 비교하기 위한 기준선."""
    c = Counters()
    for _ in range(warmup):
        c.update(before * 7, before * 7 * 20_000, days=7, decay=decay)
    for w in range(1, limit + 1):
        c.update(after * 7, after * 7 * 20_000, days=7, decay=decay)
        if _in_ballpark(posterior_rate(c, p), after, fold):
            return w
    return limit + 1


def _lag_tracker(p: Prior, before: float, after: float, fold: float = 2.0,
                 warmup: int = 20, limit: int = 60) -> tuple[int, int]:
    """Tracker 의 감지 지연과 재설정 횟수."""
    t = Tracker()
    for _ in range(warmup):
        t.update(before * 7, before * 7 * 20_000, 7, p)
    base = t.switches
    for w in range(1, limit + 1):
        t.update(after * 7, after * 7 * 20_000, 7, p)
        if _in_ballpark(t.rate(p), after, fold):
            return w, t.switches - base
    return limit + 1, t.switches - base


def _check_regime_change(p: Prior) -> None:
    """습관이 바뀔 때 따라오는가. 정확도가 아니라 감지 지연을 잰다."""
    # 금주: 하루 0.5건 → 0.05건
    never = _lag_single(p, 0.5, 0.05, decay=1.0)
    single = _lag_single(p, 0.5, 0.05, decay=0.85)
    dual, _ = _lag_tracker(p, 0.5, 0.05)
    assert single < never, f"망각이 도움이 안 됐다 ({single} vs {never})"
    assert dual < single, f"이중 추정이 단일보다 못하다 ({dual} vs {single})"
    assert dual <= 8, f"금주 감지에 {dual}주 걸린다 — 너무 느리다"

    # 카페를 갑자기 자주 가기 시작: 늘어나는 방향도 같은 속도로 잡아야 한다
    up, _ = _lag_tracker(p, 0.1, 1.0)
    assert up <= 8, f"새 습관 감지에 {up}주 걸린다"

    # 거짓경보: 습관이 안 바뀌었는데 재설정이 잦으면 안 된다.
    # 포아송 잡음만 있는 정상 상태를 100주 흘린다.
    rng = np.random.default_rng(7)
    t = Tracker()
    for _ in range(100):
        n = rng.poisson(0.5 * 7)
        t.update(n, n * 20_000, 7, p)
    assert t.switches <= 10, f"정상 상태 100주에 재설정 {t.switches}회 — 거짓경보가 많다"

    # 새 습관: 관측 없던 상태에서 단조증가해야 한다
    c = Counters()
    seen = []
    for _ in range(6):
        c.update(4 * 7, 4 * 7 * 8_000, days=7, decay=0.85)
        seen.append(posterior_rate(c, p))
    assert seen == sorted(seen), "새 습관에서 발생률이 단조증가하지 않는다"
    assert seen[-1] > 2.0, f"6주 관측 뒤에도 발생률이 {seen[-1]:.2f} 로 낮다"

    # 습관 종료 판정: 경과일이 평균 간격을 크게 넘으면 확률이 올라간다
    periodic = Prior(**{**p.__dict__, "gap_shape": 2.5})
    c = Counters(n_tx=20, days=280, n_amt=20)       # 평균 간격 14일
    c.last_gap = 7
    early = prob_ended(c, periodic)
    c.last_gap = 60
    late = prob_ended(c, periodic)
    assert late > early, "경과일이 길어져도 종료 확률이 안 오른다"
    assert early < 0.3, f"정상 주기 안인데 종료 확률이 {early:.2f} — 거짓경보"
    assert late > 0.9, f"평균 간격의 4배가 지났는데 종료 확률이 {late:.2f}"

    # 관측이 없는 카테고리에는 종료 판정을 걸지 않는다 (시작도 안 했다)
    assert prob_ended(Counters(), periodic) == 0.0

    # 무기억 카테고리(카페)에는 종료 판정을 걸지 않는다 — 한 주 안 간 게 증거가 못 된다
    cafe = Counters(n_tx=60, days=180, n_amt=60)
    cafe.last_gap = 7
    assert prob_ended(cafe, p) == 0.0, "shape=1 인데 종료 판정이 걸렸다"
    # 규칙적이면 같은 상황에서 걸린다
    assert prob_ended(Counters(n_tx=20, days=280, n_amt=20, last_gap=60), periodic) > 0.9

    # 표본이 적으면 판정 보류
    assert prob_ended(Counters(n_tx=2, days=280, n_amt=2, last_gap=60), periodic) == 0.0

    _check_shape_estimate(periodic)
    _check_freeze(periodic)


def _check_shape_estimate(p: Prior) -> None:
    """개인 간격에서 규칙성을 역산할 수 있는가."""
    rng = np.random.default_rng(3)

    def counters_from(gaps) -> Counters:
        c = Counters()
        for g in gaps:
            c.n_gap += 1
            c.sum_gap += g
            c.sum_gap2 += g * g
        return c

    # 아주 규칙적인 간격(항상 14일쯤) → shape 가 사전분포보다 커져야 한다
    reg = counters_from(rng.normal(14, 1.0, 40))
    # 무작위 간격(지수분포) → shape 가 1 쪽으로 내려가야 한다
    ran = counters_from(rng.exponential(14, 40))
    k_reg, k_ran = estimate_shape(reg, p), estimate_shape(ran, p)
    assert k_reg > k_ran, f"규칙적인데 shape 가 더 안 크다 ({k_reg:.2f} vs {k_ran:.2f})"
    assert k_ran < 2.0, f"무작위 간격인데 shape={k_ran:.2f}"
    assert k_reg > 4.0, f"거의 일정한 간격인데 shape={k_reg:.2f}"

    # 표본이 부족하면 사전분포를 그대로 쓴다
    assert estimate_shape(counters_from([14, 14]), p) == p.gap_shape


def _check_freeze(p: Prior) -> None:
    """종료 확정 후 빈도 추정이 동결되고, 재발생하면 풀리는가."""
    t = Tracker()
    for _ in range(20):
        t.update(7 / 14 * 7, 7 / 14 * 7 * 30_000, 7, p)     # 14일 주기로 20주
    for _ in range(12):                                      # 그만둠
        t.update(0, 0, 7, p)
    assert t.ended, "종료가 확정되지 않았다"
    frozen = posterior_rate(t.slow, p)
    for _ in range(20):                                      # 더 기다려도
        t.update(0, 0, 7, p)
    assert posterior_rate(t.slow, p) == frozen, "동결됐는데 주기가 계속 변한다"

    t.update(1, 30_000, 7, p)                                # 다시 하면 재개
    assert not t.ended, "재발생했는데 동결이 안 풀렸다"

    # 불규칙 카테고리(shape<1.3)도 그만두면 잡아야 한다 — 빈도 급감 경로
    irregular = Prior(**{**p.__dict__, "gap_shape": 1.0})
    t2 = Tracker()
    for _ in range(20):
        t2.update(5, 5 * 20_000, 7, irregular)               # 주 5건씩
    assert t2.quit_signal(irregular) == 0.0, "정상인데 그만둔 신호가 떴다"
    for _ in range(4):
        t2.update(0, 0, 7, irregular)
    assert t2.quit_signal(irregular) == 1.0, "불규칙 카테고리를 끊었는데 감지 못 했다"


if __name__ == "__main__":
    _selfcheck()
