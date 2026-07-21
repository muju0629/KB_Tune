"""데모 페르소나: 김민지(22, 대학 3학년, 카페 알바).

숫자는 앱의 데모 화면과 일치하도록 보정되어 있으나, 결과값을 하드코딩한 게 아니라
아래 '입력'으로부터 engine 이 계산한다. (income/fixed/savings/history → weekly_available·probability)
"""
from .models import FixedCost, PlannedEvent, Profile, Transaction

PROFILE = Profile(
    name="민지",
    age=22,
    monthly_income=800_000,          # 카페 알바
    savings_goal=200_000,
    fixed_costs=[
        FixedCost(name="통신", amount=55_000),
        FixedCost(name="교통", amount=60_000),
        FixedCost(name="구독", amount=15_000),
    ],
    direction="maintain",
    protected_categories=["술·모임"],
)

# 최근 3개월(4~6월) 거래 단위 히스토리 — 반복 패턴 탐지·예상지출 추정의 원천.
# (월별로 동일 주기를 갖도록 구성: 구독=매월 15일, 교통=매월 5일, 동아리 회식=매월 18일 …)
_MONTHLY_PATTERN: list[tuple[int, str, int, str]] = [
    # (일자, 카테고리, 금액, 가맹점)
    (3, "카페", 8_000, "스타벅스 강남R점"),
    (5, "교통", 30_000, "티머니 충전"),
    (7, "외식", 17_500, "김밥천국"),
    (9, "배달", 10_000, "배달의민족"),
    (10, "카페", 8_000, "투썸플레이스"),
    (14, "외식", 17_500, "한솥도시락"),
    (15, "구독", 15_000, "넷플릭스"),
    (17, "카페", 8_000, "메가커피"),
    (18, "술·모임", 25_000, "동아리 회식"),
    (20, "쇼핑", 40_000, "올리브영"),
    (21, "외식", 17_500, "맘스터치"),
    (23, "배달", 10_000, "쿠팡이츠"),
    (24, "카페", 8_000, "이디야커피"),
    (26, "술·모임", 35_000, "포차 모임"),
    (28, "외식", 17_500, "본죽"),
]


def _build_history() -> list[Transaction]:
    out: list[Transaction] = []
    for month in (4, 5, 6):
        for day, cat, amt, merchant in _MONTHLY_PATTERN:
            out.append(Transaction(category=cat, amount=amt, day=day, month=month, merchant=merchant))
    return out


TRANSACTIONS_HISTORY = _build_history()

# 카테고리별 월평균 — 히스토리에서 파생(단일 출처).
HISTORY_MONTHLY: dict[str, int] = {}
for _t in TRANSACTIONS_HISTORY:
    HISTORY_MONTHLY[_t.category] = HISTORY_MONTHLY.get(_t.category, 0) + _t.amount // 3
HISTORY_MONTHLY = dict(sorted(HISTORY_MONTHLY.items(), key=lambda kv: -kv[1]))

# 이번 달(7월) 1~20일 실제 가변지출 — 합계 270,000원.
TRANSACTIONS_THIS_MONTH = [
    Transaction(category="외식", amount=48_000, day=3),
    Transaction(category="술·모임", amount=42_000, day=5),
    Transaction(category="카페", amount=21_000, day=7),
    Transaction(category="쇼핑", amount=55_000, day=9),
    Transaction(category="배달", amount=14_000, day=12),
    Transaction(category="외식", amount=32_000, day=14),
    Transaction(category="술·모임", amount=38_000, day=16),
    Transaction(category="카페", amount=12_000, day=18),
    Transaction(category="교통", amount=8_000, day=19),
]  # 합계 270,000

# 앞으로의 일정(오늘~월말). confirmed=확정, protected=보호 소비.
# 생일파티 2차는 후보(미확정) — 위험 판정 대상.
UPCOMING_EVENTS = [
    PlannedEvent(title="팀플 스터디", category="카페", amount=8_000, day=22),
    PlannedEvent(title="동아리 정기모임", category="술·모임", amount=25_000, day=23, protected=True),
    PlannedEvent(title="영화 관람", category="여가", amount=15_000, day=25),
    PlannedEvent(title="생일파티 2차", category="술·모임", amount=40_000, day=24, confirmed=False),
    # 다음 주 확정 지출(추정)
    PlannedEvent(title="교재 구입", category="쇼핑", amount=30_000, day=28),
]

DAYS_IN_MONTH = 31
