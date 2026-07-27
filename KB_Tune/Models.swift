//
//  Models.swift
//  KB_Tune
//
//  데이터 모델 + 앱 상태.
//  캘린더 기반 페르소나: 성제 · 대학생 · 인포스탁 인턴 · AI 연구 병행
//  기준일은 앱을 켤 때 실제 날짜에서 읽는다(DemoClock) · 일정기간 2026년 7월
//

import SwiftUI
import Combine

// MARK: - 소비 방향

enum SpendDirection: String, CaseIterable, Identifiable {
    case reduce, maintain, increase
    var id: String { rawValue }

    var label: String {
        switch self {
        case .reduce: "줄이기"
        case .maintain: "유지"
        case .increase: "늘리기"
        }
    }

    /// 이번 주 사용 가능액
    var budget: Int {
        BudgetEngine.weeklyAvailable(self)
    }

    /// 적금 목표 달성 확률(%)
    var probability: Int {
        BudgetEngine.probability(self)
    }

    /// 에이전트 조언 문구
    var note: String {
        switch self {
        case .reduce: "더 필요한 소비는 그대로 두고, 추가 약속만 가볍게 잡아요."
        case .maintain: "출근비와 확정 일정을 반영한 현재 계획이에요."
        case .increase: "추가 약속 여유를 늘리는 대신 저축 목표 확률은 낮아져요."
        }
    }
}

// MARK: - 금액 상태 (기획 보고서 7.2 — 확정 지출 / 예약 예산 / 패턴 예상)

/// 확정 지출: 이미 결제했거나 반드시 납부(가용금액에서 전액 차감)
/// 예약 예산: 캘린더 일정에 배정했지만 아직 결제 전인 가상 예약(전액 예약, 실제 출금 없음)
/// 패턴 예상: 캘린더엔 없지만 반복될 가능성이 있는 지출(범위로만 표시, upcomingSpends 목록)
enum SpendState: String {
    case confirmed, reserved, pattern

    var label: String {
        switch self {
        case .confirmed: "확정"
        case .reserved: "예약"
        case .pattern: "예상"
        }
    }
}

// MARK: - 하루 일정(타임테이블)

struct DayEvent: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var startHour: Double     // 19.0 = 19:00, 17.5 = 17:30
    var duration: Double      // 시간 단위
    var amount: Int           // 0 = 무지출 일정(수업·알바 등)
    var estimateLow: Int? = nil
    var estimateHigh: Int? = nil
    var estimateBasis: String? = nil
    var isPredicted: Bool = false   // AI가 과거 이력으로 금액을 채운 일정
    var isProtected: Bool = false
    var riskNote: String? = nil     // 위험 일정 한 줄 요약
    var riskDetail: String? = nil   // 상세 설명 + 추천
    var category: String = "기타"    // 결제 업종(무엇에 썼는지) — 식사·카페·쇼핑·교통 등
    var purpose: String? = nil      // 생활 목적(왜 썼는지) — 데이트·가족·모임·업무·공부 등
    var state: SpendState = .confirmed
    /// 기기 캘린더에 쓴 이벤트의 식별자. 앱이 직접 쓴 일정만 값이 있고,
    /// 지울 때 이 값이 있는 경우에만 기기 캘린더에서도 지운다 —
    /// 사용자가 캘린더 앱에서 만든 일정을 앱이 함부로 지우면 안 되기 때문이다.
    var calendarEventID: String? = nil

    var amountLow: Int { estimateLow ?? amount }
    var amountHigh: Int { estimateHigh ?? amount }
    /// 확인된 금액에는 '예상'을 붙이지 않는다 — 예측이거나 범위가 있을 때만.
    var isEstimated: Bool { isPredicted || amountLow != amountHigh }
}

struct PlanDay: Identifiable {
    let id = UUID()
    var weekday: String       // "월"
    var dateLabel: String     // "7/20"
    var dayNumber: Int        // 20
    var isToday: Bool = false
    var events: [DayEvent] = []

    var spendTotal: Int { events.reduce(0) { $0 + $1.amount } }
    var spendLow: Int { events.reduce(0) { $0 + $1.amountLow } }
    var spendHigh: Int { events.reduce(0) { $0 + $1.amountHigh } }
    var hasSpend: Bool { events.contains { $0.amount > 0 } }
    /// 하루 합계에 예측이 섞여 있으면 '예상'으로 표기한다.
    var hasEstimate: Bool { events.contains { $0.amount > 0 && $0.isEstimated } }
    var hasRisk: Bool { events.contains { $0.riskNote != nil } }
}

/// 주간 지출 카드용 파생 아이템
struct WeekSpendItem: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var dayLabel: String      // "금 7/24"
    var dayNumber: Int
    var amount: Int
    var amountLow: Int
    var amountHigh: Int
    var isEstimated: Bool
    var isProtected: Bool
    var isRisky: Bool
    var purpose: String?
    var state: SpendState
}

