"""로컬 경기 집계 소비데이터와 AI Hub 금융 합성데이터의 활용 가능 범위를 점검한다."""
from __future__ import annotations

from pathlib import Path
from zipfile import ZipFile
import json

import numpy as np
import pandas as pd


HERE = Path(__file__).parent
OUT = HERE / "results/local_spend_profile"
REGIONAL = Path("/Users/muju/Downloads/카드소비데이터.csv")
AIHUB = Path("/Users/muju/Downloads/117.금융 합성데이터/3.개방데이터/1.데이터/1. 합성데이터/03.카드 승인매출정보.zip")
AIHUB_SAMPLE_ROWS = 30_000

AIHUB_COLUMNS = {
    "이용금액_쇼핑": "쇼핑",
    "이용금액_요식": "외식",
    "이용금액_교통": "교통",
    "이용금액_의료": "자기관리",
    "이용금액_납부": "고정납부",
    "이용금액_교육": "교육",
    "이용금액_여유생활": "여가",
    "이용금액_사교활동": "모임",
    "이용금액_일상생활": "생활",
}


def target_category(row: pd.Series) -> str | None:
    major = row["카드사_업종대분류명"]
    middle = row["카드사_업종중분류명"]
    if middle == "커피/음료":
        return "카페"
    if major == "음식":
        return "외식"
    if major == "소매/유통":
        return "생활"
    if major == "의료/건강" or any(word in middle for word in ["미용", "이발", "화장품"]):
        return "자기관리"
    if major in {"여가/오락", "공연/전시"}:
        return "여가"
    return None


def profile_regional() -> tuple[pd.DataFrame, dict]:
    data = pd.read_csv(
        REGIONAL, encoding="cp949",
        dtype={"기준년월일": str, "시군구코드": str, "행정동코드": str,
               "카드사_업종분류코드": str},
    )
    for column in data.select_dtypes("object"):
        data[column] = data[column].str.strip()
    key = ["기준년월일", "시군구코드", "행정동코드", "카드사_업종분류코드",
           "시간대", "성별", "연령별", "요일"]
    data["객단가"] = data["매출금액"] / data["매출건수"].replace(0, np.nan)
    data["KB_Tune_카테고리"] = data.apply(target_category, axis=1)
    usable = data.dropna(subset=["KB_Tune_카테고리", "객단가"])
    category = usable.groupby("KB_Tune_카테고리").agg(
        집계셀=("객단가", "size"),
        매출건수=("매출건수", "sum"),
        객단가_중앙값=("객단가", "median"),
        객단가_p10=("객단가", lambda x: x.quantile(0.1)),
        객단가_p90=("객단가", lambda x: x.quantile(0.9)),
    ).reset_index()
    quality = {
        "rows": int(len(data)),
        "columns": int(data.shape[1] - 2),
        "date_min": data["기준년월일"].min(),
        "date_max": data["기준년월일"].max(),
        "unique_days": int(data["기준년월일"].nunique()),
        "sgg_codes": sorted(data["시군구코드"].unique().tolist()),
        "dong_count": int(data["행정동코드"].nunique()),
        "exact_duplicates": int(data.duplicated().sum()),
        "key_duplicates": int(data.duplicated(key).sum()),
        "null_cells": int(data.drop(columns=["KB_Tune_카테고리", "객단가"]).isna().sum().sum()),
        "negative_amount_rows": int((data["매출금액"] < 0).sum()),
        "negative_count_rows": int((data["매출건수"] < 0).sum()),
        "zero_amount_rows": int((data["매출금액"] == 0).sum()),
    }
    return category, quality


def profile_aihub() -> tuple[pd.DataFrame, dict]:
    usecols = ["기준년월", "발급회원번호", "이용금액_업종기준", *AIHUB_COLUMNS]
    frames = []
    with ZipFile(AIHUB) as archive:
        for member in archive.namelist():
            with archive.open(member) as source:
                frame = pd.read_csv(source, nrows=AIHUB_SAMPLE_ROWS, usecols=usecols)
            frames.append(frame)
    panel = pd.concat(frames, ignore_index=True)
    amount_columns = ["이용금액_업종기준", *AIHUB_COLUMNS]
    counts = panel.groupby("발급회원번호")["기준년월"].nunique()
    complete_ids = counts[counts == len(frames)].index
    complete = panel[panel["발급회원번호"].isin(complete_ids)].copy()
    complete[amount_columns] = complete[amount_columns].clip(lower=0)

    rows = []
    for column, category in AIHUB_COLUMNS.items():
        wide = complete.pivot(index="발급회원번호", columns="기준년월", values=column)
        adjacent = [wide.iloc[:, i].corr(wide.iloc[:, i + 1])
                    for i in range(wide.shape[1] - 1)]
        log_values = np.log1p(complete[column])
        temp = complete.assign(log_value=log_values)
        person_mean = temp.groupby("발급회원번호").log_value.mean()
        person_var = temp.groupby("발급회원번호").log_value.var()
        between = float(person_mean.var())
        within = float(person_var.mean())
        rows.append({
            "카테고리": category,
            "원본컬럼": column,
            "인접월_상관평균": float(np.nanmean(adjacent)),
            "로그금액_ICC근사": between / max(between + within, 1e-9),
            "0원비율": float((complete[column] == 0).mean()),
            "양수금액_중앙값": float(complete.loc[complete[column] > 0, column].median()),
        })
    total = complete.pivot(index="발급회원번호", columns="기준년월", values="이용금액_업종기준")
    total_corr = [total.iloc[:, i].corr(total.iloc[:, i + 1])
                  for i in range(total.shape[1] - 1)]
    quality = {
        "sample_rows_per_month": AIHUB_SAMPLE_ROWS,
        "sample_rows": int(len(panel)),
        "sample_people": int(panel["발급회원번호"].nunique()),
        "months": sorted(panel["기준년월"].astype(int).unique().tolist()),
        "complete_panel_people": int(len(complete_ids)),
        "duplicate_person_month": int(panel.duplicated(["발급회원번호", "기준년월"]).sum()),
        "null_cells": int(panel[amount_columns].isna().sum().sum()),
        "negative_cells": int((panel[amount_columns] < 0).sum().sum()),
        "total_adjacent_correlation_mean": float(np.nanmean(total_corr)),
        "category_sum_to_total_median_ratio": float(
            panel[list(AIHUB_COLUMNS)].sum(axis=1)
            .div(panel["이용금액_업종기준"].replace(0, np.nan)).median()
        ),
    }
    return pd.DataFrame(rows), quality


