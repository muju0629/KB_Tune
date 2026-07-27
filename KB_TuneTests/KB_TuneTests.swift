//
//  KB_TuneTests.swift
//  KB_TuneTests
//
//  Created by Sungjeh Yoon on 7/21/26.
//

import Testing
@testable import KB_Tune

/// 오늘 날짜가 실시간이라(DemoClock) 날짜에 기댄 기대값은 기준일을 고정해야 한다.
/// 전역 상태를 건드리므로 직렬 실행한다.
@Suite(.serialized)
struct KB_TuneTests {

    /// 기준일 7/22로 고정한 뒤 본문을 실행하고 원래대로 되돌린다.
    private func onJuly22<T>(_ body: () throws -> T) rethrows -> T {
        DemoClock.fixedToday = 22
        defer { DemoClock.fixedToday = nil }
        return try body()
    }

    @Test func budgetUsesCalendarPersona() {
        onJuly22 {
            let model = AppModel()
            // 07-22 확인값: 고정비 435,000(통신7.5+교통15+유류6+구독3+청약10+보험2) · 일정비 761,000 · 와드 40,000
            #expect(BudgetEngine.fixed == 435_000)
            #expect(model.spentToDate == 761_000)
            #expect(model.committedThisWeek == 40_000)
            // 965,000 − 일정비 761,000 − 할부 이월 90,590
            #expect(model.remainingBudget == 113_410)
            #expect(model.weeklyBudget(for: .maintain) == 16_705)
            #expect(model.weeklyBudget(for: .maintain) < model.weeklyBudget(for: .increase))
            #expect(model.weeklyBudget(for: .reduce) < model.weeklyBudget(for: .maintain))
        }
    }

    /// 일정을 지우면 예산이 그 자리에서 따라 바뀌어야 한다.
    /// 예전엔 고정된 시드에서 계산해 지워도 금액이 그대로였다 — 그 회귀를 막는다.
    @Test func deletingEventFreesBudgetImmediately() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let before = model.weeklyBudget
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.deleteEvent(ward, on: 22)