// MARK: - 기기 캘린더 행(EventKit 연동용)

struct PlanEvent: Identifiable {
    let id = UUID()
    var title: String
    var amount: Int
    var symbol: String
    var dayLabel: String
    var featured: Bool = false
    var fromDeviceCalendar: Bool = false
    var dayOfMonth: Int = 0     // 기기 캘린더에서 가져온 일정의 '일'
}

// MARK: - 소비 카테고리

struct SpendCategory: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let monthly: Int          // 캘린더 기반 7월 월간 추정
}

// MARK: - 앱 상태

/// 하단 내비게이션 탭 — 화면 간 프로그래밍 방식 이동에 쓴다.
enum MainTab: Hashable { case weekly, chat, analysis, products }

final class AppModel: ObservableObject {
    // 페르소나
    let userName = "성제"
    let userAge: Int? = nil   // 캘린더만으로 나이는 확정하지 않음
    let userRole = "대학생 · 인포스탁 인턴"

    @Published var hasOnboarded = false
    @Published var selectedTab: MainTab = .weekly
    /// 이미 선택된 주간 탭을 다시 누르면 계획 화면을 처음 상태(주간 메인)로 되돌리는 신호.
    @Published private(set) var planResetToken = 0
    func resetPlanView() { planResetToken += 1 }

    // 온보딩 입력값 (페르소나 기본값)
    @Published var usesDemoData = true
    @Published var monthlyIncome = 2_200_000  // 풀타임 인턴 근무 기준 추정값
    @Published var savingsGoal = 800_000
    // '나한테 더 필요한 소비' — 관계·행사성 취향은 예산을 조정할 때 줄이지 않는다.
    // hobbies 에서 파생하므로 설정에서 취향을 바꾸면 즉시 따라온다.
    static let protectableTags: Set<String> = ["데이트", "가족", "모임"]
    var protectedTags: Set<String> {
        let p = hobbies.intersection(Self.protectableTags)
        return p.isEmpty ? ["데이트", "가족"] : p
    }
    /// "가족·데이트" 처럼 문장에 끼워 쓰는 목록 문자열
    var protectedList: String { protectedTags.sorted().joined(separator: "·") }
    @Published var hobbies: Set<String> = ["영화", "전시", "가족", "데이트"]

    /// 취향 → 상품 매칭 태그 변환 (Products.matchTags와 맞춤)
    var interestTags: Set<String> {
        var tags: Set<String> = []
        for h in hobbies {
            switch h {
            case "음식", "카페": tags.insert("외식")
            case "술", "모임", "데이트": tags.insert("모임")
            case "가족": tags.insert("가족")
            default: tags.insert("취미")
            }
        }
        return tags
    }

    // 계획 상태. 방향은 온보딩에서 묻지 않고 앱이 정한다 — 목표 확률만 보면 알 수 있는 걸
    // 사용자에게 되묻지 않기 위해서다. 정한 뒤엔 설정에서 언제든 바꿀 수 있다.
    @Published var direction: SpendDirection = .maintain

    /// 저축 목표가 위태로우면 '줄이기'로 시작한다.
    /// '늘리기'는 앱이 먼저 권하지 않는다 — 더 쓰라고 떠미는 금융 조언은 하지 않는다.
    static let atRiskProbability = 60

    func decideDirection() {
        direction = probability(for: .maintain) < Self.atRiskProbability ? .reduce : .maintain
    }

    /// 방향을 왜 그렇게 잡았는지 한 줄로 설명한다.
    var directionReason: String {
        let p = probability
        switch direction {
        case .reduce:
            return "저축 목표 달성 확률이 \(p)%라 '줄이기'로 시작할게요. 설정에서 바꿀 수 있어요."
        case .maintain:
            return "저축 목표 달성 확률이 \(p)%라 '유지'로 시작할게요. 설정에서 바꿀 수 있어요."
        case .increase:
            return "'늘리기'로 계획했어요. 목표 확률은 \(p)%예요."
        }
    }

    // 예산 계산의 입력은 전부 지금 화면의 캘린더에서 나온다.
    // 그래야 일정을 추가하든 지우든 시간을 바꾸든 금액이 곧바로 따라 움직인다.
    var spentToDate: Int { BudgetEngine.spentToDate(in: calendarDays) }
    var committedThisWeek: Int { BudgetEngine.committedThisWeek(in: calendarDays) }
    var committedFuture: Int { BudgetEngine.committedFuture(in: calendarDays) }

    var weeklyBudget: Int { weeklyBudget(for: direction) }
    var probability: Int { probability(for: direction) }

