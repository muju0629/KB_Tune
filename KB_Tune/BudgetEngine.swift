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
    static let daysInMonth = DemoClock.daysInMonth
    static let discretionaryDaily = 7_500.0     // 일정 밖 소액지출 데모 가정
    static let sigma = 100_000.0                // 추정 오차를 넉넉히 반영

    /// 오늘 — 앱을 켤 때 실제 날짜에서 읽는다.
    static var today: Int { DemoClock.today }

    // 아래 세 값은 예전엔 7/22 기준 상수였다. 오늘이 실시간으로 움직이니 시드 캘린더에서
    // 직접 계산한다 — 그래야 날짜가 바뀌어도 화면 숫자와 엔진이 어긋나지 않는다.
    // (앱에서 새로 추가한 일정은 여기 없고 extraCommitted 로 따로 얹는다.)
    private static let seed = AppModel.makeJulyCalendar()

    /// 오늘 이전에 이미 쓴 일정비
    static var variableSpentToDate: Int {
        seed.filter { $0.dayNumber < today }.reduce(0) { $0 + $1.spendTotal }
    }
    /// 이번 주에 아직 남아 있는 확정 일정
    static var committedThisWeek: Int {
        let week = DemoClock.weekRange(containing: today)
        return seed.filter { week.contains($0.dayNumber) && $0.dayNumber >= today }
            .reduce(0) { $0 + $1.spendTotal }
    }
    /// 오늘부터 월말까지 남은 확정 일정
    static var committedFuture: Int {
        seed.filter { $0.dayNumber >= today }.reduce(0) { $0 + $1.spendTotal }
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
    static func remainingBudget(income: Int = income,
                                savingsGoal: Int = savingsGoal) -> Int {
        disposableMonth(income: income, savingsGoal: savingsGoal)
            - variableSpentToDate - installmentCarryover
    }

    static var remainingWeeks: Int { Int(ceil(Double(daysInMonth - today + 1) / 7.0)) } // 2

    /// 이번 주 사용 가능액 = 주예산 × 방향계수 − 이번 주 확정지출
    /// - extraCommitted: 새로 추가하려는 일정의 예상 지출(영향 시뮬레이션용)
    static func weeklyAvailable(_ d: SpendDirection, includeCandidate: Bool = false,
                                extraCommitted: Int = 0,
                                income: Int = income,
                                savingsGoal: Int = savingsGoal) -> Int {
        let base = Double(remainingBudget(income: income, savingsGoal: savingsGoal)) / Double(remainingWeeks)
        let committed = committedThisWeek + (includeCandidate ? candidateAmount : 0) + extraCommitted
        return max(0, Int((base * weeklyFactor(d)).rounded()) - committed)
    }

    /// 적금 목표 달성 확률 — 정규근사(백엔드 몬테카를로와 ±1%p 이내).
    /// - extraCommitted: 새 일정을 반영했을 때의 확률을 보려면 금액을 넣는다.
    static func probability(_ d: SpendDirection, includeCandidate: Bool = false,
                            extraCommitted: Int = 0,
                            income: Int = income,
                            savingsGoal: Int = savingsGoal) -> Int {
        let daysLeft = Double(daysInMonth - today + 1)
        let discretionary = discretionaryDaily * daysLeft * discretionaryFactor(d)
        let committed = Double(committedFuture + (includeCandidate ? candidateAmount : 0) + extraCommitted)
        let mu = committed + discretionary
        let z = (Double(remainingBudget(income: income, savingsGoal: savingsGoal)) - mu) / sigma
        let cdf = 0.5 * (1 + erf(z / 2.0.squareRoot()))
        return Int((cdf * 100).rounded())
    }
}
