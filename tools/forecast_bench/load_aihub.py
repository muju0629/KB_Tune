"""AI Hub 117 금융합성데이터 → 월별 패널 parquet.

zip 을 풀지 않고 스트림으로 읽는다. 압축 해제하면 22.3GB 인데 디스크에 그만한
자리가 없고, 필요한 건 430 컬럼 중 18 개와 300만 명 중 5,000 명뿐이다.

회원번호가 SYN_0 ~ SYN_2999999 로 순차라서 번호 나머지로 체계추출한다.
앞 5,000 명만 읽고 끊으면 빠르지만 순서 편향을 배제할 근거가 없어서 전체를 훑는다.
"""
from __future__ import annotations

import zipfile
from pathlib import Path

import pandas as pd

SRC = (Path.home() / "Downloads/117.금융 합성데이터/3.개방데이터/1.데이터"
       / "1. 합성데이터/03.카드 승인매출정보.zip")
OUT = Path(__file__).parent / "data"

STRIDE = 600        # 3,000,000 / 600 = 5,000 명
CHUNK = 200_000

# 타깃과 피처. B0M = 당월, R3M/R6M = 최근 n개월 누적(기준월 이전이므로 누출 아님).
KEEP = [
    "기준년월", "발급회원번호",
    "이용금액_신용_B0M", "이용금액_체크_B0M",        # 타깃 구성
    "이용건수_신용_B0M", "이용건수_체크_B0M",
    "이용금액_신용_R3M", "이용금액_체크_R3M",        # 피처
    "이용금액_신용_R6M", "이용금액_체크_R6M",
    "이용후경과월_신용", "최종이용일자_기본",         # recency
    "이용가맹점수", "이용금액_업종기준",
    "_1순위업종", "_1순위업종_이용금액",
    "이용금액_온라인_B0M", "이용금액_오프라인_B0M",
]


def main() -> None:
    OUT.mkdir(exist_ok=True)
    frames = []
    with zipfile.ZipFile(SRC) as zf:
        for name in sorted(zf.namelist()):          # 201807_… ~ 201812_…
            kept = 0
            with zf.open(name) as fh:
                for chunk in pd.read_csv(fh, usecols=KEEP, chunksize=CHUNK,
                                         encoding="utf-8"):
                    no = chunk["발급회원번호"].str.slice(4).astype("int64")
                    part = chunk[no % STRIDE == 0]
                    kept += len(part)
                    frames.append(part)
            print(f"  {name[:6]}  {kept:,}명", flush=True)

    df = pd.concat(frames, ignore_index=True)
    df = df.rename(columns={"발급회원번호": "user_id", "기준년월": "ym"})
    df["amount"] = df["이용금액_신용_B0M"] + df["이용금액_체크_B0M"]
    df["tx_count"] = df["이용건수_신용_B0M"] + df["이용건수_체크_B0M"]
    df = df.sort_values(["user_id", "ym"]).reset_index(drop=True)

    path = OUT / "monthly.parquet"
    df.to_parquet(path, index=False)

    # 검증 출력 — 행수·기간·결측·타깃 분포
    print(f"\n{path}  {len(df):,} 행 × {df.shape[1]} 컬럼")
    print(f"  회원 {df.user_id.nunique():,} 명 · 기간 {sorted(df.ym.unique())}")
    print(f"  회원당 관측 월수: {df.groupby('user_id').size().value_counts().to_dict()}")
    na = df.isna().sum()
    print(f"  결측 있는 컬럼: {na[na > 0].to_dict() or '없음'}")
    print(f"  amount  0원 비율 {(df.amount == 0).mean():.1%}"
          f" · 중앙값 {df.amount.median():,.0f} · 평균 {df.amount.mean():,.0f}"
          f" · p99 {df.amount.quantile(.99):,.0f}")


if __name__ == "__main__":
    main()
