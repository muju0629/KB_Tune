//
//  DemoClock.swift
//  KB_Tune
//
//  앱을 켤 때마다 "오늘"을 실제 날짜에서 읽는다.
//
//  데모 캘린더는 2026년 7월 페르소나(성제) 일정이라, 실제 오늘이 2026년 7월일 때만
//  그 날짜를 쓴다. 7월을 벗어나면 빈 달을 보여주게 되므로 시연 기준일(22일)로 되돌린다.
//  월이 넘어가도 캘린더가 살아 있게 하려면 시드 일정을 현재 월의 같은 요일로
//  재배치해야 하는데, 그건 별도 작업으로 남겨뒀다.
//

import Foundation

enum DemoClock {

    /// 데모 캘린더가 담고 있는 달
    static let demoYear = 2026
    static let demoMonth = 7
    static let daysInMonth = 31

    /// 7월을 벗어났을 때 되돌아갈 시연 기준일
    static let fallbackDay = 22

    /// 2026년 7월 1일은 수요일 — 요일 계산의 기준점.
    static let weekdayNames = ["수", "목", "금", "토", "일", "월", "화"]

    /// 실제 날짜가 2026년 7월 안에 있는지. false면 캘린더는 시연 기준일로 고정된다.
    static var isLive: Bool {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return c.year == demoYear && c.month == demoMonth
    }

    /// 테스트에서 날짜를 고정할 때만 쓴다. nil이면 실제 날짜를 읽는다.
    /// 이 자리가 없으면 날짜에 기댄 테스트가 하루만 지나도 깨진다.
    static var fixedToday: Int?

    /// 오늘 일자. 앱을 켤 때마다 실제 날짜를 따라간다.
    static var today: Int {
        if let fixedToday { return fixedToday }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        guard c.year == demoYear, c.month == demoMonth, let d = c.day else { return fallbackDay }
        return d
    }

    static func weekday(of day: Int) -> String {
        weekdayNames[(day - 1) % weekdayNames.count]
    }

    /// `day`가 속한 주의 월~일 범위(7월 밖은 잘라낸다).
    static func weekRange(containing day: Int) -> ClosedRange<Int> {
        // 월요일은 weekdayNames 에서 인덱스 5 → 월요일까지 거슬러 올라갈 칸 수
        let offsetFromMonday = ((day - 1) % weekdayNames.count + 2) % weekdayNames.count
        let monday = day - offsetFromMonday
        return max(1, monday)...min(daysInMonth, monday + 6)
    }

    /// "2026년 7월 26일 일요일"
    static func fullLabel(of day: Int) -> String {
        "\(demoYear)년 \(demoMonth)월 \(day)일 \(weekday(of: day))요일"
    }
}
