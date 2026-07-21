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

    // 데모 페르소나(김민지) — 백엔드 data.py 와 동일.
    static let income = 800_000
    static let fixed = 130_000                 // 통신 55 + 교통 60 + 구독 15
    static let savingsGoal = 200_000
    static let variableSpentToDate = 270_000   // 7/1~20 실제 가변지출
    static let committedThisWeek = 48_000       // 팀플 8 + 동아리 25 + 영화 15
    static let committedFuture = 78_000         // 확정된 미래 일정(이번주+다음주)
    static let candidateAmount = 40_000         // 생일파티 2차(후보/위험)
    static let daysInMonth = 31
    static let today = 21
    static let discretionaryDaily = 5_500.0     // 과거 소액 재량지출 일평균
    static let sigma = 80_000.0                 // 월 가변지출 표준편차

    // 소비 방향 계수(위험 성향)
    static func weeklyFactor(_ d: SpendDirection) -> Double {
        switch d { case .reduce: 0.86; case .maintain: 1.00; case .increase: 1.18 }
    }
    static func discretionaryFactor(_ d: SpendDirection) -> Double {
        switch d { case .reduce: 0.60; case .maintain: 1.00; case .increase: 1.35 }
    }

    static var disposableMonth: Int { income - fixed - savingsGoal }        // 470,000
    static var remainingBudget: Int { disposableMonth - variableSpentToDate } // 200,000
    static var remainingWeeks: Int { Int(ceil(Double(daysInMonth - today + 1) / 7.0)) } // 2

    /// 이번 주 사용 가능액 = 주예산 × 방향계수 − 이번 주 확정지출
    /// - extraCommitted: 새로 추가하려는 일정의 예상 지출(영향 시뮬레이션용)
    static func weeklyAvailable(_ d: SpendDirection, includeCandidate: Bool = false,
                                extraCommitted: Int = 0) -> Int {
        let base = Double(remainingBudget) / Double(remainingWeeks)
        let committed = committedThisWeek + (includeCandidate ? candidateAmount : 0) + extraCommitted
        return Int((base * weeklyFactor(d)).rounded()) - committed
    }

    /// 적금 목표 달성 확률 — 정규근사(백엔드 몬테카를로와 ±1%p 이내).
    /// - extraCommitted: 새 일정을 반영했을 때의 확률을 보려면 금액을 넣는다.
    static func probability(_ d: SpendDirection, includeCandidate: Bool = false,
                            extraCommitted: Int = 0) -> Int {
        let daysLeft = Double(daysInMonth - today + 1)
        let discretionary = discretionaryDaily * daysLeft * discretionaryFactor(d)
        let committed = Double(committedFuture + (includeCandidate ? candidateAmount : 0) + extraCommitted)
        let mu = committed + discretionary
        let z = (Double(remainingBudget) - mu) / sigma
        let cdf = 0.5 * (1 + erf(z / 2.0.squareRoot()))
        return Int((cdf * 100).rounded())
    }
}
