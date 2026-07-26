//
//  BillingCycle.swift
//  KB_Tune
//
//  신용카드 청구 사이클 — "쓴 날"과 "돈 나가는 날"을 분리한다.
//
//  KB국민카드는 이용기간이 전월 27일~당월 26일, 결제일이 익월 14일이다.
//  그래서 오늘 쓴 돈은 최대 49일 뒤에 빠져나가고, 할부는 그보다 더 뒤까지 이어진다.
//  BudgetEngine 은 "쓴 날 = 나가는 날"로 가정해 이 시차를 몰랐다.
//  기획 보고서 7.3 계산식의 '카드 결제예정액' 항이 여기에 해당한다.
//
//  데이터는 사용자의 실제 KB국민카드 이용내역(26.06.27~26.07.26)이다.
//

import Foundation

// MARK: - 이용내역 1건

struct CardTransaction: Identifiable {
    let id = UUID()
    var day: Int                    // 2026년 7월 기준 일자
    var merchant: String
    var amount: Int                 // 이용금액 (할부면 총액)
    var installmentMonths: Int = 1  // 1 = 일시불
    var isKBPay: Bool = false
    /// 몇 건을 묶은 항목인지. 합계로만 넣은 항목이 건수를 1건으로 세지 않게 한다.
    var count: Int = 1

    var isInstallment: Bool { installmentMonths > 1 }

    /// n회차 청구액. 나누어떨어지지 않는 나머지는 1회차에 붙인다(카드사 관행).
    func installmentAmount(round n: Int) -> Int {
        guard isInstallment else { return n == 1 ? amount : 0 }
        let base = amount / installmentMonths
        return n == 1 ? base + (amount - base * installmentMonths) : base
    }
}

// MARK: - 청구 요약

struct BillingSummary {
    var usage: Int          // 이번 사이클 이용금액 (카드사 앱의 '국내 이용금액')
    var count: Int          // 이용 건수
    var dueNext: Int        // 다음 결제일에 실제로 빠질 금액
    var carryover: Int      // 그 다음 결제일로 넘어가는 할부 잔액
    var installments: [CardTransaction]
    var daysUntilClose: Int  // 이용기간 마감까지 남은 일수 (0 = 오늘 마감)
    var periodLabel: String  // "6/27~7/26"
    var closeLabel: String   // "7월 26일"
    var payLabel: String     // "8월 14일"
    var nextPayLabel: String // "9월 14일"

    /// 이용금액과 실제 청구액의 차이 — 할부 때문에 다음 달로 밀린 금액.
    var deferred: Int { usage - dueNext }
}

// MARK: - 사이클 엔진

enum BillingCycle {

    /// 이용기간 마지막 날. 이 날까지 쓴 건 다음 결제일에 청구된다.
    static let closingDay = 26
    /// 결제일 — 이용기간이 끝난 다음 달 14일.
    static let payDay = 14

    /// 사용자의 KB ALL 카드(2054) 이용내역 · 이용기간 26.06.27~26.07.26.
    /// 카드사 앱 기준 총 14건 633,220원.
    static let transactions: [CardTransaction] = [
        CardTransaction(day: 23, merchant: "쿠팡이츠", amount: 19_100),
        CardTransaction(day: 23, merchant: "유튜브 프리미엄", amount: 14_900),
        CardTransaction(day: 20, merchant: "네이버페이", amount: 30_000),
        CardTransaction(day: 20, merchant: "쿠팡이츠", amount: 13_900),
        CardTransaction(day: 20, merchant: "KICC(서울시인터넷)", amount: 50_000, isKBPay: true),
        CardTransaction(day: 14, merchant: "네이버페이", amount: 23_600),
        CardTransaction(day: 14, merchant: "쿠팡(와우 멤버십)", amount: 7_890),
        CardTransaction(day: 13, merchant: "네이버페이", amount: 63_000),
        CardTransaction(day: 12, merchant: "쿠팡(쿠페이)", amount: 21_160),
        CardTransaction(day: 9, merchant: "쿠팡(쿠페이)", amount: 36_570),
        CardTransaction(day: 9, merchant: "인터넷상거래", amount: 181_180,
                        installmentMonths: 2, isKBPay: true),
        // 카드사 앱 총액(633,220원 · 14건)과 맞추기 위한 나머지 3건.
        // 스크린샷에 안 잡힌 구간이라 개별 내역 대신 합계로만 둔다.
        CardTransaction(day: 6, merchant: "기타 3건", amount: 171_920, count: 3),
    ]

    /// 이번 사이클 요약.
    /// - Parameter today: 2026년 7월 기준 오늘 일자
    static func summary(today: Int = DemoClock.today,
                        transactions: [CardTransaction] = transactions) -> BillingSummary {
        let usage = transactions.reduce(0) { $0 + $1.amount }

        // 다음 결제일 청구액 = 일시불 전액 + 할부 1회차
        let dueNext = transactions.reduce(0) { $0 + $1.installmentAmount(round: 1) }

        // 그 다음 결제일 = 할부 2회차
        let carryover = transactions.reduce(0) { $0 + $1.installmentAmount(round: 2) }

        return BillingSummary(
            usage: usage,
            count: transactions.reduce(0) { $0 + $1.count },
            dueNext: dueNext,
            carryover: carryover,
            installments: transactions.filter(\.isInstallment),
            daysUntilClose: max(0, closingDay - today),
            periodLabel: "6/\(closingDay + 1)~7/\(closingDay)",
            closeLabel: "7월 \(closingDay)일",
            payLabel: "8월 \(payDay)일",
            nextPayLabel: "9월 \(payDay)일"
        )
    }

    /// 지금 카드로 `amount`를 더 쓰면 다음 결제일 청구가 얼마가 되는지.
    /// 마감(26일)을 넘겨 쓰면 한 사이클 뒤로 밀린다.
    static func projectedDue(adding amount: Int, on day: Int,
                             today: Int = DemoClock.today) -> Int {
        let base = summary(today: today).dueNext
        return day <= closingDay ? base + amount : base
    }
}
