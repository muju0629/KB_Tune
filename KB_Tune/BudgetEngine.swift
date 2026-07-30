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

    // σ 는 상수가 아니다. 상수로 두면 월초와 월말의 불확실성이 같아진다 —
    // 남은 일수가 31일일 때와 3일일 때 오차가 같을 수는 없다.
    // 아래 값과 spendSigma 식은 backend/app/engine/probability.py 와 동일하다.
    static let amountLogSD = 0.40               // 건당 금액의 로그 표준편차 (AI Hub 분산분해)
    static let discretionaryRate = 1.0          // 일정 밖 지출 발생률(건/일)
    static let rateCV = 1.0                     // 그 발생률 자체의 불확실성 (= 거의 모른다)
    static let maxConfidence = 97               // 모델이 담지 못하는 예외 지출이 있어 상한을 둔다

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

    static func spentToDate(in days: [PlanDay], asOfDay: Int? = nil) -> Int {
        let referenceDay = asOfDay ?? today
        let month = DemoClock.range(of: DemoClock.month(of: referenceDay))
        return days.filter { month.contains($0.dayNumber) && $0.dayNumber < referenceDay }
            .reduce(0) { $0 + $1.spendTotal }
    }
    /// 이번 주에 아직 남아 있는 확정 일정
    static func committedThisWeek(in days: [PlanDay], asOfDay: Int? = nil) -> Int {
        let referenceDay = asOfDay ?? today
        let week = DemoClock.weekRange(containing: referenceDay)
        return days.filter { week.contains($0.dayNumber) && $0.dayNumber >= referenceDay }
            .reduce(0) { $0 + $1.spendTotal }
    }
    /// 오늘부터 월말까지 남은 확정 일정
    static func committedFuture(in days: [PlanDay], asOfDay: Int? = nil) -> Int {
        let referenceDay = asOfDay ?? today
        let month = DemoClock.range(of: DemoClock.month(of: referenceDay))
        return days.filter { month.contains($0.dayNumber) && $0.dayNumber >= referenceDay }
            .reduce(0) { $0 + $1.spendTotal }
    }

    /// 남은 확정 지출의 제곱합. σ 계산에 쓴다 — 분산은 금액의 제곱에 비례한다.
    ///
    /// 백엔드는 일정 단위로 더하고 여기서는 날짜 단위로 더한다. 한 날짜에 금액이 있는
    /// 일정이 둘 이상이면 값이 갈리는데, 현재 캘린더는 그런 날이 없어 일치한다.
    static func committedFutureSumSq(in days: [PlanDay], asOfDay: Int? = nil) -> Double {
        let referenceDay = asOfDay ?? today
        let month = DemoClock.range(of: DemoClock.month(of: referenceDay))
        return days.filter { month.contains($0.dayNumber) && $0.dayNumber >= referenceDay }
            .reduce(0.0) { $0 + pow(Double($1.spendTotal), 2) }
    }

    /// 남은 지출의 표준편차. 확정 일정의 금액 오차 + 일정 밖 지출의 발생 불확실성.
    ///
    ///     Var = Σ 일정금액² · (exp(s²) − 1)
    ///         + E[X]² · (t · exp(s²) + t² · CV²)
    ///
    /// 둘째 항의 t² 때문에 기간이 길어질수록 불확실성이 제곱으로 커진다.
    static func spendSigma(committedSumSq: Double, daysLeft: Double,
                           _ d: SpendDirection) -> Double {
        let s2 = amountLogSD * amountLogSD
        var variance = committedSumSq * (exp(s2) - 1)
        variance += discretionaryVariance(daysLeft: daysLeft, d)
        return variance.squareRoot()
    }

    /// 일정 밖 지출의 분산.
    ///
    /// 두 근사 중 **큰 쪽**을 쓴다. 합성으로 교체하지 않는 이유가 있다.
    ///
    /// 카테고리별 사후분포 합성은 **탐지된 반복 패턴만** 설명한다. 편의점·교통·일회성
    /// 지출처럼 패턴으로 안 잡히는 돈을 보지 못한다. 지금 캘린더 밖 패턴은 장보기
    /// 하나뿐이라 합성 σ 가 37,289원인데 닫힌 공식은 81,011원이다. 그냥 갈아끼우면
    /// 불확실성이 절반으로 줄고 달성 확률이 부풀려진다 — 관측하지 않은 지출에 대한
    /// 불확실성을 줄일 근거는 없다.
    ///
    /// 그래서 합성은 **하한을 올리는 역할**만 한다. 패턴이 쌓여 설명되는 분산이
    /// 무지 기준선을 넘으면 그때 합성이 이긴다. 지금은 닫힌 공식이 이기고, 그게 맞다.
    ///
    /// 백엔드는 요청에 실려온 값만 보므로 늘 닫힌 공식을 쓴다.
    static func discretionaryVariance(daysLeft: Double, _ d: SpendDirection) -> Double {
        let s2 = amountLogSD * amountLogSD
        let perEvent = discretionaryDaily * discretionaryFactor(d) / discretionaryRate
        let t = discretionaryRate * daysLeft
        let ignorance = pow(perEvent, 2) * (t * exp(s2) + t * t * rateCV * rateCV)

        guard let empirical = SpendHistory.offCalendarVariance(days: daysLeft) else {
            return ignorance
        }
        // 소비방향은 재량지출의 크기를 조절한다. 분산은 크기의 제곱에 비례한다.
        return max(ignorance, empirical * pow(discretionaryFactor(d), 2))
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
                            committedSumSq: Double? = nil,
                            extraCommitted: Int = 0,
                            income: Int = income,
                            savingsGoal: Int = savingsGoal,
                            asOfDay: Int? = nil) -> Int {
        let referenceDay = asOfDay ?? today
        let monthRange = DemoClock.range(of: DemoClock.month(of: referenceDay))
        let daysLeft = Double(monthRange.upperBound - referenceDay + 1)
        let discretionary = discretionaryDaily * daysLeft * discretionaryFactor(d)
        let committed = Double((committedFuture ?? Self.committedFuture(in: seed)) + extraCommitted)
        let mu = committed + discretionary
        let remaining = remainingBudget(income: income, savingsGoal: savingsGoal, spentToDate: spentToDate)

        // 검토 중인 일정도 금액 오차를 갖는다 — 평균에만 넣고 분산에서 빼면 안 된다.
        let sumSq = (committedSumSq ?? Self.committedFutureSumSq(in: seed, asOfDay: referenceDay))
            + pow(Double(extraCommitted), 2)
        let sigma = spendSigma(committedSumSq: sumSq, daysLeft: daysLeft, d)

        let z = (Double(remaining) - mu) / sigma
        let cdf = 0.5 * (1 + erf(z / 2.0.squareRoot()))
        return min(Int((cdf * 100).rounded()), maxConfidence)
    }
}
