//
//  DemoClock.swift
//  KB_Tune
//
//  앱을 켤 때마다 "오늘"을 실제 날짜에서 읽는다.
//
//  날짜는 7월 1일을 1로 세는 통산일 하나로 다룬다(8월 1일 = 32, 8월 31일 = 62).
//  달을 넘나드는 계산이 정수 덧셈으로 끝나기 때문이다 — 월말 일정을 다음 주로
//  옮기면 자연히 8월이 되고, 주차를 세거나 정렬할 때 달을 따로 볼 일이 없다.
//  화면에 보일 때만 이 값을 '몇 월 며칠'로 되돌린다.
//
//  데모 캘린더는 2026년 7~8월 페르소나(성제) 일정이라, 실제 오늘이 그 사이일 때만
//  그 날짜를 쓴다. 벗어나면 빈 달을 보여주게 되므로 시연 기준일로 되돌린다.
//

import Foundation

enum DemoClock {

    /// 데모 캘린더가 담고 있는 기간
    static let demoYear = 2026
    static let months = [7, 8]
    static let firstMonth = 7

    private static let lengths: [Int: Int] = [7: 31, 8: 31]

    /// 통산일의 마지막 날(8월 31일)
    static let lastDay = 62

    /// 데모 기간을 벗어났을 때 되돌아갈 시연 기준일(7월 22일)
    static let fallbackDay = 22

    /// 2026년 7월 1일은 수요일 — 요일 계산의 기준점.
    static let weekdayNames = ["수", "목", "금", "토", "일", "월", "화"]

    /// 테스트에서 날짜를 고정할 때만 쓴다. nil이면 실제 날짜를 읽는다.
    /// 이 자리가 없으면 날짜에 기댄 테스트가 하루만 지나도 깨진다.
    static var fixedToday: Int?

    /// 오늘(통산일). 앱을 켤 때마다 실제 날짜를 따라간다.
    static var today: Int {
        if let fixedToday { return fixedToday }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        guard c.year == demoYear, let m = c.month, let d = c.day, months.contains(m) else {
            return fallbackDay
        }
        return serial(month: m, day: d)
    }

    /// 실제 날짜가 데모 기간 안에 있는지. false면 캘린더는 시연 기준일로 고정된다.
    static var isLive: Bool {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return c.year == demoYear && months.contains(c.month ?? 0)
    }

    // MARK: 통산일 ↔ 월/일

    static func serial(month: Int, day: Int) -> Int {
        months.prefix { $0 < month }.reduce(day) { $0 + (lengths[$1] ?? 0) }
    }

    static func month(of day: Int) -> Int {
        var remaining = day
        for m in months {
            let len = lengths[m] ?? 0
            if remaining <= len { return m }
            remaining -= len
        }
        return months.last ?? firstMonth
    }

    static func dayOfMonth(of day: Int) -> Int {
        var remaining = day
        for m in months {
            let len = lengths[m] ?? 0
            if remaining <= len { return remaining }
            remaining -= len
        }
        return lengths[months.last ?? firstMonth] ?? 0
    }

    /// 그 달이 차지하는 통산일 구간. 7월 → 1...31, 8월 → 32...62
    static func range(of month: Int) -> ClosedRange<Int> {
        let start = serial(month: month, day: 1)
        return start...(start + (lengths[month] ?? 0) - 1)
    }

    /// `day`가 속한 달의 마지막 날(통산일)
    static func lastDayOfMonth(containing day: Int) -> Int { range(of: month(of: day)).upperBound }

    /// 그 달 1일이 월요일 기준으로 몇 칸 밀려 있는지 — 월간 격자의 앞 빈칸.
    static func firstWeekdayOffset(of month: Int) -> Int {
        let first = serial(month: month, day: 1)
        return ((first - 1) % weekdayNames.count + 2) % weekdayNames.count
    }

    static func weekday(of day: Int) -> String {
        weekdayNames[(day - 1) % weekdayNames.count]
    }

    // MARK: 주

    /// `day`가 속한 주의 월~일 범위. 달 경계는 잘라낸다 —
    /// 예산 장부가 "이 달 쓸 돈을 이 달의 주로 나눈다"를 전제로 하기 때문이다.
    static func weekRange(containing day: Int) -> ClosedRange<Int> {
        let offsetFromMonday = ((day - 1) % weekdayNames.count + 2) % weekdayNames.count
        let monday = day - offsetFromMonday
        let bounds = range(of: month(of: day))
        return max(bounds.lowerBound, monday)...min(bounds.upperBound, monday + 6)
    }

    // MARK: 표기

    /// "7/30" · "8/6"
    static func shortLabel(of day: Int) -> String { "\(month(of: day))/\(dayOfMonth(of: day))" }

    /// "7월 30일"
    static func dayLabel(of day: Int) -> String { "\(month(of: day))월 \(dayOfMonth(of: day))일" }

    /// "2026년 7월 26일 일요일"
    static func fullLabel(of day: Int) -> String {
        "\(demoYear)년 \(dayLabel(of: day)) \(weekday(of: day))요일"
    }

    /// "2026년 7월"
    static func monthLabel(of month: Int) -> String { "\(demoYear)년 \(month)월" }
}
