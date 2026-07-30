"""사용자 한 명이 앱을 쓰는 동안 온디바이스 모델이 어떻게 바뀌는지 재현한다.

주 단위로 진행하며 각 시점에 모델이 "무엇을 알고 있는지" 출력한다.
20주차에 술 모임을 끊어서 습관 변화 감지도 같이 본다.

    python onboarding_sim.py
"""
from __future__ import annotations

import numpy as np

import mpp

RNG = np.random.default_rng(11)
WEEKS = 26
QUIT_WEEK = 20          # 이 주부터 술 모임을 끊는다


class Category:
    """카테고리 하나. 인구 사전분포 + 개인 실제값 + 폰에 저장되는 추정기."""

    def __init__(self, name, prior_gap, prior_amt, shape, true_gap, true_amt):
        self.name = name
        self.true_gap, self.true_amt = true_gap, true_amt
        lam0 = 1.0 / prior_gap
        # 사전분포 세기는 30일 상당 — 개인 관측 한 달이면 대등해진다
        self.prior = mpp.Prior(a=lam0 * 30, b=30, mu0=np.log(prior_amt),
                               tau2=0.35, sigma2=0.16, gap_shape=shape)
        self.tracker = mpp.Tracker()
        self.active = True
        self.total_events = 0        # 실제 누적 건수 (감쇠 없음)
        self.last_day = None         # 마지막 발생 일자 — 실제 간격 계산용

    def week(self, w: int):
        """한 주 진행. 실제 발생 일자를 뽑아 간격까지 함께 넘긴다.

        간격을 집계 건수에서 만들어내지 않는다 — 실제 발생 시점의 차이를 쓴다.
        앱에서도 같다. 일정에 날짜가 있으니 간격이 관측된다.
        """
        n = 0 if not self.active else RNG.poisson(7.0 / self.true_gap)
        total, gaps = 0.0, []
        if n:
            days_in_week = np.sort(RNG.uniform(0, 7, n)) + (w - 1) * 7
            total = float(np.exp(RNG.normal(np.log(self.true_amt), 0.35, n)).sum())
            for d in days_in_week:
                if self.last_day is not None:
                    gaps.append(float(d - self.last_day))
                self.last_day = float(d)
        self.tracker.update(n, total, 7, self.learned_prior(), gaps=gaps)
        self.total_events += int(n)
        return n

    # ── 모델이 지금 알고 있는 것 ─────────────────────────────────────────
    def learned_prior(self) -> mpp.Prior:
        """개인 간격에서 역산한 규칙성을 반영한 사전분포.

        인구 가정으로 시작하지만 간격이 5개쯤 쌓이면 개인값으로 넘어간다.
        서버 전송 없이 폰에서 계산된다.
        """
        k = mpp.estimate_shape(self.tracker.slow, self.prior)
        return mpp.Prior(**{**self.prior.__dict__, "gap_shape": k})

    def shape(self) -> float:
        return mpp.estimate_shape(self.tracker.slow, self.prior)

    def amount(self):
        mu, sd = mpp.posterior_log_amount(self.tracker.slow, self.prior)
        return np.exp(mu), np.exp(mu - 1.2816 * sd), np.exp(mu + 1.2816 * sd)

    def gap_days(self):
        return 1.0 / mpp.posterior_rate(self.tracker.slow, self.prior)

    def prob_7d(self):
        return mpp.prob_within(self.tracker.slow, self.learned_prior(), 7,
                               elapsed=self.tracker.slow.last_gap)

    def quit(self):
        """그만둔 것 같은가. 규칙적이면 경과일로, 불규칙하면 빈도 급감으로 판정."""
        return self.tracker.quit_signal(self.learned_prior())

    def effective_n(self):
        """유효 표본수. decay 때문에 누적 건수보다 작다 — 최근 관측에 가중된 값."""
        return self.tracker.slow.n_amt


def main() -> None:
    cats = [
        # 이름      인구사전  인구금액  규칙성  개인실제  개인금액
        Category("카페",   4.0,  8_000, 1.0,  3.0,  4_500),
        Category("외식",   6.0, 18_000, 1.2,  7.0, 15_000),
        Category("술모임", 14.0, 35_000, 1.6, 10.0, 40_000),
        Category("미용실", 42.0, 35_000, 3.2, 35.0, 28_000),
    ]

    marks = {0: "설치 직후 — 데이터 0건", 1: "1주 사용", 4: "1개월", 8: "2개월",
             12: "3개월", 19: "금주 직전", 22: "금주 후 2주", 26: "금주 후 6주"}

    print("=" * 92)
    print("온디바이스 모델이 사용 중에 어떻게 바뀌는가 — 사용자 1명, 26주")
    print("=" * 92)

    for w in range(WEEKS + 1):
        if w > 0:
            for c in cats:
                if c.name == "술모임" and w >= QUIT_WEEK:
                    c.active = False
                c.week(w)

        if w not in marks:
            continue

        print(f"\n■ {w}주차 — {marks[w]}")
        print(f"  {'카테고리':8s} {'누적':>5s} {'유효':>5s} {'예상금액':>9s} {'80% 구간':>19s} "
              f"{'추정주기':>7s} {'규칙성':>6s} {'7일내':>6s} {'그만?':>6s}")
        print("  " + "─" * 92)
        for c in cats:
            amt, lo, hi = c.amount()
            print(f"  {c.name:8s} {c.total_events:>4}건 {c.effective_n():>4.0f}건 "
                  f"{amt:>8,.0f}원 {lo:>8,.0f}~{hi:>9,.0f}원 {c.gap_days():>6.1f}일 "
                  f"{c.shape():>6.2f} {c.prob_7d():>5.0%} {c.quit():>6.0%}")

        # 주간 총액 분포 — probability.py 의 σ 를 대체하는 그 분포
        draws = np.sum([mpp.sample_total(c.tracker.slow, c.prior, 7, 3000, RNG)
                        for c in cats], axis=0)
        print(f"  주간 총액 예상  중앙값 {np.median(draws):>7,.0f}원 · "
              f"80% 구간 {np.quantile(draws, .1):>7,.0f}~{np.quantile(draws, .9):>7,.0f}원 · "
              f"σ {draws.std():>7,.0f}원")

    print("\n" + "=" * 92)
    print("정답값:  카페 3일/4,500원 · 외식 7일/15,000원 · 술모임 10일/40,000원 · 미용실 35일/28,000원")
    print("=" * 92)


if __name__ == "__main__":
    main()
