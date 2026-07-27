//
//  WeekLedger.swift
//  KB_Tune
//
//  주차별 예산 장부 — 이번 주에 얼마를 더 쓸 수 있는지, 왜 그 금액인지.
//
//  계산 순서는 사용자가 머릿속으로 하는 것과 같게 맞췄다.
//    ① 월 수입에서 고정비·적금·다음 달로 넘어갈 할부를 뺀다 → 이 달에 쓸 수 있는 돈
//    ② 그 돈을 이 달의 주 수로 나눈다                      → 한 주에 배분되는 기본 금액
//    ③ 지난주에 남긴(또는 넘긴) 금액을 더한다              → 이번 주에 실제로 배분된 금액
//    ④ 이번 주 일정비를 뺀다                               → 추가로 더 쓸 수 있는 여유
//
//  ③이 핵심이다. 지난주에 아껴 쓰면 이번 주가 넉넉해지고, 넘겨 쓰면 이번 주가 줄어든다.
//  "왜 이번 주는 더 많지?"에 답할 수 있어야 사용자가 계획을 믿는다.
//
//  마지막 주의 여유는 결국 (한 달에 쓸 수 있는 돈 − 한 달 일정비 전체)와 같아진다.
//  중간에 어떻게 나누든 총량은 보존된다.
//

import Foundation

struct WeekBudget: Identifiable {
    let index: Int                 // 0-based. 화면의 "N주차"는 index + 1
    var month: Int = DemoClock.firstMonth
    let days: ClosedRange<Int>     // 이 달에서 이 주가 걸치는 날짜
    let baseAllowance: Int         // 이 달에 쓸 수 있는 돈 ÷ 주 수
    let rollover: Int              // 지난주에서 넘어온 금액(음수면 넘겨 쓴 것)
    let plannedSpend: Int          // 이 주에 잡힌 일정비

    var id: Int { index }
    var label: String { "\(month)월 \(index + 1)주차" }

    /// 이번 주에 실제로 배분된 금액
    var allowance: Int { baseAllowance + rollover }
    /// 일정비를 빼고 남은 여유. 다음 주로 넘어가는 값이기도 하다(음수 가능).
    var carriesForward: Int { allowance - plannedSpend }
    /// 화면에 띄우는 "더 쓸 수 있는 금액" — 음수는 0으로 보여주되 넘긴 사실은 따로 알린다.
    var available: Int { max(0, carriesForward) }
    var isOverspent: Bool { carriesForward < 0 }
}

enum WeekLedger {

    /// 한 달을 월요일 시작 주 단위로 쪼갠다. 달의 첫날·마지막 날이 낀 주는 잘린 채로 둔다.
    /// 날짜는 통산일이라 8월도 같은 방식으로 나뉜다.
    static func weekRanges(month: Int = DemoClock.firstMonth) -> [ClosedRange<Int>] {
        let bounds = DemoClock.range(of: month)
        var ranges: [ClosedRange<Int>] = []
        var day = bounds.lowerBound
        while day <= bounds.upperBound {
            let range = DemoClock.weekRange(containing: day)
            ranges.append(range)
            day = range.upperBound + 1
        }
        return ranges
    }

    /// 주차별 장부를 처음부터 순서대로 만든다. 각 주의 잔액이 다음 주 이월로 들어간다.
    /// - Parameters:
    ///   - spendByWeek: 주차 index → 그 주의 일정비
    ///   - openingRollover: 지난달에서 넘어온 금액(첫 주의 이월)
    static func build(disposable: Int,
                      spendByWeek: [Int: Int],
                      openingRollover: Int = 0,
                      month: Int = DemoClock.firstMonth) -> [WeekBudget] {
        let ranges = weekRanges(month: month)
        guard !ranges.isEmpty else { return [] }

        let base = disposable / ranges.count
        var carried = openingRollover
        var result: [WeekBudget] = []

        for (i, range) in ranges.enumerated() {
            let week = WeekBudget(index: i, month: month, days: range, baseAllowance: base,
                                  rollover: carried, plannedSpend: spendByWeek[i] ?? 0)
            result.append(week)
            carried = week.carriesForward
        }
        return result
    }

    /// 달이 끝났을 때 다음 달로 넘길 금액 — 마지막 주의 잔액.
    static func closingRollover(_ weeks: [WeekBudget]) -> Int {
        weeks.last?.carriesForward ?? 0
    }

    /// 다음 달 첫 주가 어떻게 시작되는지 미리 보여준다.
    ///
    /// 이번 달에 아껴 쓴 만큼이 다음 달 첫 주에 얹힌다는 걸 눈으로 봐야
    /// "지금 아끼면 뭐가 좋은지"가 손에 잡힌다. 이월을 만들어놓고 결과를 안 보여주면
    /// 사용자는 그게 실제로 돌아가는지 알 수 없다.
    static func nextMonthOpening(disposable: Int,
                                 carriedIn: Int,
                                 weeksInNextMonth: Int = 5) -> WeekBudget {
        WeekBudget(index: 0, month: DemoClock.months.last ?? DemoClock.firstMonth, days: 1...7,
                   baseAllowance: disposable / max(1, weeksInNextMonth),
                   rollover: carriedIn,
                   plannedSpend: 0)
    }
}
