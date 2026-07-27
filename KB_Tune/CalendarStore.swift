//
//  CalendarStore.swift
//  KB_Tune
//
//  기기 캘린더(EventKit) 연동. 권한 요청 → 이번 주 일정 읽기.
//  iOS 17+ 전체 접근 API 사용. 권한 설명은 Info.plist(NSCalendarsFullAccessUsageDescription)에 있음.
//

import EventKit
import SwiftUI
import Combine

@MainActor
final class CalendarStore: ObservableObject {

    enum Access {
        case notDetermined   // 아직 요청 전
        case authorized      // 접근 허용
        case denied          // 거부됨 (설정에서 변경 필요)
    }

    @Published var access: Access = .notDetermined
    @Published var events: [PlanEvent] = []
    @Published var isLoading = false
    @Published var didFetch = false
    @Published var lastError: String?      // 권한 타임아웃 등 사용자 안내 문구

    private let store = EKEventStore()

    init() {
        refreshAccessStatus()
    }

    /// 현재 권한 상태 반영
    func refreshAccessStatus() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .authorized
        case .denied, .restricted, .writeOnly:
            access = .denied
        default:
            access = .notDetermined
        }
    }

    /// 권한 요청 후 이번 주 일정 읽기.
    /// 시뮬레이터 등에서 권한 팝업이 응답하지 않아도 **무한 대기하지 않도록** 타임아웃을 둔다.
    func connect() async {
        isLoading = true
        defer { isLoading = false }

        switch await requestAccess(timeout: 12) {
        case .some(true):
            access = .authorized
            lastError = nil
            fetchThisWeek()
        case .some(false):
            access = .denied
            lastError = nil
        case .none:
            // 타임아웃. 사용자가 뒤늦게 허용했을 수 있으니 시스템 상태를 다시 읽는다 —
            // 안 그러면 실제로는 허용됐는데 화면은 계속 '연결 안 됨'으로 남는다.
            refreshAccessStatus()
            if access == .authorized {
                lastError = nil
                fetchThisWeek()
            } else {
                lastError = "캘린더 권한 응답이 없어요. 다시 시도하거나, 설정 앱에서 캘린더 접근을 켜주세요."
            }
        }
    }

    /// 권한 요청 + 타임아웃. 반환 nil = 응답 없음.
    /// 콜백 API를 써서 어떤 경우에도 정확히 한 번만 재개되도록 보장한다.
    private func requestAccess(timeout seconds: Double) async -> Bool? {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            var resumed = false
            // 두 경로 모두 메인 큐로 모아 경합 없이 한 번만 재개
            func finish(_ value: Bool?) {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { finish(granted) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(nil) }
        }
    }

    // MARK: 쓰기 — 앱에서 잡은 일정을 기기 캘린더에 남긴다

    /// `day`는 7월 1일을 1로 세는 통산일이라, 실제 달력으로 되돌려서 쓴다.
    private func date(day: Int, hour: Double) -> Date? {
        var comps = DateComponents()
        comps.year = DemoClock.demoYear
        comps.month = DemoClock.month(of: day)
        comps.day = DemoClock.dayOfMonth(of: day)
        comps.hour = Int(hour)
        comps.minute = Int((hour - Double(Int(hour))) * 60)
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    /// 일정을 기본 캘린더에 쓰고 식별자를 돌려준다. 권한이 없거나 실패하면 nil.
    /// 이 식별자가 있어야 나중에 같은 일정을 지우거나 시간을 옮길 수 있다.
    func save(title: String, day: Int, startHour: Double, duration: Double) -> String? {
        guard access == .authorized, let start = date(day: day, hour: startHour) else { return nil }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(duration * 3600)
        event.calendar = store.defaultCalendarForNewEvents
        event.notes = "KB Tune에서 예산을 잡은 일정이에요."

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            lastError = "캘린더에 일정을 쓰지 못했어요. 설정에서 캘린더 접근을 확인해 주세요."
            return nil
        }
    }

    /// 앱이 쓴 일정을 기기 캘린더에서 지운다.
    /// 식별자가 있는 일정만 지우므로, 사용자가 캘린더 앱에서 직접 만든 일정은 건드리지 않는다.
    @discardableResult
    func remove(eventID: String) -> Bool {
        guard access == .authorized,
              let event = store.event(withIdentifier: eventID) else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            lastError = "캘린더에서 일정을 지우지 못했어요."
            return false
        }
    }

    /// 시작 시각을 옮긴다(길이는 그대로 유지).
    @discardableResult
    func reschedule(eventID: String, day: Int, startHour: Double) -> Bool {
        guard access == .authorized,
              let event = store.event(withIdentifier: eventID),
              let oldStart = event.startDate, let oldEnd = event.endDate,
              let start = date(day: day, hour: startHour) else { return false }

        let length = oldEnd.timeIntervalSince(oldStart)
        event.startDate = start
        event.endDate = start.addingTimeInterval(length)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            lastError = "캘린더에서 일정 시간을 바꾸지 못했어요."
            return false
        }
    }

    /// 다가오는 N일간의 기기 캘린더 일정 (일정 추가 화면의 '가져오기' 목록용).
    /// iCloud뿐 아니라 설정에서 추가한 구글·네이버 캘린더 일정도 함께 읽힌다.
    func fetchUpcoming(days: Int = 30) {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) HH:mm"

        let dayOfMonth = Calendar.current.component(.day, from: now)

        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(50)
            .map { ek in
                PlanEvent(
                    title: ek.title ?? "일정",
                    amount: 0,
                    symbol: "calendar",
                    dayLabel: formatter.string(from: ek.startDate),
                    fromDeviceCalendar: true,
                    dayOfMonth: Self.serialDay(of: ek.startDate)
                )
            }
        _ = dayOfMonth
        didFetch = true
    }

    /// 기기 캘린더의 실제 날짜를 앱이 쓰는 통산일로 옮긴다. 데모 기간 밖이면 0.
    static func serialDay(of date: Date) -> Int {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard c.year == DemoClock.demoYear, let m = c.month, let d = c.day,
              DemoClock.months.contains(m) else { return 0 }
        return DemoClock.serial(month: m, day: d)
    }

    /// 이번 주(오늘 기준) 기기 캘린더 일정 로드
    func fetchThisWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // 월요일 시작
        let now = Date()
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return }

        let predicate = store.predicateForEvents(
            withStart: week.start,
            end: week.end,
            calendars: nil
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "E M/d"

        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { ek in
                PlanEvent(
                    title: ek.title ?? "일정",
                    amount: 0, // 예상 지출은 사용자가 지정 (또는 에이전트가 추정)
                    symbol: "calendar",
                    dayLabel: formatter.string(from: ek.startDate),
                    fromDeviceCalendar: true
                )
            }
        didFetch = true
    }
}