            #expect(model.committedThisWeek == 0)
            #expect(model.weeklyBudget == before + ward.amount)
            #expect(model.day(number: 22)?.events.contains { $0.title == "와드" } == false)
        }
    }

    /// 금액을 고치면 차액만큼만 움직인다.
    @Test func editingAmountMovesBudgetByTheDifference() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let before = model.weeklyBudget
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.updateEventAmount(ward, on: 22, amount: ward.amount - 10_000)

            #expect(model.weeklyBudget == before + 10_000)
        }
    }

    /// 시간만 옮기면 금액 합계는 그대로다.
    @Test func movingEventTimeKeepsTheTotal() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let before = model.weeklyBudget
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.updateEventTime(ward, on: 22, startHour: 21)

            #expect(model.weeklyBudget == before)
            #expect(model.day(number: 22)?.events.first { $0.title == "와드" }?.startHour == 21)
        }
    }

    /// 할부는 다음 달 카드값으로 이미 예약된 돈이라 이번 달 예산에서 빠진다.
    @Test func installmentCarryoverReducesBudget() {
        onJuly22 {
            let carryover = BudgetEngine.installmentCarryover
            #expect(carryover == 90_590)
            // 이월분이 없다면 그만큼 더 쓸 수 있었다
            let model = AppModel()
            #expect(BudgetEngine.disposableMonth() - model.spentToDate
                    - carryover == model.remainingBudget)
        }
    }

    @Test func julyCalendarTotalsAreConfirmedValues() {
        let model = onJuly22 { AppModel() }

        #expect(model.calendarDays.count == 31)
        #expect(model.todayDayNumber == 22)
        // 금액이 모두 확정돼 low == high — 범위가 사라진다.
        // 881,000 = 기존 확인값 801,000 + 데모 일정(7/30 피자 52,000 · 7/31 킥오프 28,000)
        #expect(model.julyEstimateLow == 881_000)
        #expect(model.julyEstimateHigh == 881_000)
        #expect(model.plannedSpendLow == 95_000)
        #expect(model.plannedSpendHigh == 95_000)
        // 월말 여유는 캘린더 합계에서 파생 — 일정이 늘면 같은 폭으로 줄어야 한다.
        #expect(model.monthEndRemainingLow
                == model.monthlyIncome - BudgetEngine.fixed - model.savingsGoal - model.julyEstimateHigh)
        #expect(model.monthEndRemainingHigh == model.monthEndRemainingLow)
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
        onJuly22 {
            let model = AppModel()
            let keys = model.upcomingSpends.map(\.pattern.key)

            // 캘린더에 없지만 주기가 이번 주에 돌아오는 지출
            #expect(keys.contains("쿠팡 장보기"))
            #expect(keys.contains("주말 데이트"))
            // 이번 주 캘린더에 이미 있는 '와드'는 중복 제안하지 않는다
            #expect(!keys.contains("와드"))

            // 예측은 확정이 아니므로 기본 예산을 건드리지 않는다
            #expect(model.weeklyBudget == 16_705)
            #expect(model.weeklyBudgetAfterPredictions < model.weeklyBudget)
        }
    }

    @Test func acceptingPredictionMovesMoneyOutOfBudget() {
        let model = onJuly22 { AppModel() }
        let spend = onJuly22 { try! #require(model.upcomingSpends.first { $0.pattern.key == "쿠팡 장보기" }) }

        onJuly22 {
            let before = model.weeklyBudget
            model.acceptPrediction(spend)
            #expect(model.weeklyBudget == max(0, before - spend.amount))
        }
        #expect(!model.upcomingSpends.contains { $0.pattern.key == "쿠팡 장보기" })
        let added = model.day(number: spend.expectedDay)?.events.first { $0.title == "쿠팡 장보기" }
        #expect(added?.isPredicted == true)      // 예측 금액이라 '예상'으로 표시된다
        #expect(added?.amount == 35_000)
    }

    // MARK: 신용카드 청구 사이클

    /// 카드사 앱 화면(26.06.27~26.07.26 · 14건 · 633,220원)과 숫자가 맞아야 한다.
    @Test func billingSummaryMatchesCardStatement() {
        let b = BillingCycle.summary(today: 26)

        #expect(b.usage == 633_220)
        #expect(b.count == 14)                 // '기타 3건'은 1건이 아니라 3건으로 센다
        #expect(b.periodLabel == "6/27~7/26")
        #expect(b.payLabel == "8월 14일")
    }

    /// 이용금액과 실제 청구액은 다르다 — 할부가 다음 결제일로 밀리기 때문이다.
    @Test func installmentSplitsAcrossTwoPayDates() {
        let b = BillingCycle.summary(today: 26)

        // 인터넷상거래 181,180원 무이자 2개월 → 90,590 × 2
        #expect(b.carryover == 90_590)
        #expect(b.deferred == 90_590)
        #expect(b.dueNext == 542_630)
        #expect(b.dueNext + b.carryover == b.usage)   // 새는 돈 없이 두 결제일로 나뉜다
    }

    /// 나누어떨어지지 않는 할부는 나머지를 1회차에 붙여 총액이 보존돼야 한다.
    @Test func installmentRoundingKeepsTotal() {
        let tx = CardTransaction(day: 1, merchant: "테스트", amount: 100_000, installmentMonths: 3)
        let rounds = (1...3).map { tx.installmentAmount(round: $0) }

        #expect(rounds.reduce(0, +) == 100_000)
        #expect(rounds[0] == 33_334)   // 33,333 + 나머지 1
        #expect(rounds[1] == 33_333)
    }

    /// 이용기간 마감일을 넘겨 쓰면 이번 결제일이 아니라 다음 결제일로 넘어간다.
    @Test func spendingAfterClosingDayMovesToNextCycle() {
        let due = BillingCycle.summary(today: 26).dueNext

        #expect(BillingCycle.projectedDue(adding: 50_000, on: 26, today: 26) == due + 50_000)
        #expect(BillingCycle.projectedDue(adding: 50_000, on: 27, today: 26) == due)
    }

    // MARK: 일정-거래 매칭 (보고서 8.1)

    /// 예약만 잡히고 금액을 모르는 일정에 결제가 붙는 게 이 기능의 핵심 시나리오다.
    /// 7/14 오디움 예약(14:00) ← 네이버페이 23,600원(13:38).
    @Test func matchesReservationToPaymentByTime() {
        let model = onJuly22 { AppModel() }
        let tx = try! #require(BillingCycle.transactions.first {
            $0.day == 14 && $0.merchant == "네이버페이"
        })

        let m = try! #require(MatchEngine.bestMatch(for: tx, in: model))

        #expect(m.event.title == "오디움 예약")
        #expect(m.verdict == .confirm)          // 50~79점 → 사용자에게 확인 요청
        #expect(m.score >= 50 && m.score < 80)
    }

    /// 장소·이동 기준이 없으므로 만점은 100이 아니다. 남은 기준으로 환산해야
    /// 보고서의 80/50 임계값을 그대로 쓸 수 있다.
    @Test func scoreIsNormalizedOverAvailableCriteria() {
        let model = onJuly22 { AppModel() }
        let tx = try! #require(BillingCycle.transactions.first {
            $0.day == 14 && $0.merchant == "네이버페이"
        })
        let m = try! #require(MatchEngine.bestMatch(for: tx, in: model))

        #expect(m.available < 100)              // 장소(20)·이동(10)이 빠졌다
        #expect(m.score == Int((Double(m.earned) / Double(m.available) * 100).rounded()))
        // 금액을 모르는 일정은 그 기준이 감점이 아니라 '제외'로 처리된다
        #expect(m.criteria.contains { $0.name == "금액 유사성" && $0.max == 0 })
    }

    /// 출근처럼 하루를 덮는 일정은 후보에서 빼야 한다.
    /// 안 그러면 그날 아무 결제나 시간 점수를 다 먹는다.
    @Test func allDayBackgroundEventsAreNotMatchCandidates() {
        let model = onJuly22 { AppModel() }
        // 7/13 12:27 네이버페이 — 그 시각엔 '인포스탁 인턴'(8:30~17:30)만 걸친다
        let tx = try! #require(BillingCycle.transactions.first {
            $0.day == 13 && $0.merchant == "네이버페이"
        })

        let m = MatchEngine.bestMatch(for: tx, in: model)
        #expect(m?.event.title != "인포스탁 인턴")
        #expect(m?.verdict != .auto)
    }

    /// 양쪽 다 '기타'인 건 업종이 맞은 게 아니라 둘 다 모르는 것 — 만점을 주면 안 된다.
    @Test func unknownCategoriesDoNotCountAsAMatch() {
        let model = onJuly22 { AppModel() }
        let tx = try! #require(BillingCycle.transactions.first {
            $0.day == 14 && $0.merchant == "네이버페이"
        })
        let m = try! #require(MatchEngine.bestMatch(for: tx, in: model))
        let category = try! #require(m.criteria.first { $0.name == "업종 일치" })

        #expect(category.earned < category.max)
        #expect(category.earned > 0)            // 틀렸다고 0점을 주지도 않는다
    }

    // MARK: 실시간 날짜

    /// 주 범위는 월요일에 시작해 7월 밖으로 넘어가지 않는다.
    @Test func weekRangeStartsOnMondayAndStaysInJuly() {
        #expect(DemoClock.weekRange(containing: 22) == 20...26)   // 7/22 수 → 20(월)~26(일)
        #expect(DemoClock.weekRange(containing: 26) == 20...26)   // 7/26 일 → 같은 주
        #expect(DemoClock.weekRange(containing: 27) == 27...31)   // 다음 주는 월말에서 잘린다
        #expect(DemoClock.weekRange(containing: 1) == 1...5)      // 7/1 수 → 앞쪽도 잘린다
    }

    /// 2026년 7월 1일은 수요일 — 요일 계산의 기준점이 맞아야 캘린더가 어긋나지 않는다.
    @Test func weekdayMatchesJuly2026() {
        #expect(DemoClock.weekday(of: 1) == "수")
        #expect(DemoClock.weekday(of: 22) == "수")
        #expect(DemoClock.weekday(of: 26) == "일")
        #expect(DemoClock.fullLabel(of: 26) == "2026년 7월 26일 일요일")
    }

    /// 캘린더의 '오늘' 표시는 하나뿐이고 실제 날짜를 따라간다.
    @Test func calendarMarksTodayFromClock() {
        let days = onJuly22 { AppModel.makeJulyCalendar() }
        #expect(days.filter(\.isToday).count == 1)
        #expect(days.first(where: \.isToday)?.dayNumber == 22)
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
