"""LLM 이 만든 검색어를 검색 엔진에 넘기기 전에 검사한다.

LLM 에는 가명처리된 문장이 가지만 검색 엔진에는 그것도 보내지 않기로 했다. 이유는
상대의 성격이 다르기 때문이다 — LLM 제공자는 무보존·학습 미사용을 계약으로 묶을 수
있지만, 검색 엔진은 질의가 어디에 얼마나 남는지 통제할 방법이 없다.

문제는 도구를 부르는 게 LLM 이라는 점이다. "제주도 3박4일 여행 경비"처럼 사용자 문장을
그대로 질의에 옮겨 담을 수 있다. 그래서 **모델을 믿지 않고 모델의 출력을 검사한다.**

검사 규칙은 하나다. 질의에 들어 있는 낱말은 전부 아래 셋 중 하나여야 한다.
  · 코드에 적어 둔 허용 낱말(카테고리·소비 어휘)
  · 숫자와 단위(3박, 2명, 1인)
  · 조사·접속사 같은 기능어
사용자 문장에서 온 낱말이 하나라도 섞이면 통째로 버린다. 버려도 답을 못 하는 게 아니라
앱이 만든 안전한 질의로 대신한다.
"""
from __future__ import annotations

import re

# 한글 음절 영역. 경계 글자를 직접 적지 않고 코드포인트로 만든다.
HANGUL_RANGE = f"{chr(0xAC00)}-{chr(0xD7A3)}"

# 검색어에 나와도 되는 낱말. 전부 코드에 적힌 것이고 사용자 입력에서 오지 않는다.
ALLOWED = {
    # 일정 유형
    "여행", "국내", "해외", "숙박", "항공", "렌터카", "숙소", "펜션", "호텔", "모텔",
    "외식", "식사", "점심", "저녁", "카페", "커피", "모임", "회식", "술자리",
    "데이트", "기념일", "가족", "경조사", "축의금", "부의금", "결혼식", "돌잔치",
    "문화", "영화", "공연", "전시", "콘서트", "관람료",
    "여가", "노래방", "볼링", "당구", "골프",
    "자기관리", "미용실", "네일", "피부관리", "헬스", "필라테스", "요가",
    "병원", "치과", "한의원", "약국", "안경", "진료비",
    "쇼핑", "의류", "신발", "가방", "화장품",
    "교통", "택시", "기차", "고속버스",
    "학원", "수강료", "교재", "스터디",
    "반려동물", "동물병원", "미용",
    # 무엇을 묻는지
    "평균", "비용", "경비", "가격", "요금", "예산", "지출", "시세",
    "인당", "한국", "얼마",
}

# 숫자 + 단위. "3박", "2명", "4일" 같은 구조 신호는 사용자 문장에서 왔더라도
# 개인을 가리키지 않는다. 형식이 맞을 때만 통과시킨다.
NUMERIC = re.compile(r"^\d{1,3}(박|일|명|인|월|시간|개|주)?$")

# 조사·접속사. 낱말을 나눌 때 붙어 남는 것들이라 따로 허용한다.
FUNCTION_WORDS = {"의", "은", "는", "이", "가", "을", "를", "와", "과", "에", "에서",
                  "으로", "로", "및", "당", "짜리", "정도", "쯤"}

MAX_LENGTH = 60

_SPLIT = re.compile(f"[^0-9A-Za-z{HANGUL_RANGE}]+")
_NUM_UNIT_RUN = re.compile(r"(\d{1,3}(박|일|명|인|주)?)+$")


def split_tokens(query: str) -> list[str]:
    """검색어를 낱말로 쪼갠다. 한글·영문·숫자 덩어리만 남긴다."""
    return [t for t in _SPLIT.split(query) if t]


def _acceptable(token: str) -> bool:
    if token in ALLOWED or token in FUNCTION_WORDS:
        return True
    if NUMERIC.match(token):
        return True
    # "3박4일" 처럼 붙어 온 경우 — 숫자와 단위만으로 이루어졌으면 통과.
    if _NUM_UNIT_RUN.fullmatch(token):
        return True
    # 허용 낱말에 조사가 붙은 경우("여행은") — 앞부분이 허용 낱말이면 통과.
    return any(token.startswith(word) and len(token) - len(word) <= 2 for word in ALLOWED)


def rejected_tokens(query: str) -> list[str]:
    """허용 목록에 없는 낱말. 비어 있으면 내보내도 되는 질의다."""
    return [t for t in split_tokens(query) if not _acceptable(t)]


def is_safe(query: str) -> bool:
    return bool(query.strip()) and len(query) <= MAX_LENGTH and not rejected_tokens(query)