    /// 이번 주에 더 쓸 수 있는 금액 — 주차 장부에서 읽는다.
    /// 소비 방향은 그 위에 성향 계수로 얹는다(줄이기면 보수적으로 잡아준다).
    /// - extraCommitted: 아직 캘린더에 넣지 않은 후보 일정(추가 화면의 영향 미리보기용).
    func weeklyBudget(for direction: SpendDirection, extraCommitted: Int = 0) -> Int {
        guard let week = thisWeekBudget else { return 0 }
        // 배분이 음수면(지난주에 넘겨 씀) 이번 주에 나눠 쓸 몫 자체가 없다.
        // 음수에 성향 계수를 곱하면 '줄이기'가 더 큰 금액이 되는 뒤집힘이 생기므로 먼저 자른다.
        let base = max(0, week.allowance)
        let scaled = Int((Double(base) * BudgetEngine.weeklyFactor(direction)).rounded())
        return max(0, scaled - week.plannedSpend - extraCommitted)
    }
    func probability(for direction: SpendDirection, extraCommitted: Int = 0) -> Int {
        BudgetEngine.probability(direction,
                                 spentToDate: spentToDate,
                                 committedFuture: committedFuture,
                                 extraCommitted: extraCommitted,
                                 income: monthlyIncome,
                                 savingsGoal: savingsGoal)
    }

    var remainingBudget: Int {
        BudgetEngine.remainingBudget(income: monthlyIncome, savingsGoal: savingsGoal,
                                     spentToDate: spentToDate)
    }

    // MARK: 주차별 예산 장부 (이월)

    /// 이 달에 쓸 수 있는 돈 — 고정비·적금·다음 달로 넘어갈 할부를 뺀 나머지.
    /// 할부를 여기서 빼두면 주차 배분이 그만큼 줄어, 다음 달 카드값이 미리 반영된다.
    var monthlyDisposable: Int {
        monthlyIncome - BudgetEngine.fixed - savingsGoal - BudgetEngine.installmentCarryover
    }

    /// 지난달에서 넘어온 금액. 데모는 7월부터 시작해 0이지만,
    /// 8월 계획을 볼 때는 7월 마지막 주 잔액이 여기로 들어온다.
    @Published var openingRollover = 0

    var weekBudgets: [WeekBudget] {
        var spendByWeek: [Int: Int] = [:]
        for (i, range) in WeekLedger.weekRanges().enumerated() {
            spendByWeek[i] = calendarDays
                .filter { range.contains($0.dayNumber) }
                .reduce(0) { $0 + $1.spendTotal }
        }
        return WeekLedger.build(disposable: monthlyDisposable,
                                spendByWeek: spendByWeek,
                                openingRollover: openingRollover)
    }

    var thisWeekBudget: WeekBudget? {
        weekBudgets.first { $0.days.contains(todayDayNumber) }
    }

    /// 이번 달이 끝나면 다음 달로 넘어갈 금액.
    var closingRollover: Int { WeekLedger.closingRollover(weekBudgets) }

    /// 다음 달 첫 주가 어떻게 시작되는지.
    /// 고정비·적금은 그대로 두고, 이번 달에 남긴 금액만 얹어서 보여준다.
    var nextMonthFirstWeek: WeekBudget {
        WeekLedger.nextMonthOpening(
            disposable: monthlyIncome - BudgetEngine.fixed - savingsGoal,
            carriedIn: closingRollover)
    }

    var nextMonthLabel: String { "\(DemoClock.demoMonth + 1)월" }

    /// 지금 여력으로 매달 넣을 수 있는 적금액. 남은 예산에서 다음 달 할부까지 뺀 뒤
    /// 만원 단위로 내림한다 — 딱 맞게 잡으면 한 번만 흔들려도 못 넣게 된다.
    var suggestedSavingsAmount: Int {
        let room = remainingBudget - BudgetEngine.installmentCarryover
        return max(0, (room / 2 / 10_000) * 10_000)
    }

    /// KB Pay 이용내역 연결 여부(온보딩에서 동의). 데모라 실제 계정에 접속하지는 않는다.
    @Published var kbPayLinked = false

    // MARK: 신용카드 청구 (기획 보고서 7.3 '카드 결제예정액')

    /// 이번 이용기간 요약 — 얼마 썼고, 다음 결제일에 얼마가 빠지고, 얼마가 다음 달로 밀리는지.
    var billing: BillingSummary { BillingCycle.summary(today: todayDayNumber) }

    /// 이용기간 마감일에 쓴 돈은 다음 결제일에, 하루만 넘겨 쓰면 그 다음 결제일에 청구된다.
    var isBillingCloseDay: Bool { todayDayNumber == BillingCycle.closingDay }

    /// 챗봇에서 적금을 물어보고 상품 화면으로 넘어왔는지. 넘어간 화면이 소비하고 되돌린다.
    @Published var wantsSavings = false

    var referenceDateLabel: String { DemoClock.fullLabel(of: todayDayNumber) }
    let analysisPeriod = "2026년 7월 캘린더"

    // MARK: 7월 캘린더 일정

