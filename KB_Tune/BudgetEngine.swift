//
//  BudgetEngine.swift
//  KB_Tune
//
//  결정론적 예산 엔진 (백엔드 app/engine 의 Swift 포트).
//  백엔드가 없을 때 앱이 오프라인으로 같은 숫자를 계산하는 폴백이자,
//  앱에도 실제 금융 로직이 있음을 보장한다(UI 전용 아님).
//
//  숫자는 여기서 계산하고, 문장·판단은 백엔드의 Claude가 담당한다.
//

import Foundation

enum BudgetEngine {

    // 성제의 2026년 7월 캘린더 기준. 고정비·단건 지출은 본인 확인값, 수입·저축은 데모 가정.
    static let income = 2_200_000               // 미확인 — 데모 가정(설정에서 수정)
    static let fixed = 435_000                  // 통신 7.5 + 교통 15 + 유류 6 + 구독 3 + 청약 10 + 보험 2 (확인값)
    static let savingsGoal = 800_000            // 미확인 — 데모 가정
    static let candidateAmount = 0              // 미확정 일정은 기본 계산에서 제외
    static let discretionaryDaily = 7_500.0     // 일정 밖 소액지출 데모 가정
    static let sigma = 100_000.0                // 추정 오차를 넉넉히 반영

    /// 오늘 — 앱을 켤 때 실제 날짜에서 읽는다.
    static var today: Int { DemoClock.today }

    // 일정비는 **지금 화면에 있는 캘린더**에서 계산한다.
    // 고정된 시드에서 계산하면 사용자가 일정을 지우거나 시간을 바꿔도 금액이 그대로라
    // "지웠는데 왜 안 줄지?"가 된다. 그래서 AppModel 이 자기 calendarDays 에서 뽑아 넘긴다.
    //
    // 시드 기준 값은 호출부가 값을 안 넘겼을 때의 기본값으로만 남긴다.
    private static let seed = AppModel.makeCalendar()

    /// 오늘이 든 달의 범위. 예산은 달 단위라 8월 일정이 7월 계산에 섞이면 안 된다.
    static var thisMonth: ClosedRange<Int> { DemoClock.range(of: DemoClock.month(of: today)) }

    /// 오늘 이전에 이미 쓴 일정비 (기본값 — 보통은 AppModel 이 실제 값을 넘긴다)
    static var variableSpentToDate: Int { spentToDate(in: seed) }

    static func spentToDate(in days: [PlanDay]) -> Int {
        days.filter { thisMonth.contains($0.dayNumber) && $0.dayNumber < today }
            .reduce(0) { $0 + $1.spendTotal }
    }
    /// 이번 주에 아직 남아 있는 확정 일정
    static func committedThisWeek(in days: [PlanDay]) -> Int {
        let week = DemoClock.weekRange(containing: today)
        return days.filter { week.contains($0.dayNumber) && $0.dayNumber >= today }
            .reduce(0) { $0 + $1.spendTotal }
    }
    /// 오늘부터 월말까지 남은 확정 일정
    static func committedFuture(in days: [PlanDay]) -> Int {
        days.filter { thisMonth.contains($0.dayNumber) && $0.dayNumber >= today }
            .reduce(0) { $0 + $1.spendTotal }
    }

    /// 다음 달로 넘어가는 할부 잔액 (기획 보고서 7.3 '카드 결제예정액').
    ///
    /// 일시불은 쓴 시점에 이미 일정비로 잡혀 있어 여기서 또 빼면 이중차감이 된다.
    /// 할부만 "이번 달 소비엔 안 잡혔는데 다음 달 카드값으로 나갈 돈"이라 따로 차감한다.
    static var installmentCarryover: Int { BillingCycle.summary().carryover }

    // 소비 방향 계수(위험 성향)
    static func weeklyFactor(_ d: SpendDirection) -> Double {
        switch d { case .reduce: 0.86; case .maintain: 1.00; case .increase: 1.18 }
    }
    static func discretionaryFactor(_ d: SpendDirection) -> Double {
        switch d { case .reduce: 0.60; case .maintain: 1.00; case .increase: 1.35 }
    }

    static func disposableMonth(income: Int = income,
                                savingsGoal: Int = savingsGoal) -> Int {
        income - fixed - savingsGoal
    }

    /// 이번 달 남은 예산. 할부 이월분은 다음 달 카드값으로 이미 예약된 돈이라 여기서 뺀다.
    /// - spentToDate: 오늘 이전에 쓴 일정비. 안 넘기면 시드 기준값.
    static func remainingBudget(income: Int = income,
                                savingsGoal: Int = savingsGoal,
                                spentToDate: Int? = nil) -> Int {
        disposableMonth(income: income, savingsGoal: savingsGoal)
            - (spentToDate ?? variableSpentToDate) - installmentCarryover
    }

    static var remainingWeeks: Int { max(1, Int(ceil(Double(thisMonth.upperBound - today + 1) / 7.0))) }

    /// 이번 주 사용 가능액 = 주예산 × 방향계수 − 이번 주 확정지출
    /// - extraCommitted: 아직 캘린더에 넣지 않은 후보 일정(영향 미리보기용).
    ///   이미 캘린더에 있는 일정은 committedThisWeek 에 들어가므로 여기 또 넣으면 이중계산이다.
    static func weeklyAvailable(_ d: SpendDirection,
                                spentToDate: Int? = nil,
                                committedThisWeek: Int? = nil,
                                extraCommitted: Int = 0,
                                income: Int = income,
                                savingsGoal: Int = savingsGoal) -> Int {
        let remaining = remainingBudget(income: income, savingsGoal: savingsGoal, spentToDate: spentToDate)
        let base = Double(remaining) / Double(remainingWeeks)
        let committed = (committedThisWeek ?? Self.committedThisWeek(in: seed)) + extraCommitted
        return max(0, Int((base * weeklyFactor(d)).rounded()) - committed)
    }

    /// 적금 목표 달성 확률 — 정규근사(백엔드 몬테카를로와 ±1%p 이내).
    static func probability(_ d: SpendDirection,
                            spentToDate: Int? = nil,
                            committedFuture: Int? = nil,
                            extraCommitted: Int = 0,
                            income: Int = income,
                            savingsGoal: Int = savingsGoal) -> Int {
        let daysLeft = Double(thisMonth.upperBound - today + 1)
        let discretionary = discretionaryDaily * daysLeft * discretionaryFactor(d)
        let committed = Double((committedFuture ?? Self.committedFuture(in: seed)) + extraCommitted)
        let mu = committed + discretionary
        let remaining = remainingBudget(income: income, savingsGoal: savingsGoal, spentToDate: spentToDate)
        let z = (Double(remaining) - mu) / sigma
        let cdf = 0.5 * (1 + erf(z / 2.0.squareRoot()))
        return Int((cdf * 100).rounded())
    }
}
