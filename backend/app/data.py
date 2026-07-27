"""2026년 7월 캘린더를 바탕으로 만든 성제의 데모 데이터.

금액은 2026-07-22 성제가 직접 확인한 값(단건 지출·고정비)과 데모 가정(수입·저축)이 섞여 있다.
출근은 점심이 무비용이고 교통·유류비가 월 고정비에 있어 일정 비용 0원으로 계산한다.
금액이 없는 급여일·카드 결제일(7/14)은 계산에서 제외한다.
"""
from .models import FixedCost, PlannedEvent, Profile, Transaction

PROFILE = Profile(
    role="대학생 · 인포스탁 인턴",
    monthly_income=2_200_000,       # 근무 일정 기준 데모 가정값(설정에서 수정 가능)
    savings_goal=800_000,
    fixed_costs=[                   # 07-22 본인 확인값, 합계 435,000
        FixedCost(name="통신", amount=75_000),
        FixedCost(name="교통", amount=150_000),
        FixedCost(name="유류비", amount=60_000),
        FixedCost(name="구독·OTT", amount=30_000),
        FixedCost(name="청약", amount=100_000),
        FixedCost(name="보험", amount=20_000),
    ],
    direction="maintain",
    protected_categories=["데이트", "가족"],
)


def _estimated(category: str, amount: int, day: int, title: str,
               low: int | None = None, high: int | None = None) -> Transaction:
    """캘린더 일정 한 건을 예상 지출 입력으로 바꾼다."""
    return Transaction(
        category=category,
        amount=amount,
        day=day,
        month=7,
        merchant=title,
        estimate_low=amount if low is None else low,
        estimate_high=amount if high is None else high,
    )


# 7월 1~21일 일정비. 합계 761,000원(전 항목 확정 — 범위 없음).
# 출근은 점심 무비용 + 교통·유류 고정비 반영으로 0원.
TRANSACTIONS_THIS_MONTH = [
    _estimated("출근", 0, 1, "인포스탁 인턴"),
    _estimated("업무·학업", 8_000, 1, "SensCoreAI 연구"),
    _estimated("출근", 0, 2, "인포스탁 인턴"),
    _estimated("외식", 20_000, 2, "저녁"),
    _estimated("출근", 0, 3, "인포스탁 인턴"),
    _estimated("모임", 40_000, 3, "해커톤 뒤풀이"),
    _estimated("쇼핑", 150_000, 4, "정장 구입"),
    _estimated("경조사", 70_000, 4, "교수님 결혼식"),
    _estimated("업무·학업", 8_000, 5, "자습"),
    _estimated("출근", 0, 6, "인포스탁 인턴"),
    _estimated("외식", 20_000, 6, "저녁·카페"),
    _estimated("출근", 0, 7, "인포스탁 인턴"),
    _estimated("업무·학업", 5_000, 7, "SensCoreAI 연구"),
    _estimated("출근", 0, 8, "인포스탁 인턴"),
    _estimated("모임", 25_000, 8, "선우 약속"),
    _estimated("출근", 0, 9, "인포스탁 인턴"),
    _estimated("출근", 0, 10, "인포스탁 인턴"),
    _estimated("데이트", 100_000, 10, "데이트"),
    _estimated("업무·학업", 15_000, 11, "마인드온·SOL TA"),
    _estimated("가족", 20_000, 12, "가족 식사"),
    _estimated("데이트", 30_000, 12, "데이트"),
    _estimated("출근", 0, 13, "인포스탁 인턴"),
    _estimated("모임", 30_000, 13, "입대 전 저녁"),
    _estimated("출근", 0, 14, "인포스탁 인턴"),
    _estimated("출근", 0, 15, "인포스탁 인턴"),
    _estimated("모임", 25_000, 15, "친구 저녁"),
    _estimated("출근", 0, 16, "인포스탁 인턴"),
    _estimated("모임", 5_000, 16, "인포스탁 전체 회식"),
    _estimated("자기관리", 20_000, 17, "한의원"),
    _estimated("문화·이동", 40_000, 17, "오디움·안성 이동"),
    _estimated("모임", 25_000, 18, "친구 저녁"),
    _estimated("문화", 50_000, 19, "영화·무대인사·미술관"),
    _estimated("출근", 0, 20, "인포스탁 인턴"),
    _estimated("업무·학업", 5_000, 20, "SensCoreAI 연구"),
    _estimated("자기관리", 50_000, 20, "레이저 제모"),
    _estimated("출근", 0, 21, "인포스탁 인턴"),
    _estimated("업무·학업", 0, 21, "회의"),
]

# 7월 22~31일 확정 일정. 금액 있는 항목은 와드 40,000원뿐(이번 주=월말까지 40,000원).
# 캘린더에 금액이 보이지 않는 급여일·카드 결제일은 포함하지 않았다.
UPCOMING_EVENTS = [
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=22),
    PlannedEvent(title="와드", category="업무·학업", amount=40_000, day=22),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=23),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=24),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=27),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=28),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=29),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=30),
    PlannedEvent(title="인포스탁 인턴", category="출근", amount=0, day=31),
]

# 일정 추정 기능의 개인화 기준. 실제 거래 이력이 아니라 위 캘린더에서 확인된 유형별 표본이다.
TRANSACTIONS_HISTORY = TRANSACTIONS_THIS_MONTH

# 카테고리별 7월 1~21일 일정 예상액(분석 화면용 단일 출처).
HISTORY_MONTHLY: dict[str, int] = {}
for _t in TRANSACTIONS_HISTORY:
    HISTORY_MONTHLY[_t.category] = HISTORY_MONTHLY.get(_t.category, 0) + _t.amount
HISTORY_MONTHLY = dict(sorted(HISTORY_MONTHLY.items(), key=lambda kv: -kv[1]))

DAYS_IN_MONTH = 31