    @Published var calendarDays: [PlanDay] = AppModel.makeJulyCalendar()
    var currentWeekRange: ClosedRange<Int> { DemoClock.weekRange(containing: todayDayNumber) }
    var week: [PlanDay] { calendarDays.filter { currentWeekRange.contains($0.dayNumber) } }

    /// 월요일 시작, 7월과 겹치는 주 단위 날짜 창. 각 주는 7칸(월~일)이고 7월 밖은 nil.
    /// 주간 날짜 스트립을 가로로 넘겨(3주차·4주차…) 보기 위한 창.
    var julyWeeks: [[Int?]] {
        var slots: [Int?] = Array(repeating: nil, count: firstWeekdayOffset)  // 월·화 빈칸
        slots += (1...daysInMonth).map { Optional($0) }
        while slots.count % 7 != 0 { slots.append(nil) }
        return stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
    }

    /// 오늘이 포함된 주의 인덱스 (0-based). "7월 N주차"의 N은 이 인덱스 + 1.
    var currentWeekIndex: Int {
        julyWeeks.firstIndex { $0.contains(todayDayNumber) } ?? 0
    }

    var weekSpendItems: [WeekSpendItem] {
        var items: [WeekSpendItem] = []

        for day in week {
            for event in day.events where event.amount > 0 {
                items.append(
                    WeekSpendItem(title: event.title, symbol: event.symbol,
                                  dayLabel: "\(day.weekday) \(day.dateLabel)",
                                  dayNumber: day.dayNumber,
                                  amount: event.amount,
                                  amountLow: event.amountLow,
                                  amountHigh: event.amountHigh,
                                  isEstimated: event.isEstimated,
                                  isProtected: event.isProtected,
                                  isRisky: event.riskNote != nil,
                                  purpose: event.purpose,
                                  state: event.state)
                )
            }
        }
        return items
    }

    /// 오늘 이후 남은 이번 주 지출 — 주간 합계(지나간 날 포함)와 구분해 쓴다.
    var remainingThisWeek: Int {
        week.filter { $0.dayNumber >= todayDayNumber }.reduce(0) { $0 + $1.spendTotal }
    }

    // MARK: 과거 이력 기반 예상 소비

    /// 이번 주 남은 기간에 주기가 돌아오는, 캘린더에 아직 없는 지출.
    /// 확정이 아니므로 예산 계산에는 넣지 않고 "반영하기"를 눌러야 일정이 된다.
    var upcomingSpends: [UpcomingSpend] {
        let titles = Set(week.flatMap(\.events).map(\.title))
        return SpendHistory.upcoming(from: todayDayNumber,
                                     to: currentWeekRange.upperBound,
                                     excludingTitles: titles)
            .filter { !dismissedPredictions.contains($0.pattern.key) }
    }

    /// 예상 소비를 다 더하면 이번 주 사용 가능액이 얼마나 남는지 — 미리보기용.
    var weeklyBudgetAfterPredictions: Int {
        max(0, weeklyBudget - upcomingSpends.reduce(0) { $0 + $1.amount })
    }

    /// 예상 소비가 예산을 넘는 금액(넘지 않으면 0)
    var predictedShortfall: Int {
        max(0, upcomingSpends.reduce(0) { $0 + $1.amount } - weeklyBudget)
    }

    @Published private(set) var dismissedPredictions: Set<String> = []

    /// 예상 소비를 실제 일정으로 확정한다.
    func acceptPrediction(_ spend: UpcomingSpend) {
        addEvent(title: spend.pattern.key, day: spend.expectedDay, amount: spend.amount,
                 category: spend.pattern.category, basis: spend.reason, predicted: true)
        dismissedPredictions.insert(spend.pattern.key)
    }

    /// 이번엔 안 쓸 것 같다고 표시 — 목록에서만 내린다.
    func dismissPrediction(_ spend: UpcomingSpend) {
        dismissedPredictions.insert(spend.pattern.key)
    }

    var plannedSpendTotal: Int { weekSpendItems.reduce(0) { $0 + $1.amount } }
    var plannedSpendLow: Int { weekSpendItems.reduce(0) { $0 + $1.amountLow } }
    var plannedSpendHigh: Int { weekSpendItems.reduce(0) { $0 + $1.amountHigh } }

    // MARK: 하루 마감 (기획 보고서 8.2)
    //
    // 실서비스에선 KB Pay 결제 기록으로 예약 지출의 실제 결제 여부를 자동으로 안다.
    // 카드 기록이 붙은 지출은 물어볼 필요 없이 확정되고,
    // '예정돼 있었는데 카드 기록이 없는' 지출만 남아 "현금으로 결제하셨나요?"라고 되묻는다.

    @Published private(set) var dailyCloseDismissed = false