def main() -> None:
    regional, regional_quality = profile_regional()
    aihub, aihub_quality = profile_aihub()
    calibration = {
        "regional_ticket_median": {
            row.KB_Tune_카테고리: round(float(row.객단가_중앙값), 2)
            for row in regional.itertuples()
        },
        "aihub_total_persistence": aihub_quality["total_adjacent_correlation_mean"],
        "aihub_category_persistence": {
            row.카테고리: round(float(row.인접월_상관평균), 6)
            for row in aihub.itertuples()
        },
        "aihub_category_icc": {
            row.카테고리: round(float(row.로그금액_ICC근사), 6)
            for row in aihub.itertuples()
        },
        "usage_guardrail": "분포 보정 전용. 개인별 주간 정답 또는 실사용 성능 근거로 사용 금지.",
    }

    OUT.mkdir(parents=True, exist_ok=True)
    regional.to_csv(OUT / "regional_category_profile.csv", index=False)
    aihub.to_csv(OUT / "aihub_persistence_profile.csv", index=False)
    (OUT / "calibration.json").write_text(
        json.dumps(calibration, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    report = f"""# 로컬 소비데이터 품질·활용 범위

## 판정

- 경기 카드소비데이터: **객단가 분포 보정에만 사용 가능**. 하루·한 시군구라 주기와 개인화를 검증할 수 없음.
- AI Hub 금융 합성데이터: **개인 성향 지속성 시뮬레이션에 사용 가능**. 합성자료라 실사용 성능 근거로 사용 불가.

## 경기 카드소비데이터

- 원본: `{REGIONAL}`
- 행/열: {regional_quality['rows']:,}행 × {regional_quality['columns']}열
- 기간: {regional_quality['date_min']}~{regional_quality['date_max']} ({regional_quality['unique_days']}일)
- 시군구 코드: {', '.join(regional_quality['sgg_codes'])}, 행정동 {regional_quality['dong_count']}개
- 정확 중복 {regional_quality['exact_duplicates']}건, 후보키 중복 {regional_quality['key_duplicates']}건
- 결측 셀 {regional_quality['null_cells']}개, 음수 금액 {regional_quality['negative_amount_rows']}행

{regional.to_markdown(index=False, floatfmt='.2f')}

## AI Hub 카드 월 집계 표본

- 원본: `{AIHUB}`
- 월별 앞 {AIHUB_SAMPLE_ROWS:,}명 × 6개월 = {aihub_quality['sample_rows']:,}행
- 완전 패널 {aihub_quality['complete_panel_people']:,}명, 개인×월 중복 {aihub_quality['duplicate_person_month']}건
- 총액 인접월 상관 평균: {aihub_quality['total_adjacent_correlation_mean']:.3f}
- 세부 카테고리 합/업종기준 총액 중앙 비율: {aihub_quality['category_sum_to_total_median_ratio']:.3f}

{aihub.to_markdown(index=False, floatfmt='.3f')}

## 데이터 품질 위험

1. **높음** — 경기 데이터는 단 하루여서 날짜 발생·주기·8주 학습곡선을 만들 수 없음.
2. **높음** — AI Hub 자료는 합성자료이며 2018년 6개월 월 집계다. 주간 발생일 예측의 실제 근거가 아님.
3. **중간** — AI Hub 세부 카테고리 합은 업종기준 총액의 일부만 설명한다. 총액과 세부 합을 같은 분모로 혼용하면 안 됨.
4. **중간** — 3만 명은 파일 앞부분의 동일 ID 표본이다. 전체 모집단 대표 표본이라고 주장할 수 없음.

## 다음 실험 사용 규칙

- 경기 데이터: 카페·외식·생활·자기관리의 금액 중앙값과 폭만 생성기 사전분포에 반영.
- AI Hub: 개인별 지속 성향의 존재를 표현하는 보수적 파라미터에만 반영.
- 원자료의 높은 상관을 그대로 복사하지 않고 축소 적용하며, 적용값을 결과 보고서에 공개.
- 모델 학습/평가 사용자는 계속 완전 분리하고, 미래 피드백은 질문 선택 뒤에만 생성.
"""
    (OUT / "results.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
