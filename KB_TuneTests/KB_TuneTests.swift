//
//  KB_TuneTests.swift
//  KB_TuneTests
//
//  Created by Sungjeh Yoon on 7/21/26.
//

import Foundation
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
            // 이번 주 금액은 주차 장부에서 나온다 — 성질 검증은 이월 테스트가 맡는다.
            #expect(model.weeklyBudget(for: .maintain) >= 0)
        }
    }

    /// 배분이 남아 있는 주에서는 방향에 따라 금액이 줄이기 < 유지 < 늘리기 순이어야 한다.
    /// 배분이 음수인 주에 계수를 그대로 곱하면 순서가 뒤집히므로 그 회귀를 막는다.
    @Test func directionOrdersTheWeeklyAmount() {
        let model = onJuly22 { AppModel() }
        model.openingRollover = 600_000     // 첫 주부터 배분이 넉넉한 상황을 만든다

        onJuly22 {
            let reduce = model.weeklyBudget(for: .reduce)
            let maintain = model.weeklyBudget(for: .maintain)
            let increase = model.weeklyBudget(for: .increase)
            #expect(reduce < maintain)
            #expect(maintain < increase)
        }
    }

    /// 일정을 지우면 예산이 그 자리에서 따라 바뀌어야 한다.
    /// 예전엔 고정된 시드에서 계산해 지워도 금액이 그대로였다 — 그 회귀를 막는다.
    @Test func deletingEventFreesBudgetImmediately() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let before2 = try! #require(model.thisWeekBudget).carriesForward
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.deleteEvent(ward, on: 22)

            #expect(model.committedThisWeek == 0)
            // 이 주는 이미 배분을 넘겨 써 화면 금액이 0에 붙어 있다.
            // 지운 효과는 다음 주로 넘어갈 금액에서 드러난다.
            #expect(model.thisWeekBudget?.carriesForward == before2 + ward.amount)
            #expect(model.day(number: 22)?.events.contains { $0.title == "와드" } == false)
        }
    }

    /// 금액을 고치면 차액만큼만 움직인다.
    @Test func editingAmountMovesBudgetByTheDifference() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let before = try! #require(model.thisWeekBudget).carriesForward
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.updateEventAmount(ward, on: 22, amount: ward.amount - 10_000)

            #expect(model.thisWeekBudget?.carriesForward == before + 10_000)
        }
    }

    /// 시간만 옮기면 금액 합계는 그대로다.
    @Test func movingEventTimeKeepsTheTotal() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let before = try! #require(model.thisWeekBudget).carriesForward
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.updateEventTime(ward, on: 22, startHour: 21)

            #expect(model.thisWeekBudget?.carriesForward == before)
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

    /// 3개월 이상 할부도 2회차만이 아니라 남은 모든 회차가 다음 달 예산에 잡혀야 한다.
    @Test func installmentCarryoverIncludesEveryRemainingRound() {
        let transaction = CardTransaction(day: 9, merchant: "테스트", amount: 100_000,
                                          installmentMonths: 3)
        let summary = BillingCycle.summary(today: 22, transactions: [transaction])

        #expect(transaction.installmentAmount(round: 1) == 33_334)
        #expect(transaction.installmentAmount(round: 2) == 33_333)
        #expect(transaction.installmentAmount(round: 3) == 33_333)
        #expect(transaction.installmentAmount(round: 4) == 0)
        #expect(summary.dueNext == 33_334)
        #expect(summary.carryover == 66_666)
        #expect(summary.deferred == summary.carryover)
    }

    @Test func transactionTimeNeverRendersSixtyMinutes() {
        let transaction = CardTransaction(day: 1, merchant: "테스트", amount: 1_000,
                                          hour: 9.999)
        #expect(transaction.timeLabel == "10:00")
    }

    @Test func julyCalendarTotalsAreConfirmedValues() {
        let model = onJuly22 { AppModel() }

        // 캘린더는 7·8월 두 달을 담는다(통산 62일). 7월만 세면 31일.
        #expect(model.calendarDays.count == 62)
        #expect(model.days(of: 7).count == 31)
        #expect(model.days(of: 8).count == 31)
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

    @Test func cafeEstimateComesFromPersonalMedianAndChangesWithHistory() throws {
        let previous = SpendHistory.learnedRecords
        defer { SpendHistory.replaceLearnedRecords(previous) }
        SpendHistory.replaceLearnedRecords([])

        let baseline = EventEstimator.estimate("카페 약속")
        #expect(baseline.amount == 20_000)       // 10,000원·30,000원 표본의 중앙값
        #expect(baseline.method == "history")
        #expect(baseline.basis.contains("2건"))
        #expect(baseline.basis.contains("중앙값"))

        SpendHistory.replaceLearnedRecords([
            SpendRecord(title: "퇴근 커피", category: "카페", month: 7, day: 10,
                        amount: 50_000, onCalendar: true)
        ])
        let learned = EventEstimator.estimate("카페 약속")
        let draft = try #require(EventPhrase.parse("8월 5일 카페 갈래"))

        #expect(learned.amount == 30_000)        // 10,000·30,000·50,000원의 중앙값
        #expect(learned.basis.contains("3건"))
        #expect(draft.amount == learned.amount)  // 자연어 일정 추가도 같은 이력을 쓴다
        #expect(draft.basis.contains("3건"))
    }

    @Test func dailyCloseLearnsCashPaymentAndResetClearsIt() {
        let previous = SpendHistory.learnedRecords
        defer { SpendHistory.replaceLearnedRecords(previous) }

        onJuly22 {
            let model = AppModel()
            model.addEvent(title: "카페 약속", day: 22, amount: 50_000,
                           category: "카페", basis: "사용자 확인", state: .reserved)
            let cafeID = model.day(number: 22)?.events.first { $0.title == "카페 약속" }?.id

            model.resolveDailyClose(paidCash: true)

            let learnedCafe = model.learnedSpendRecords.first { $0.sourceEventID == cafeID }
            #expect(learnedCafe?.amount == 50_000)
            #expect(learnedCafe?.category == "카페")
            #expect(model.day(number: 22)?.events.first { $0.id == cafeID }?.state == .confirmed)
            #expect(EventEstimator.estimate("카페 약속").amount == 30_000)

            let learnedCount = model.learnedSpendRecords.count
            model.resolveDailyClose(paidCash: true)
            #expect(model.learnedSpendRecords.count == learnedCount) // 같은 결제를 중복 학습하지 않는다

            model.resetToDemo()
            #expect(model.learnedSpendRecords.isEmpty)
            #expect(EventEstimator.estimate("카페 약속").amount == 20_000)
        }
    }

    @Test func learnedHistoryRoundTripsAndOldStateDefaultsToEmptyHistory() throws {
        let learned = SpendRecord(title: "카페 약속", category: "카페", month: 7, day: 22,
                                  amount: 24_000, onCalendar: true, sourceEventID: UUID())
        let state = PersistedState(
            hasOnboarded: true,
            usesDemoData: true,
            kbPayLinked: false,
            monthlyIncome: 2_200_000,
            savingsGoal: 800_000,
            direction: .maintain,
            hobbies: ["카페"],
            calendarDays: AppModel.makeCalendar(),
            learnedSpendRecords: [learned],
            dismissedPredictions: [],
            dailyCloseDismissed: false
        )

        let restored = try JSONDecoder().decode(
            PersistedState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(restored.learnedSpendRecords == [learned])

        let oldJSON = #"{"version":1,"hasOnboarded":true,"usesDemoData":true,"kbPayLinked":false,"monthlyIncome":2200000,"savingsGoal":800000,"direction":"maintain","hobbies":["카페"],"calendarDays":[{"weekday":"수","dateLabel":"7/22","dayNumber":22,"events":[]}],"dismissedPredictions":[],"dailyCloseDismissed":false}"#
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(oldJSON.utf8))

        #expect(old.calendarDays.count == 1)
        #expect(old.learnedSpendRecords.isEmpty)
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
            #expect(model.weeklyBudgetAfterPredictions <= model.weeklyBudget)
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

    // MARK: 주차별 이월

    /// 중간에 어떻게 나누든 총량은 보존된다 —
    /// 마지막 주 잔액 = 이 달에 쓸 수 있는 돈 − 이 달 일정비 전체.
    @Test func rolloverPreservesTheMonthlyTotal() {
        let model = onJuly22 { AppModel() }
        let weeks = model.weekBudgets

        #expect(weeks.count == 5)                       // 2026년 7월은 5주에 걸친다
        #expect(model.closingRollover
                == model.monthlyDisposable - model.julyEstimateHigh)
    }

    /// 각 주의 잔액이 다음 주 이월로 그대로 넘어가야 한다.
    @Test func eachWeekCarriesIntoTheNext() {
        let model = onJuly22 { AppModel() }
        let weeks = model.weekBudgets

        for (prev, next) in zip(weeks, weeks.dropFirst()) {
            #expect(next.rollover == prev.carriesForward)
        }
        #expect(weeks.first?.rollover == 0)             // 지난달에서 넘어온 게 없다
    }

    /// 지난달 잔액이 있으면 첫 주가 그만큼 넉넉해진다 — 8월로 넘길 때의 동작.
    @Test func openingRolloverLiftsTheFirstWeek() {
        let model = onJuly22 { AppModel() }
        let baseline = try! #require(model.weekBudgets.first).allowance

        model.openingRollover = 40_000

        let lifted = try! #require(model.weekBudgets.first)
        #expect(lifted.allowance == baseline + 40_000)
        #expect(lifted.rollover == 40_000)
    }

    /// 일정을 지우면 그 주 잔액이 늘고, 늘어난 만큼 다음 주로 넘어간다.
    @Test func deletingEventIncreasesWhatCarriesForward() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            let weeks = model.weekBudgets
            let lastBefore = try! #require(weeks.last).carriesForward
            let ward = try! #require(model.day(number: 22)?.events.first { $0.title == "와드" })

            model.deleteEvent(ward, on: 22)

            #expect(try! #require(model.weekBudgets.last).carriesForward
                    == lastBefore + ward.amount)
        }
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
        let days = onJuly22 { AppModel.makeCalendar() }
        #expect(days.filter(\.isToday).count == 1)
        #expect(days.first(where: \.isToday)?.dayNumber == 22)
    }

    @Test func confirmedAmountsAreNotLabelledAsEstimates() {
        let model = AppModel()
        let ward = model.day(number: 22)?.events.first { $0.title == "와드" }
        // 사용자가 확인한 금액 → low == high 이고 예측도 아니므로 '예상' 접두어가 붙지 않는다
        #expect(ward?.isEstimated == false)
    }

    // MARK: 대화 문장 → 일정

    /// 사용자가 실제로 말할 법한 문장에서 날짜·이름·금액을 뽑아내야 한다.
    @Test func parsesDateAndActivityFromEverydaySentence() throws {
        let d = onJuly22 {
            try! #require(EventPhrase.parse("나 7/31일날 약속 잡아도 될까? 친구들이랑 강남에서 술 한잔 할거같은데"))
        }
        #expect(DemoClock.month(of: d.day) == 7)
        #expect(DemoClock.dayOfMonth(of: d.day) == 31)
        #expect(d.title == "술 약속")
        #expect(d.amountWasSpoken == false)      // 금액을 안 말했으니 추정으로 채운다
        #expect(d.amount > 0)
    }

    /// 금액을 말하면 추정하지 않고 그 값을 쓴다.
    @Test func spokenAmountWinsOverEstimate() throws {
        let d = onJuly22 { try! #require(EventPhrase.parse("8월 2일 데이트 10만원")) }
        #expect(DemoClock.month(of: d.day) == 8)
        #expect(DemoClock.dayOfMonth(of: d.day) == 2)
        #expect(d.title == "데이트")
        #expect(d.amount == 100_000)
        #expect(d.amountWasSpoken)
    }

    /// 평범한 질문을 일정 제안으로 오해하면 안 된다.
    /// 날짜와 할 일이 둘 다 있어야만 후보로 본다.
    @Test func plainQuestionsAreNotTreatedAsEvents() {
        onJuly22 {
            #expect(EventPhrase.parse("이번 주 얼마까지 써도 돼?") == nil)   // 날짜도 할 일도 없음
            #expect(EventPhrase.parse("안녕") == nil)
            #expect(EventPhrase.parse("내일 날씨 어때?") == nil)             // 날짜만 있고 할 일 없음
            #expect(EventPhrase.parse("술 한잔 하고 싶다") == nil)           // 할 일만 있고 날짜 없음
        }
    }

    /// 데모 기간(7~8월) 밖 날짜는 받지 않는다.
    @Test func datesOutsideTheDemoWindowAreRejected() {
        onJuly22 {
            #expect(EventPhrase.parse("12월 25일 술 한잔") == nil)
        }
    }

    // MARK: 기기 캘린더 연결

    /// 직접 넣은 일정은 기기 캘린더 식별자를 함께 들고 있어야 한다.
    /// 이 값이 없으면 나중에 지우거나 시간을 옮겨도 기기 캘린더에는 반영되지 않는다.
    @Test func addedEventRemembersItsCalendarID() {
        let model = onJuly22 { AppModel() }

        onJuly22 {
            model.addEvent(title: "테스트 모임", day: 23, amount: 20_000,
                           category: "모임", basis: nil, calendarEventID: "EK-123")
            let added = model.day(number: 23)?.events.first { $0.title == "테스트 모임" }
            #expect(added?.calendarEventID == "EK-123")
        }
    }

    /// 예측 수락은 예산 항목이지 약속이 아니다 — 기기 캘린더에 넣지 않는다.
    @Test func acceptedPredictionIsNotWrittenToDeviceCalendar() {
        let model = onJuly22 { AppModel() }
        let spend = onJuly22 {
            try! #require(model.upcomingSpends.first { $0.pattern.key == "쿠팡 장보기" })
        }

        onJuly22 {
            model.acceptPrediction(spend)
            let added = model.day(number: spend.expectedDay)?
                .events.first { $0.title == "쿠팡 장보기" }
            #expect(added?.calendarEventID == nil)
        }
    }

    // MARK: 기기 저장

    /// 저장했다 되살려도 일정·금액·상태가 그대로여야 한다.
    ///
    /// id 를 `let id = UUID()` 로 둔 구조체는 인코딩에서 빠지기 쉽고, 빠지면 복원할 때
    /// 새 id 가 생긴다. 그러면 "같은 일정"을 못 찾아 수정·삭제가 엉뚱한 걸 건드린다.
    @Test func calendarSurvivesSaveAndRestore() throws {
        let days = onJuly22 { AppModel.makeCalendar() }

        let data = try JSONEncoder().encode(days)
        let restored = try JSONDecoder().decode([PlanDay].self, from: data)

        #expect(restored.count == days.count)
        #expect(restored.map(\.id) == days.map(\.id))            // id 가 보존돼야 한다
        #expect(restored.map(\.dayNumber) == days.map(\.dayNumber))

        let before = try #require(days.first { $0.dayNumber == 22 }?
            .events.first { $0.title == "와드" })
        let after = try #require(restored.first { $0.dayNumber == 22 }?
            .events.first { $0.title == "와드" })

        #expect(after.id == before.id)
        #expect(after.amount == 40_000)
        #expect(after.state == before.state)
        #expect(after.estimateBasis == before.estimateBasis)
        #expect(after.isProtected == before.isProtected)
    }

    @Test func olderCalendarJSONUsesSafeDefaultsInsteadOfFailingWholeRestore() throws {
        let legacy = #"{"weekday":"수","dateLabel":"7/22","dayNumber":22,"events":[{"title":"옛 일정","symbol":"calendar","startHour":19,"duration":2,"amount":12000}]}"#
        let day = try JSONDecoder().decode(PlanDay.self, from: Data(legacy.utf8))
        let event = try #require(day.events.first)

        #expect(day.dayNumber == 22)
        #expect(event.title == "옛 일정")
        #expect(event.category == "기타")
        #expect(event.state == .confirmed)
        #expect(event.calendarEventID == nil)
    }

    /// 테스트 중에는 기기 저장을 읽지도 쓰지도 않는다 —
    /// 앞선 실행이 남긴 일정이 섞이면 아래 기대값들이 전부 흔들린다.
    @Test func persistenceIsOffDuringTests() {
        #expect(LocalStore.isDisabled)
        #expect(LocalStore.load() == nil)
    }

    // MARK: 핵심 계산 회귀

    @Test func suggestedSavingsDoesNotSubtractInstallmentTwice() {
        onJuly22 {
            let model = AppModel()

            // remainingBudget에 할부 이월액 90,590원이 이미 포함돼 있다.
            #expect(model.remainingBudget == 113_410)
            #expect(model.suggestedSavingsAmount == 50_000)
        }
    }

    @Test func savingsRecommendationUsesOnlySafeAdditionalDeposit() {
        onJuly22 {
            let model = AppModel()
            let pick = try! #require(RecoEngine.evalSavings(model).first { $0.product.id == "my-made" })

            #expect(pick.monthlyDeposit == model.suggestedSavingsAmount)
            #expect(pick.monthlyDeposit < model.savingsGoal)
            #expect(pick.estInterest == RecoEngine.savingsInterest(
                monthly: model.suggestedSavingsAmount, months: 12,
                ratePct: pick.product.expectedRate
            ))
        }
    }

    @Test func cardSpendUsesOneNormalizedLedger() {
        let model = onJuly22 { AppModel() }
        let spend = RecoEngine.normalizedCardSpend(model)

        // 일정 한 건은 한 카테고리에만 속하므로 추천 입력 합계가 월간 일정 합계와 같다.
        #expect(spend.values.reduce(0, +) == model.julyEstimateHigh)
        #expect(RecoEngine.recognizedSpend(model) == model.julyEstimateHigh)
        #expect((spend["교통"] ?? 0) > 0)
    }

    @Test func nori2BenefitNeverExceedsAggregateMonthlyCap() {
        let model = onJuly22 { AppModel() }
        let evaluation = try! #require(RecoEngine.evalCards(model).ranked.first { $0.product.id == "nori2" })

        #expect(evaluation.product.monthlyBenefitCap == 20_000)
        #expect(evaluation.estMonthly <= evaluation.product.monthlyBenefitCap)
        #expect(evaluation.benefitLines.reduce(0) { $0 + $1.amount } == evaluation.estMonthly)
    }

    @Test func partialWeeksAreProratedAndPreserveMonthlyTotal() {
        let disposable = 965_000
        let weeks = WeekLedger.build(disposable: disposable, spendByWeek: [:], month: 7)

        #expect(weeks.map(\.baseAllowance).reduce(0, +) == disposable)
        #expect(weeks.first?.days.count == 5)
        #expect(weeks.first?.baseAllowance == disposable * 5 / 31)
        #expect(weeks[1].days.count == 7)
        #expect(weeks[1].baseAllowance == disposable * 7 / 31)

        let august = WeekLedger.build(disposable: disposable, spendByWeek: [:], month: 8)
        #expect(august.map(\.baseAllowance).reduce(0, +) == disposable)
        #expect(august.first?.days.count == 2)
    }

    @Test func futureEventPreviewUsesItsOwnWeek() {
        let model = onJuly22 { AppModel() }
        model.openingRollover = 600_000
        let target = DemoClock.serial(month: 8, day: 3)
        let currentBefore = model.weeklyBudget
        let targetBefore = model.weeklyBudget(for: .maintain, on: target)

        #expect(targetBefore > 10_000)
        #expect(model.weeklyBudget(for: .maintain, extraCommitted: 10_000, on: target)
                == targetBefore - 10_000)
        #expect(model.weeklyBudget == currentBefore)
    }

    @Test func augustBillingUsesSerialDatesAndCorrectPaymentMonth() {
        let augustFirst = DemoClock.serial(month: 8, day: 1)
        let augustTwentySeventh = DemoClock.serial(month: 8, day: 27)
        let summary = BillingCycle.summary(today: augustFirst)

        #expect(summary.daysUntilPay == 13)
        #expect(summary.daysUntilClose == 0) // 화면의 확정 명세는 7/26에 이미 마감
        #expect(BillingCycle.paymentLabel(for: augustFirst) == "9월 14일")
        #expect(BillingCycle.paymentLabel(for: augustTwentySeventh) == "10월 14일")
        #expect(!BillingCycle.isInReferenceStatement(augustFirst))
    }

    @Test func restoredCalendarRecomputesTodayMarker() {
        let saved = onJuly22 { AppModel.makeCalendar() }
        let augustSecond = DemoClock.serial(month: 8, day: 2)
        let restored = AppModel.markingToday(saved, today: augustSecond)

        #expect(restored.filter(\.isToday).count == 1)
        #expect(restored.first(where: \.isToday)?.dayNumber == augustSecond)
    }

    /// 앱을 켠 뒤 자정이 지나도 한 화면 안에서 '오늘' 기준이 둘로 갈라지지 않아야 한다.
    @Test func modelCalculationsUseTheLaunchDateSnapshot() {
        DemoClock.fixedToday = 22
        let model = AppModel()
        let expected = BudgetEngine.spentToDate(in: model.calendarDays, asOfDay: 22)
        DemoClock.fixedToday = 23
        defer { DemoClock.fixedToday = nil }

        #expect(model.todayDayNumber == 22)
        #expect(model.spentToDate == expected)
        #expect(model.committedThisWeek
                == BudgetEngine.committedThisWeek(in: model.calendarDays, asOfDay: 22))
    }

    @Test func automaticEventTimesDoNotOverlapAtTheEndOfDay() {
        let events = [
            DayEvent(title: "첫 일정", symbol: "calendar", startHour: 19,
                     duration: 2, amount: 0),
            DayEvent(title: "둘째 일정", symbol: "calendar", startHour: 21,
                     duration: 2, amount: 0),
        ]
        let slot = AppModel.freeSlot(after: events)
        let overlaps = events.contains {
            slot < $0.startHour + $0.duration && $0.startHour < slot + 2
        }

        #expect(!overlaps)
        #expect(slot + 2 <= 24)
    }

    @Test func predictionDismissalOnlyHidesThatOccurrence() {
        let model = onJuly22 { AppModel() }
        let spend = onJuly22 {
            try! #require(model.upcomingSpends.first { $0.pattern.key == "쿠팡 장보기" })
        }
        let later = UpcomingSpend(pattern: spend.pattern,
                                  expectedDay: spend.expectedDay + spend.pattern.cadenceDays,
                                  amount: spend.amount, reason: spend.reason)

        model.dismissPrediction(spend)

        #expect(model.dismissedPredictions.contains(AppModel.predictionOccurrenceKey(spend)))
        #expect(!model.dismissedPredictions.contains(AppModel.predictionOccurrenceKey(later)))
    }

    @Test func septemberPreviewUsesItsActualPartialWeek() {
        let opening = WeekLedger.nextMonthOpening(disposable: 900_000,
                                                  carriedIn: 10_000,
                                                  month: 9)
        // 2026-09-01은 화요일: 첫 월요일 주간에는 9/1~9/6, 6일만 들어간다.
        #expect(opening.month == 9)
        #expect(opening.days.count == 6)
        #expect(opening.baseAllowance == 180_000)
        #expect(opening.allowance == 190_000)
    }

    @Test func movingEventReturnsTargetAndPreservesCalendarIdentity() {
        let model = onJuly22 { AppModel() }
        model.addEvent(title: "동기화 테스트", day: 23, amount: 20_000,
                       category: "외식", basis: nil, calendarEventID: "EK-MOVE")
        let event = try! #require(model.day(number: 23)?.events.first { $0.title == "동기화 테스트" })

        let target = model.moveEventToNextWeek(event, from: 23)

        #expect(target == 30)
        #expect(model.day(number: 23)?.events.contains { $0.id == event.id } == false)
        #expect(model.day(number: 30)?.events.first { $0.id == event.id }?.calendarEventID == "EK-MOVE")
    }

    @Test @MainActor func augustCalendarDateImportsAsSerialDay() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 8, day: 2, hour: 19, minute: 30)
        ))

        #expect(CalendarStore.serialDay(of: date) == 33)
        #expect(DemoClock.dayLabel(of: CalendarStore.serialDay(of: date)) == "8월 2일")
    }

    // MARK: 외부 AI 개인정보 경계

    @Test func outboundPrivacyRemovesIdentityButKeepsFinancialContext() {
        let model = onJuly22 { AppModel() }
        let source = "나는 김성제고 김민수와 카페 갈래. 010-1234-5678 test@example.com 카드 1234-5678-9012-3456 계좌 123-456-789012, 외국인번호 900101-5123456, 여권 M12345678, 주소는 서울시 종로구 세종대로 1이야. 8월 5일 카페 20,000원"
        let safe = OutboundPrivacy.sanitize(source, model: model)

        #expect(!safe.contains("김성제"))
        #expect(!safe.contains("김민수"))
        #expect(!safe.contains("010-1234-5678"))
        #expect(!safe.contains("test@example.com"))
        #expect(!safe.contains("1234-5678-9012-3456"))
        #expect(!safe.contains("123-456-789012"))
        #expect(!safe.contains("900101-5123456"))
        #expect(!safe.contains("M12345678"))
        #expect(!safe.contains("세종대로"))
        #expect(safe.contains("8월 5일"))
        #expect(safe.contains("20,000원"))
    }

    @Test func externalAIReceivesIntentInsteadOfTheOriginalQuestion() {
        let outbound = OutboundPrivacy.financialIntent(
            "김민수와 강남에서 7만원짜리 바지를 사도 될까?"
        )

        #expect(!outbound.contains("김민수"))
        #expect(!outbound.contains("강남"))
        #expect(!outbound.contains("바지"))
        #expect(outbound.contains("새 지출"))
        #expect(outbound.contains("70000원"))
    }

    @Test func outboundPrivacyAliasesKnownEventTitleWithoutConsent() {
        let model = onJuly22 { AppModel() }
        let safe = OutboundPrivacy.sanitize("와드 일정은 얼마로 잡을까?", model: model)

        #expect(!safe.contains("와드"))
        #expect(safe.contains("[자기관리 일정]"))
    }

    @Test @MainActor func finalChatRequestBodyContainsNoRawQuestionIdentityOrEventTitle() throws {
        let model = onJuly22 { AppModel() }
        model.addEvent(title: "김민수 PT", day: 23, amount: 20_000,
                       category: "운동", basis: "테스트")
        let body = try #require(AgentService.makeChatRequestBody(
            message: "김민수와 강남에서 PT 2만원 추가해줘",
            history: [
                AgentChatTurn(role: "user", content: "박영희와 김민수 PT를 잡았어"),
                AgentChatTurn(role: "assistant", content: "김민수 PT 일정은 20,000원이에요"),
            ],
            model: model
        ))
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("김민수"))
        #expect(!json.contains("박영희"))
        #expect(!json.contains("강남"))
        #expect(!json.contains("김민수 PT"))
        #expect(json.contains("20000"))
        #expect(json.contains("운동"))
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

    // MARK: 공개 통계 기준 금액

    @Test func bundledBaselineTableIsReadableOffline() {
        // 서버가 없어도 값이 나와야 한다. 첫 실행·비행기 모드·백엔드 다운 모두 이 경로다.
        #expect(!BaselinePrices.table.events.isEmpty)
        #expect(!BaselinePrices.table.items.isEmpty)
        #expect(BaselinePrices.monthly.total > 0)
    }

    @Test func everyBaselineRowCarriesItsSource() {
        // 근거 없는 숫자를 못 넣게 막는다 — 화면에 출처를 그대로 인용하기 때문이다.
        for event in BaselinePrices.table.events {
            #expect(!event.source.isEmpty)
            #expect(event.low <= event.amount && event.amount <= event.high)
        }
        for item in BaselinePrices.table.items {
            #expect(!item.source.isEmpty)
            #expect(item.low <= item.amount && item.amount <= item.high)
        }
    }

    @Test func newUserWithoutHistoryGetsPublicStatisticsNotSomeoneElsesSpending() {
        // 이력이 빈 사람. 이 기능이 존재하는 이유다.
        let result = EventEstimator.estimate("친구 저녁", history: [])
        #expect(result.method == "baseline")
        #expect(result.amount > 0)
        #expect(result.basis.contains("출처는"))
    }

    @Test func personalHistoryStillWinsOverPublicAverage() {
        // 기기에 같은 카테고리 결제 이력이 있으면 통계 평균이 그걸 덮으면 안 된다.
        let result = EventEstimator.estimate("친구 저녁")
        #expect(result.method == "history")
        #expect(result.amount != BaselinePrices.forCategory("모임")?.amount)
        #expect(result.basis.contains("기기에 저장된"))
    }

    @Test func ageBucketOnlyMovesTheStatisticalBaseline() {
        let plain = BaselinePrices.forCategory("모임")
        let twenties = BaselinePrices.forCategory("모임", ageBucket: "20")
        #expect(twenties!.amount < plain!.amount)
        // 표에 없는 나이대를 넣어도 평균으로 조용히 떨어져야 한다.
        #expect(BaselinePrices.forCategory("모임", ageBucket: "99")!.amount == plain!.amount)
    }

    @Test func categoriesWithoutPublicStatisticsStayOnTheOldRules() {
        // 축의금에 대응하는 공표 통계가 없다. 없으면 없다고 해야 규칙으로 넘어간다.
        #expect(BaselinePrices.forCategory("경조사") == nil)
    }

    @Test func travelReachesItsPublicBaselineInsteadOfTheGenericFallback() {
        // 표에 46,234원 행이 있는데 규칙에 '여행' 항목이 없어서 도달을 못 했다.
        // "제주도 여행"이 기타로 떨어져 근거 없는 20,000원이 나왔다.
        let result = EventEstimator.estimate("제주도 여행", history: [])
        #expect(result.category == "여행")
        #expect(result.method == "baseline")
        #expect(result.basis.contains("출처는"))
    }

    @Test func buyingSomethingIsShoppingNotMiscellaneous() {
        // "구매"만 있고 "구입"이 없어서 한 글자 차이로 기타까지 미끄러졌다.
        for title in ["맥미니 구입하기", "노트북 장만", "정장 구매"] {
            #expect(EventEstimator.estimate(title, history: []).category == "쇼핑",
                    "\(title) 이 쇼핑으로 안 잡힌다")
        }
    }

    @Test func itemLookupIsMoreSpecificThanCategoryAverage() {
        let match = BaselinePrices.forTitle("점심은 자장면")
        #expect(match?.basis.contains("자장면") == true)
    }

    // MARK: 웹 검색 — 제목이 검색어로 새지 않는가

    @Test func searchQueryNeverCopiesWordsFromTheTitle() {
        // 이 기능의 안전성 전부가 여기 걸려 있다. 검색어는 코드에 있는 말로만 조립되고
        // 제목의 낱말은 하나도 복사되지 않아야 한다.
        let secrets = ["제주도", "성심병원", "김민수", "성당", "강남", "롯데월드"]
        let titles = [
            "제주도 3박4일 여행", "성심병원 정기검진 여행", "김민수랑 여행",
            "성당 모임 여행", "강남 여행 2명", "롯데월드 여행",
        ]
        for title in titles {
            guard let built = SearchQuery.make(title: title, category: "여행") else { continue }
            for secret in secrets {
                #expect(!built.query.contains(secret), "‘\(secret)’이 검색어에 남음: \(built.query)")
            }
        }
    }

    @Test func searchQueryKeepsOnlyStructuralSignals() {
        let built = SearchQuery.make(title: "제주도 3박4일 여행", category: "여행")
        #expect(built?.query == "국내 3박 여행 1인 평균 경비")

        let overseas = SearchQuery.make(title: "일본 2박 여행", category: "여행")
        #expect(overseas?.query == "해외 2박 여행 1인 평균 경비")
    }

    @Test func categoriesWithGoodBaselinesAreNotSearched() {
        // 공개 통계나 개인 이력으로 답이 나오는 건 검색하지 않는다.
        for category in ["외식", "카페", "모임", "데이트", "자기관리", "쇼핑"] {
            #expect(SearchQuery.make(title: "무엇이든", category: category) == nil)
        }
    }

    @Test func headcountIsAppliedByTheAppNotTheSearch() {
        // 검색은 늘 1인 기준으로 묻고, 인원 곱하기는 기기에서 한다.
        #expect(SearchQuery.headcount(in: "여행 4명") == 4)
        #expect(SearchQuery.headcount(in: "여행") == 1)
        #expect(SearchQuery.headcount(in: "여행 99명") == 1)   // 말이 안 되는 값은 무시
        #expect(SearchQuery.make(title: "여행 4명", category: "여행")?
            .query.contains("1인 평균") == true)
    }

    // MARK: 대화 에이전트

    @Test func planAgentIsOffUntilTheUserTurnsItOn() {
        // 켜면 방금 친 문장이 모델까지 간다. 기본값이 꺼짐이 아니면 동의 없이 나간다.
        UserDefaults.standard.removeObject(forKey: AIConsent.key)
        #expect(AIConsent.granted == false)
    }

    @Test func oneSwitchTurnsOnEverythingAndNothingElseIsNeeded() {
        // 스위치는 하나뿐이다. 켜면 대화·일정 변경·검색이 다 되고, 끄면 다 멈춘다.
        // 예전에는 넷이어서 "뭘 켜야 뭐가 되는지" 알 수 없었다.
        defer { ConsentStore.reset() }

        ConsentStore.set(.overseas, false)
        #expect(AIConsent.granted == false)

        ConsentStore.set(.overseas, true)
        #expect(AIConsent.granted)
    }

    @Test func turningTransmissionOnAlwaysLeavesAConsentRecord() {
        // 전송을 켜는 길은 하나여야 한다. 대화 화면의 동의 시트가 AIConsent 만 직접
        // 켜던 시절에는, 설정에서 철회해도 시트가 되켜서 기록은 '철회'인데 전송은
        // 이어졌다. 동의 시각이 안 남아 언제 동의했는지 입증도 못 했다.
        defer { ConsentStore.reset() }
        ConsentStore.reset()

        ConsentStore.set(.overseas, true)
        // 전송이 켜졌다면 동의 기록과 시각이 반드시 함께 있어야 한다.
        #expect(AIConsent.granted)
        #expect(ConsentStore.granted(.overseas))
        #expect(ConsentStore.grantedAt(.overseas) != nil)

        ConsentStore.set(.overseas, false)
        #expect(AIConsent.granted == false)
        #expect(ConsentStore.granted(.overseas) == false)
        #expect(ConsentStore.grantedAt(.overseas) == nil)
    }

    @Test func agentTurnMasksNamesAndSavedEventTitles() {
        // 에이전트 경로로 나가는 문장. 이름과 이미 저장된 일정 제목은 기기에서 가려야 한다.
        let model = AppModel()
        let saved = model.calendarDays.flatMap(\.events).first { !$0.title.isEmpty }
        let sentence = "\(model.userName)이랑 \(saved?.title ?? "와드") 얘기 좀 하자. 010-1234-5678로 연락함"
        let sent = OutboundPrivacy.sanitize(sentence, model: model)

        #expect(!sent.contains(model.userName))
        if let title = saved?.title { #expect(!sent.contains(title)) }
        #expect(!sent.contains("010-1234-5678"))
    }

    @Test func nothingLeavesUntilTheUserTurnsAIOn() {
        // 켠 적 없는 사람에게서는 아무것도 나가면 안 된다. 기본값이 꺼짐이어야 한다.
        UserDefaults.standard.removeObject(forKey: AIConsent.key)
        #expect(AIConsent.granted == false)
        #expect(AIConsent.asked == false)
    }

    @Test func calendarTitlesNeedTheirOwnConsent() {
        // 일정 제목은 민감정보(제23조)다. 별도 동의 없이는 앱 안으로도 들어오면 안 된다 —
        // 가려서 보내는 게 아니라 아예 읽지 않는 것이 이 규칙의 요지다.
        defer { ConsentStore.reset() }

        ConsentStore.set(.sensitive, false)
        #expect(CalendarStore.importedTitle("정형외과 진료") == "일정")

        ConsentStore.set(.sensitive, true)
        #expect(CalendarStore.importedTitle("정형외과 진료") == "정형외과 진료")
    }

    @Test func consentGateStaysClosedUntilTheRequiredItemIsGranted() {
        // 필수 항목 없이는 앱에 들어갈 수 없어야 한다. 선택 항목만 눌러도 열리면
        // '필수/선택 분리'(제22조)가 화면에만 있고 코드에는 없는 것이 된다.
        defer { ConsentStore.reset() }
        ConsentStore.reset()
        #expect(ConsentStore.isComplete == false)

        ConsentStore.set(.sensitive, true)
        ConsentStore.finish()
        #expect(ConsentStore.isComplete == false)

        ConsentStore.set(.essential, true)
        ConsentStore.finish()
        #expect(ConsentStore.isComplete == true)
    }

    @Test func withdrawingOverseasConsentStopsTransmission() {
        // 국외 이전 동의를 끄면 전송 스위치도 같이 꺼져야 한다. 두 값이 어긋나면
        // 철회했는데도 계속 나가는 사고가 된다.
        defer { ConsentStore.reset() }

        ConsentStore.set(.overseas, true)
        #expect(AIConsent.granted == true)

        ConsentStore.set(.overseas, false)
        #expect(AIConsent.granted == false)
    }

}