    /// 카드 기록 없이 예정만 잡혀 있는 오늘 지출 — 현금 결제 여부를 되물어야 하는 항목.
    var todayCloseItems: [DayEvent] {
        guard let today = day(number: todayDayNumber) else { return [] }
        return today.events.filter { $0.amount > 0 && $0.state == .reserved }
    }

    /// 확인할 게 있는 날에만 카드를 띄운다 — 무조건 알림 금지.
    var shouldShowDailyClose: Bool { !dailyCloseDismissed && !todayCloseItems.isEmpty }

    /// paidCash=true: 현금으로 결제했다고 확인 → 예약을 확정 지출로 학습한다.
    /// paidCash=false: 아직 안 썼으니 예약 상태 그대로 두고 카드만 닫는다.
    func resolveDailyClose(paidCash: Bool) {
        if paidCash, let i = calendarDays.firstIndex(where: { $0.dayNumber == todayDayNumber }) {
            for j in calendarDays[i].events.indices where calendarDays[i].events[j].state == .reserved {
                calendarDays[i].events[j].state = .confirmed
            }
        }
        dailyCloseDismissed = true
    }

    /// 이번 주 위험 일정 (예산 초과)
    var riskyDay: PlanDay? { week.first { $0.hasRisk } }
    var riskyEvent: DayEvent? { riskyDay?.events.first { $0.riskNote != nil } }

    func day(number: Int) -> PlanDay? { calendarDays.first { $0.dayNumber == number } }

    // MARK: 일정 추가·조정 (AddEventView·위험카드에서 호출)

