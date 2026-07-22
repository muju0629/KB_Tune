//
//  KB_TuneTests.swift
//  KB_TuneTests
//
//  Created by Sungjeh Yoon on 7/21/26.
//

import Testing
@testable import KB_Tune

struct KB_TuneTests {

    @Test func budgetUsesCalendarPersona() {
        // 07-22 확인값: 고정비 435,000(통신7.5+교통15+유류6+구독3+청약10+보험2) · 일정비 761,000 · 와드 40,000
        #expect(BudgetEngine.fixed == 435_000)
        #expect(BudgetEngine.remainingBudget() == 204_000)
        #expect(BudgetEngine.weeklyAvailable(.maintain) == 62_000)
        #expect(BudgetEngine.weeklyAvailable(.reduce) == 47_720)
        #expect(BudgetEngine.weeklyAvailable(.increase) == 80_360)
        #expect(BudgetEngine.probability(.maintain) == 81)
    }

    @Test func julyCalendarTotalsAreConfirmedValues() {
        let model = AppModel()

        #expect(model.calendarDays.count == 31)
        #expect(model.todayDayNumber == 22)
        // 금액이 모두 확정돼 low == high — 범위가 사라진다.
        #expect(model.julyEstimateLow == 801_000)
        #expect(model.julyEstimateHigh == 801_000)
        #expect(model.plannedSpendLow == 95_000)
        #expect(model.plannedSpendHigh == 95_000)
        #expect(model.monthEndRemainingLow == 164_000)
        #expect(model.monthEndRemainingHigh == 164_000)
    }

    @Test func internshipCostsNothingAndLaserIsConfirmed() {
        let model = AppModel()
        let internships = model.calendarDays.flatMap(\.events).filter { $0.title == "인포스탁 인턴" }
        let laser = model.day(number: 20)?.events.first { $0.title == "레이저 제모 7회차" }

        // 점심 무비용 + 교통·유류는 월 고정비 → 출근 일정은 전부 0원
        #expect(internships.count == 22)
        #expect(internships.reduce(0) { $0 + $1.amount } == 0)
        #expect(laser?.amount == 50_000)
        #expect(laser?.amountLow == 50_000)
        #expect(laser?.amountHigh == 50_000)
    }

    // MARK: 과거 이력 기반 예측

    @Test func recurrenceDetectionFindsCadenceAndAverage() {
        let byKey = Dictionary(uniqueKeysWithValues: SpendHistory.patterns.map { ($0.key, $0) })

        let ward = try! #require(byKey["와드"])
        #expect(ward.cadenceDays == 42)          // 5/16 → 6/27
        #expect(ward.cadenceLabel == "6주")
        #expect(ward.avgAmount == 40_000)

        let coupang = try! #require(byKey["쿠팡 장보기"])
        #expect(coupang.cadenceDays == 10)
        #expect(coupang.avgAmount == 35_000)
        #expect(coupang.regularity > 0.6)        // 주기가 규칙적이라 주기를 근거로 쓴다

        let date = try! #require(byKey["주말 데이트"])
        #expect(date.cadenceDays == 14)
        #expect(date.avgAmount == 70_000)
    }

    @Test func predictionExplainsItselfInKorean() {
        let p = try! #require(SpendHistory.predict(title: "와드"))
        #expect(p.amount == 40_000)
        #expect(p.reason == "성제님의 와드 주기는 6주 정도였어요.")
        #expect(p.detail.contains("5월 16일"))

        // 일정 추정기가 규칙보다 이력을 먼저 쓴다
        let e = EventEstimator.estimate("와드")
        #expect(e.method == "history")
        #expect(e.amount == 40_000)
    }

    @Test func upcomingSpendsCoverCalendarGaps() {
        let model = AppModel()
        let keys = model.upcomingSpends.map(\.pattern.key)

        // 캘린더에 없지만 주기가 이번 주에 돌아오는 지출
        #expect(keys.contains("쿠팡 장보기"))
        #expect(keys.contains("주말 데이트"))
        // 이번 주 캘린더에 이미 있는 '와드'는 중복 제안하지 않는다
        #expect(!keys.contains("와드"))

        // 예측은 확정이 아니므로 기본 예산을 건드리지 않는다
        #expect(model.weeklyBudget == 62_000)
        #expect(model.weeklyBudgetAfterPredictions < model.weeklyBudget)
    }

    @Test func acceptingPredictionMovesMoneyOutOfBudget() {
        let model = AppModel()
        let before = model.weeklyBudget
        let spend = try! #require(model.upcomingSpends.first { $0.pattern.key == "쿠팡 장보기" })

        model.acceptPrediction(spend)

        #expect(model.weeklyBudget == before - spend.amount)
        #expect(!model.upcomingSpends.contains { $0.pattern.key == "쿠팡 장보기" })
        let added = model.day(number: spend.expectedDay)?.events.first { $0.title == "쿠팡 장보기" }
        #expect(added?.isPredicted == true)      // 예측 금액이라 '예상'으로 표시된다
        #expect(added?.amount == 35_000)
    }

    @Test func confirmedAmountsAreNotLabelledAsEstimates() {
        let model = AppModel()
        let ward = model.day(number: 22)?.events.first { $0.title == "와드" }
        // 사용자가 확인한 금액 → low == high 이고 예측도 아니므로 '예상' 접두어가 붙지 않는다
        #expect(ward?.isEstimated == false)
    }

    @Test func confirmedWardAndFreeMeetingAreSingleSourceOfTruth() {
        let model = AppModel()
        let meeting = model.day(number: 21)?.events.first { $0.title == "회의" }
        let ward = model.day(number: 22)?.events.first { $0.title == "와드" }

        #expect(meeting?.amount == 0)
        #expect(ward?.amount == 40_000)
        #expect(EventEstimator.estimate("회의").amount == 0)
        #expect(EventEstimator.estimate("와드").amount == 40_000)
    }

}
