"""다음 주 요일별 발생 예측 — 방법 비교.

평가 단위는 **질문**이다. "토요일에 약속 생기시나요?" 를 던졌을 때 맞았는가.

비교는 임계값이 아니라 **같은 질문 예산**에서 한다. 방법마다 점수 분포가 달라서
같은 0.6 이 같은 뜻이 아니다. "주당 0.5건 물어볼 수 있다면 누가 제일 잘 고르나" 가
제품이 실제로 마주하는 질문이다.

    python methods.py
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

import mpp
from next_week import LOOKBACK, DECAY, FIRST_TEST_WEEK, category_prior

HERE = Path(__file__).parent
WEEKDAY = ["월", "화", "수", "목", "금", "토", "일"]


# ── 특징 추출 ────────────────────────────────────────────────────────────────
def cells(tx: pd.DataFrame, weeks: range) -> pd.DataFrame:
    """(사람 × 주 × 카테고리 × 요일) 후보 격자 + 예측에 쓸 특징.

    특징은 전부 `week` 이전 데이터로만 만든다. 미래를 보면 평가가 무의미하다.
    """
    rows = []
    for p, ph in tx.groupby("person"):
        cats = ph.category.unique()
        for w in weeks:
            hist = ph[ph.week < w]
            if hist.empty:
                continue
            look = np.arange(max(0, w - LOOKBACK), w)
            wt = DECAY ** (w - 1 - look)
            wsum = wt.sum()
            actual = set(zip(ph[ph.week == w].category, ph[ph.week == w].weekday))

            for cat in cats:
                sub = hist[hist.category == cat]
                if sub.empty:
                    continue
                # 요일별 감쇠 발생률 + 최근 4주 원시 히트
                hits = np.zeros(7)
                raw4 = np.zeros(7)
                for wi, week in enumerate(look):
                    for d in sub[sub.week == week].weekday.unique():
                        hits[d] += wt[wi]
                        if week >= w - 4:
                            raw4[d] += 1
                rate = hits / wsum
                weeks_active = (DECAY ** (w - 1 - look)).sum()

                # 그 주에 (요일 무관) 발생한 비율
                any_week = sum(wt[wi] for wi, week in enumerate(look)
                               if (sub.week == week).any()) / wsum

                # 경과일과 빈도
                last_day = int(sub.day.max())
                elapsed = w * 7 - last_day
                per_week = len(sub) / max(len(look), 1)

                for d in range(7):
                    rows.append({
                        "person": p, "week": w, "category": cat, "weekday": d,
                        "rate": rate[d], "raw4": raw4[d], "any_week": any_week,
                        "elapsed": elapsed, "per_week": per_week,
                        "n_obs": len(sub), "weeks_active": weeks_active,
                        "occurred": (cat, d) in actual,
                    })
    return pd.DataFrame(rows)


# ── 방법들 ──────────────────────────────────────────────────────────────────
def m1_baseline(f: pd.DataFrame, _pop=None) -> np.ndarray:
    """현재 방식. 요일별 감쇠 발생률을 그대로 점수로 쓴다."""
    return f.rate.to_numpy()


def m2_hierarchical(f: pd.DataFrame, pop: dict) -> np.ndarray:
    """계층 베타-이항. 관측이 적으면 인구 요일 프로파일로 shrink 한다.

    관측 2주짜리 사용자의 "3주 중 3주 발생 = 100%" 를 그대로 믿으면 안 된다.
    """
    prior_p = np.array([pop["weekday"].get((c, d), pop["base"])
                        for c, d in zip(f.category, f.weekday)])
    strength = 4.0                                  # 인구 사전분포 = 관측 4주 상당
    n = f.weeks_active.to_numpy()
    return (f.rate.to_numpy() * n + prior_p * strength) / (n + strength)


def m3_factored(f: pd.DataFrame, pop: dict) -> np.ndarray:
    """분해. P(요일 d 발생) = P(그 주 발생) × P(d | 발생).

    M1 은 둘을 섞는다 — 요일이 고른 카테고리도 발생 빈도가 높으면 점수가 오른다.
    분리하면 "이번 주에 하나?" 와 "한다면 언제?" 를 각각 제대로 추정한다.
    """
    # P(d | 발생) — 요일 분포를 정규화. 분모가 0 이면 균등.
    key = list(zip(f.person, f.week, f.category))
    df = f.assign(_k=key)
    tot = df.groupby("_k").rate.transform("sum").to_numpy()
    share = np.where(tot > 0, f.rate.to_numpy() / np.maximum(tot, 1e-9), 1 / 7)
    return f.any_week.to_numpy() * share


def m4_factored_elapsed(f: pd.DataFrame, pop: dict) -> np.ndarray:
    """M3 + 경과일. 규칙적 카테고리는 "때가 됐는지" 가 발생 확률을 움직인다."""
    base = m3_factored(f, pop)
    shapes = np.array([category_prior(c)[1] for c in f.category])
    # 규칙적(shape>1.3)인 카테고리만 보정. 무기억이면 경과일이 정보를 주지 않는다.
    lam = f.per_week.to_numpy() / 7
    gap = np.where(lam > 0, 1 / np.maximum(lam, 1e-9), 1e9)
    ratio = f.elapsed.to_numpy() / np.maximum(gap, 1e-9)
    boost = np.where(shapes >= 1.3, np.clip(ratio, 0.4, 2.0), 1.0)
    return np.clip(base * boost, 0, 1)


def m5_gbm(train: pd.DataFrame, test: pd.DataFrame, pop: dict) -> np.ndarray:
    """전역 GBM. 온디바이스는 아니고 **상한선**을 재기 위한 참조선이다."""
    from lightgbm import LGBMClassifier

    cols = ["rate", "raw4", "any_week", "elapsed", "per_week", "n_obs", "weekday"]
    X = train[cols].copy()
    X["cat"] = train.category.astype("category").cat.codes
    Xt = test[cols].copy()
    Xt["cat"] = test.category.astype("category").cat.codes

    m = LGBMClassifier(n_estimators=400, learning_rate=0.05, num_leaves=31,
                       min_child_samples=50, verbose=-1, random_state=0)
    m.fit(X, train.occurred.astype(int))
    return m.predict_proba(Xt)[:, 1]


def population(f: pd.DataFrame) -> dict:
    """인구 요일 프로파일. 학습 구간에서만 만든다."""
    g = f.groupby(["category", "weekday"]).occurred.mean()
    return {"weekday": g.to_dict(), "base": float(f.occurred.mean())}


# ── 평가 ────────────────────────────────────────────────────────────────────
def precision_at_budget(score: np.ndarray, occurred: np.ndarray,
                        n_person_week: int, budget: float) -> tuple[float, int]:
    """주·명당 `budget` 건만 물어볼 수 있을 때의 정밀도."""
    k = int(round(budget * n_person_week))
    if k <= 0 or k > len(score):
        return float("nan"), 0
    idx = np.argsort(-score)[:k]
    return float(occurred[idx].mean()), k


def main() -> None:
    tx = pd.read_parquet(HERE / "data/synthetic_tx.parquet")
    all_weeks = range(FIRST_TEST_WEEK, int(tx.week.max()) + 1)
    split = FIRST_TEST_WEEK + (len(list(all_weeks)) // 2)

    print("특징 추출 중…", flush=True)
    f = cells(tx, all_weeks)
    train = f[f.week < split]
    test = f[f.week >= split].reset_index(drop=True)
    pop = population(train)          # 인구 사전분포는 학습 구간에서만

    n_pw = test.groupby(["person", "week"]).ngroups
    occ = test.occurred.to_numpy()
    print(f"학습 {len(train):,}건(주 {FIRST_TEST_WEEK}~{split-1}) · "
          f"테스트 {len(test):,}건(주 {split}~{int(tx.week.max())})")
    print(f"테스트 실제 발생률 {occ.mean():.1%} · 사람-주 {n_pw:,}\n")

    methods = [
        ("M1 현재 방식 (요일 감쇠율)", lambda: m1_baseline(test, pop)),
        ("M2 + 계층 베타-이항", lambda: m2_hierarchical(test, pop)),
        ("M3 분해 P(주)×P(요일|주)", lambda: m3_factored(test, pop)),
        ("M4 M3 + 경과일 보정", lambda: m4_factored_elapsed(test, pop)),
        ("M5 GBM 전역 (온디바이스 X)", lambda: m5_gbm(train, test, pop)),
    ]

    budgets = [0.1, 0.15, 0.25, 0.5, 1.0]
    print("=== 같은 질문 예산에서의 정밀도 (주·명당 질문 수) ===")
    head = "".join(f"{b:>9.2f}건" for b in budgets)
    print(f"{'방법':30s}{head}")
    print("-" * (30 + 10 * len(budgets)))

    results = {}
    for name, fn in methods:
        s = np.asarray(fn(), float)
        results[name] = s
        line = "".join(f"{precision_at_budget(s, occ, n_pw, b)[0]:>9.1%} " for b in budgets)
        print(f"{name:30s}{line}")

    # 차이가 우연인지 — 부트스트랩 신뢰구간. 제품이 쓸 예산에서만 본다.
    print("\n=== M3 vs M1 차이가 우연인가 (부트스트랩 2,000회) ===")
    rng = np.random.default_rng(7)
    for b in [0.15, 0.25, 0.5]:
        k = int(round(b * n_pw))
        i1 = np.argsort(-results["M1 현재 방식 (요일 감쇠율)"])[:k]
        i3 = np.argsort(-results["M3 분해 P(주)×P(요일|주)"])[:k]
        d = []
        for _ in range(2000):
            s1 = rng.choice(occ[i1], k, replace=True).mean()
            s3 = rng.choice(occ[i3], k, replace=True).mean()
            d.append(s3 - s1)
        d = np.array(d)
        lo, hi = np.percentile(d, [2.5, 97.5])
        sig = "유의" if lo > 0 else "불확실"
        print(f"  {b:>5.2f}건/주 (질문 {k:,}개)  M3−M1 = {d.mean():+.1%} "
              f"[{lo:+.1%}, {hi:+.1%}]  → {sig}")

    print("\n=== 상위 질문만 봤을 때 M3 가 무엇을 고르는가 ===")
    top = np.argsort(-results["M3 분해 P(주)×P(요일|주)"])[:int(0.25 * n_pw)]
    t = test.iloc[top]
    g = t.groupby("category").agg(질문=("occurred", "size"), 정밀도=("occurred", "mean"))
    g["정밀도"] = g["정밀도"].map("{:.1%}".format)
    print(g.sort_values("질문", ascending=False).head(8).to_string())


if __name__ == "__main__":
    main()