    /// 새 일정을 캘린더와 예산 계산에 함께 반영한다.
    /// 새로 추가하는 일정은 아직 결제 전이므로 기본 상태는 '예약 예산'이다(실제 출금 없음, 가용금액에서만 제외).
    func addEvent(title: String, day: Int, amount: Int, category: String,
                  basis: String?, predicted: Bool = false, startHour: Double? = nil,
                  riskNote: String? = nil, riskDetail: String? = nil,
                  purpose: String? = nil, state: SpendState = .reserved) {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == day }) else { return }
        // 사용자가 시간을 골랐으면 그 시각에, 아니면 겹치지 않는 빈 시간에 넣는다.
        let start = startHour ?? Self.freeSlot(after: calendarDays[i].events)
        let event = DayEvent(title: title, symbol: Self.symbol(for: category),
                             startHour: start, duration: 2, amount: amount,
                             estimateLow: amount, estimateHigh: amount,
                             estimateBasis: basis, isPredicted: predicted,
                             riskNote: riskNote, riskDetail: riskDetail,
                             category: category, purpose: purpose, state: state)
        calendarDays[i].events.append(event)
        calendarDays[i].events.sort { $0.startHour < $1.startHour }
        // 예산 계산은 calendarDays 에서 파생되므로 따로 합산해 둘 필요가 없다.
    }

    /// 일정을 지운다. 예산 계산은 캘린더에서 파생되므로 금액은 곧바로 따라 바뀐다.
    /// - Returns: 기기 캘린더에서도 지워야 할 이벤트 식별자(앱이 쓴 일정일 때만).
    @discardableResult
    func deleteEvent(_ event: DayEvent, on dayNumber: Int) -> String? {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == dayNumber }),
              let j = calendarDays[i].events.firstIndex(where: { $0.id == event.id }) else { return nil }
        let removed = calendarDays[i].events.remove(at: j)
        return removed.calendarEventID
    }

    /// 시작 시각을 옮긴다. 하루 안에서만 움직이므로 금액 합계는 그대로지만,
    /// 다른 일정과의 순서·겹침이 바뀌므로 정렬은 다시 한다.
    func updateEventTime(_ event: DayEvent, on dayNumber: Int, startHour: Double) {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == dayNumber }),
              let j = calendarDays[i].events.firstIndex(where: { $0.id == event.id }) else { return }
        calendarDays[i].events[j].startHour = max(0, min(startHour, 23.5))
        calendarDays[i].events.sort { $0.startHour < $1.startHour }
    }

    /// 금액을 고친다 — 예상액을 실제에 맞출 때.
    func updateEventAmount(_ event: DayEvent, on dayNumber: Int, amount: Int) {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == dayNumber }),
              let j = calendarDays[i].events.firstIndex(where: { $0.id == event.id }) else { return }
        calendarDays[i].events[j].amount = max(0, amount)
        calendarDays[i].events[j].estimateLow = max(0, amount)
        calendarDays[i].events[j].estimateHigh = max(0, amount)
    }

    /// 기기 캘린더에 쓴 뒤 돌려받은 식별자를 일정에 붙여둔다 — 나중에 지울 때 필요하다.
    func attachCalendarID(_ id: String, to event: DayEvent, on dayNumber: Int) {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == dayNumber }),
              let j = calendarDays[i].events.firstIndex(where: { $0.id == event.id }) else { return }
        calendarDays[i].events[j].calendarEventID = id
    }

    /// 위험 일정을 7일 뒤로 옮기고 경고를 지운다. 이번 주 부담에서 빠져 사용 가능액이 회복된다.
    func moveEventToNextWeek(_ event: DayEvent, from dayNumber: Int) {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == dayNumber }),
              let j = calendarDays[i].events.firstIndex(where: { $0.id == event.id }) else { return }
        var moved = calendarDays[i].events.remove(at: j)
        moved.riskNote = nil
        moved.riskDetail = nil

        let target = min(dayNumber + 7, daysInMonth)
        if let k = calendarDays.firstIndex(where: { $0.dayNumber == target }) {
            calendarDays[k].events.append(moved)
            calendarDays[k].events.sort { $0.startHour < $1.startHour }
        }
    }

    /// 위험을 감수하고 일정을 유지 — 경고 표시만 지운다(예산 부담은 그대로).
    func acceptRisk(of event: DayEvent, on dayNumber: Int) {
        guard let i = calendarDays.firstIndex(where: { $0.dayNumber == dayNumber }),
              let j = calendarDays[i].events.firstIndex(where: { $0.id == event.id }) else { return }
        calendarDays[i].events[j].riskNote = nil
        calendarDays[i].events[j].riskDetail = nil
    }

    /// 기존 일정과 겹치지 않는 시작 시각 (기본 19시, 막히면 마지막 일정 종료 후)
    static func freeSlot(after events: [DayEvent], preferred: Double = 19) -> Double {
        let overlaps = { (h: Double) in
            events.contains { h < $0.startHour + $0.duration && $0.startHour < h + 2 }
        }
        guard overlaps(preferred) else { return preferred }
        let end = events.map { $0.startHour + $0.duration }.max() ?? preferred
        return min(end, 21.5)   // 타임테이블은 24시까지만 그린다
    }

    /// 추정 카테고리 → 일정 아이콘
    static func symbol(for category: String) -> String {
        switch category {
        case "출근": "briefcase"
        case "경조사": "gift"
        case "데이트": "heart"
        case "가족": "house"
        case "자기관리": "cross.case"
        case "여가", "문화": "film"
        case "모임", "술·모임": "person.2"
        case "카페": "cup.and.saucer"
        case "외식": "fork.knife"
        case "쇼핑": "handbag"
        case "교통": "bus"
        // 카드내역 분류(LocalExtractor)에만 있는 카테고리 — 일정에는 없지만 이용내역 목록에 뜬다.
        case "배달": "takeoutbag.and.cup.and.straw"
        case "구독": "arrow.triangle.2.circlepath"
        case "건강": "cross.case"
        default: "calendar"
        }
    }

    // MARK: 월간 (2026년 7월)

    let monthLabel = "2026년 7월"
    let daysInMonth = DemoClock.daysInMonth
    let firstWeekdayOffset = 2        // 7/1 = 수요일 (월요일 시작 기준 빈칸 2)
    /// 앱을 켤 때 실제 날짜에서 읽는다. 세션 중엔 고정(달이 넘어가도 화면이 흔들리지 않게).
    let todayDayNumber = DemoClock.today
    var julyEstimateLow: Int { calendarDays.reduce(0) { $0 + $1.spendLow } }
    var julyEstimateHigh: Int { calendarDays.reduce(0) { $0 + $1.spendHigh } }
    var monthEndRemainingLow: Int {
        max(0, monthlyIncome - BudgetEngine.fixed - savingsGoal - julyEstimateHigh)
    }
    var monthEndRemainingHigh: Int {
        max(0, monthlyIncome - BudgetEngine.fixed - savingsGoal - julyEstimateLow)
    }

    // MARK: 7월 일정비 프로파일 (중간 추정값)

    // 합계 801,000 = julyEstimate (캘린더 합계와 일치해야 함 — 출근은 무지출이라 카테고리 없음)
    let spendProfile: [SpendCategory] = [
        SpendCategory(name: "경조사·쇼핑", symbol: "gift", monthly: 220_000),
        SpendCategory(name: "모임·식사", symbol: "person.2", monthly: 210_000),
        SpendCategory(name: "데이트·가족", symbol: "heart", monthly: 150_000),
        SpendCategory(name: "문화", symbol: "film", monthly: 78_000),
        SpendCategory(name: "학업·연구", symbol: "laptopcomputer", monthly: 73_000),
        SpendCategory(name: "건강·관리", symbol: "cross.case", monthly: 70_000),
    ]
    var spendMonthly: Int { spendProfile.reduce(0) { $0 + $1.monthly } }

    // MARK: 캘린더 원본을 앱 데모 데이터로 변환

    static func makeJulyCalendar() -> [PlanDay] {
        var events: [Int: [DayEvent]] = [:]

        func add(_ day: Int, _ title: String, symbol: String,
                 start: Double, duration: Double,
                 amount: Int = 0, low: Int? = nil, high: Int? = nil,
                 basis: String? = nil, protected: Bool = false,
                 category: String = "기타", purpose: String? = nil,
                 state: SpendState = .confirmed) {
            events[day, default: []].append(
                DayEvent(title: title, symbol: symbol,
                         startHour: start, duration: duration,
                         amount: amount,
                         estimateLow: low, estimateHigh: high,
                         estimateBasis: basis,
                         isProtected: protected,
                         category: category, purpose: purpose, state: state)
            )
        }

        let workDays: Set<Int> = [1, 2, 3, 6, 7, 8, 9, 10, 13, 14, 15, 16,
                                  20, 21, 22, 23, 24, 27, 28, 29, 30, 31]
        for day in workDays {
            // 점심은 비용이 들지 않고, 교통·유류비는 월 고정비에 있어 출근은 무지출 일정이다.
            add(day, "인포스탁 인턴", symbol: "building.2", start: 8.5, duration: 9)
        }

        add(1, "저녁", symbol: "fork.knife", start: 18, duration: 2,
            amount: 8_000, low: 8_000, high: 8_000, basis: "간단한 식사 기준",
            category: "외식", purpose: "개인 일정")
        add(2, "SensCoreAI 연구", symbol: "laptopcomputer", start: 19.5, duration: 1)
        add(2, "저녁", symbol: "fork.knife", start: 18.5, duration: 3,
            amount: 20_000, low: 20_000, high: 20_000, basis: "저녁·카페 1회 기준",
            category: "외식", purpose: "모임")
        add(3, "월급일", symbol: "banknote", start: 8, duration: 0.5)
        add(3, "해커톤 뒤풀이", symbol: "person.3", start: 19, duration: 3,
            amount: 40_000, low: 40_000, high: 40_000, basis: "저녁 모임 1회 기준",
            category: "술·모임", purpose: "모임")
        add(4, "정장 구매", symbol: "tshirt", start: 9, duration: 3,
            amount: 150_000, low: 150_000, high: 150_000, basis: "확인된 구매 금액",
            category: "쇼핑", purpose: "개인 일정")
        add(4, "교수님 결혼식", symbol: "rosette", start: 16.5, duration: 3.25,
            amount: 70_000, low: 70_000, high: 70_000, basis: "확인된 축의금·교통비",
            category: "경조사", purpose: "경조사")
        add(5, "자습", symbol: "book.closed", start: 17.5, duration: 3.5,
            amount: 8_000, low: 8_000, high: 8_000, basis: "식음료 1회 기준",
            category: "카페", purpose: "공부")
        add(6, "저녁·카공", symbol: "cup.and.saucer", start: 18, duration: 4,
            amount: 20_000, low: 20_000, high: 20_000, basis: "저녁 + 카페 기준",
            category: "카페", purpose: "공부")
        add(7, "SensCoreAI 연구", symbol: "laptopcomputer", start: 21.75, duration: 1,
            amount: 5_000, low: 5_000, high: 5_000, basis: "음료 1회 기준",
            category: "카페", purpose: "공부")
        add(8, "선우", symbol: "person.2", start: 18.5, duration: 2.5,
            amount: 25_000, low: 25_000, high: 25_000, basis: "저녁 약속 1회 기준",
            category: "외식", purpose: "모임")
        add(10, "데이트", symbol: "heart", start: 18, duration: 4,
            amount: 100_000, low: 100_000, high: 100_000, basis: "확인된 금액", protected: true,
            category: "데이트", purpose: "데이트")
        add(11, "마인드온", symbol: "person.crop.square", start: 11, duration: 1)
        add(11, "SOL TA", symbol: "person.2", start: 12, duration: 5,
            amount: 15_000, low: 15_000, high: 15_000, basis: "교통 + 식사 기준",
            category: "교통", purpose: "업무")
        add(12, "가족 식사", symbol: "house", start: 13, duration: 2,
            amount: 20_000, low: 20_000, high: 20_000, basis: "본인 몫 기준", protected: true,
            category: "외식", purpose: "가족")
        add(12, "데이트", symbol: "heart", start: 15, duration: 2.2,
            amount: 30_000, low: 30_000, high: 30_000, basis: "카페·데이트 기준", protected: true,
            category: "카페", purpose: "데이트")
        add(13, "규호 입대 전 저녁", symbol: "person.2", start: 18, duration: 3,
            amount: 30_000, low: 30_000, high: 30_000, basis: "저녁 모임 1회 기준",
            category: "외식", purpose: "모임")
        add(14, "국민카드 결제일", symbol: "creditcard", start: 8, duration: 0.5)
        add(14, "오디움 예약", symbol: "ticket", start: 14, duration: 1)
        add(15, "종현·한결", symbol: "person.2", start: 18, duration: 1.5,
            amount: 25_000, low: 25_000, high: 25_000, basis: "저녁 약속 1회 기준",
            category: "외식", purpose: "모임")
        add(16, "인포스탁 전사 회식", symbol: "person.3", start: 18, duration: 2.5,
            amount: 5_000, low: 5_000, high: 5_000, basis: "개인 교통비 기준",
            category: "교통", purpose: "업무")
        add(17, "제헌절 공부", symbol: "book.closed", start: 8.5, duration: 4.5)
        add(17, "한의원", symbol: "cross.case", start: 10, duration: 1,
            amount: 20_000, low: 20_000, high: 20_000, basis: "진료비 예상",
            category: "건강", purpose: "병원")
        add(17, "오디움·안성", symbol: "tram.fill", start: 13, duration: 4.75,
            amount: 40_000, low: 40_000, high: 40_000, basis: "왕복 교통 + 식사 기준",
            category: "교통", purpose: "여행")
        add(18, "공부", symbol: "book.closed", start: 11.5, duration: 6.5)
        add(18, "성창이와 저녁", symbol: "person.2", start: 18, duration: 2,
            amount: 25_000, low: 25_000, high: 25_000, basis: "저녁 약속 1회 기준",
            category: "외식", purpose: "모임")
        add(19, "호프 영화", symbol: "film", start: 10.25, duration: 2.75,
            amount: 18_000, low: 18_000, high: 18_000, basis: "영화 관람 1회 기준",
            category: "문화", purpose: "문화")
        add(19, "호프 무대인사", symbol: "theatermasks", start: 12.9, duration: 0.3)
        add(19, "밥", symbol: "fork.knife", start: 13.5, duration: 1,
            amount: 12_000, low: 12_000, high: 12_000, basis: "식사 1회 기준",
            category: "외식", purpose: "개인 일정")
        add(19, "아모레퍼시픽 미술관", symbol: "paintpalette", start: 15, duration: 2,
            amount: 20_000, low: 20_000, high: 20_000, basis: "관람 + 교통 기준",
            category: "문화", purpose: "문화")
        add(20, "레이저 제모 7회차", symbol: "face.smiling", start: 18, duration: 1,
            amount: 50_000, low: 50_000, high: 50_000, basis: "당일 결제 확인",
            category: "자기관리", purpose: "개인 일정")
        add(20, "SensCoreAI 연구", symbol: "laptopcomputer", start: 20, duration: 1,
            amount: 5_000, low: 5_000, high: 5_000, basis: "음료 1회 기준",
            category: "카페", purpose: "공부")
        add(21, "회의", symbol: "bubble.left.and.bubble.right", start: 21, duration: 1,
            basis: "별도 결제 없음")
        // 7/22 저녁 일정(미용실) — 아직 결제 전이라 '예약 예산' 상태로 둔다. 하루 마감에서 확인하면 확정으로 바뀐다.
        add(22, "와드", symbol: "scissors", start: 19, duration: 1,
            amount: 40_000, low: 40_000, high: 40_000, basis: "사용자가 확인한 금액",
            category: "자기관리", purpose: "개인 일정", state: .reserved)
        add(24, "인포스탁 월급날", symbol: "banknote", start: 8, duration: 0.5)
        // 데모 시나리오 — 이번 주에 새로 잡은 저녁 약속 2건.
        add(30, "윤혁이랑 피자 (이태원)", symbol: "fork.knife", start: 19, duration: 2,
            amount: 52_000, low: 52_000, high: 52_000, basis: "사용자가 확인한 금액",
            category: "외식", purpose: "모임", state: .reserved)
        add(31, "크리에이터 킥오프 저녁 (강남)", symbol: "person.3", start: 19, duration: 2,
            amount: 28_000, low: 28_000, high: 28_000, basis: "사용자가 확인한 금액",
            category: "외식", purpose: "모임", state: .reserved)

        let today = DemoClock.today
        return (1...DemoClock.daysInMonth).map { day in
            PlanDay(weekday: DemoClock.weekday(of: day),
                    dateLabel: "7/\(day)", dayNumber: day,
                    isToday: day == today,
                    events: events[day, default: []].sorted { $0.startHour < $1.startHour })
        }
    }
}

// 온보딩 통합 서베이 후보 (좋아하는 것 = 나한테 더 필요한 소비 후보)
let keepCandidates: [(tag: String, label: String, symbol: String)] = [
    ("데이트", "데이트", "heart"),
    ("모임", "모임·친구", "person.2"),
    ("연구", "연구·공부", "laptopcomputer"),
    ("영화", "영화", "film"),
    ("카페", "카페", "cup.and.saucer"),
    ("음식", "맛집·음식", "fork.knife"),
    ("여행", "여행", "airplane"),
    ("운동", "운동", "figure.run"),
    ("전시", "전시·공연", "paintpalette"),
    ("게임", "게임", "gamecontroller"),
    ("가족", "가족", "house"),
]
