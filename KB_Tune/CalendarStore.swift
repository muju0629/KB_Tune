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
        case .none:   // 타임아웃 — 응답 없음
            access = .notDetermined
            lastError = "캘린더 권한 응답이 없어요. 다시 시도하거나, 설정 앱에서 캘린더 접근을 켜주세요."
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

    // MARK: - 데모용 모의 일정
    //
    // 아이폰 **기본 캘린더**에 그대로 넣어 캘린더 앱에서 자연스럽게 보이게 한다.
    // 대신 메모에 숨은 마커를 심어, 삭제는 **마커가 있는 일정만** 대상으로 한다
    // → 사용자의 진짜 일정은 어떤 경우에도 지워지지 않는다.

    static let demoMarker = "KBTUNE_DEMO"

    private func writableCalendar() -> EKCalendar? {
        if let def = store.defaultCalendarForNewEvents, def.allowsContentModifications { return def }
        return store.calendars(for: .event).first { $0.allowsContentModifications }
    }

    /// 데모용 일정 5건을 기기 기본 캘린더에 생성 (기존 데모 일정은 먼저 정리).
    @discardableResult
    func seedDemoEvents() -> Int {
        guard access == .authorized, let cal = writableCalendar() else { return 0 }
        removeDemoEvents(refresh: false)

        // (제목, 며칠 뒤, 시작 시각, 소요 시간)
        let items: [(String, Int, Int, Int)] = [
            ("팀플 스터디", 1, 14, 2),
            ("동아리 정기모임", 2, 18, 3),
            ("생일파티 2차", 3, 19, 3),
            ("지민 결혼식", 4, 12, 3),
            ("영화 약속", 5, 15, 2),
        ]

        var made = 0
        let calc = Calendar.current
        for (title, offset, hour, hours) in items {
            guard let base = calc.date(byAdding: .day, value: offset, to: Date()) else { continue }
            var comp = calc.dateComponents([.year, .month, .day], from: base)
            comp.hour = hour
            guard let start = calc.date(from: comp) else { continue }

            let ev = EKEvent(eventStore: store)
            ev.calendar = cal
            ev.title = title
            ev.startDate = start
            ev.endDate = start.addingTimeInterval(TimeInterval(hours * 3600))
            ev.notes = Self.demoMarker      // 숨은 마커 — 삭제 대상 식별용
            if (try? store.save(ev, span: .thisEvent, commit: false)) != nil { made += 1 }
        }
        try? store.commit()
        fetchUpcoming()
        return made
    }

    /// 마커가 있는 데모 일정만 삭제 (사용자의 실제 일정은 절대 건드리지 않음).
    func removeDemoEvents(refresh: Bool = true) {
        let from = Date().addingTimeInterval(-60 * 60 * 24 * 60)
        let to = Date().addingTimeInterval(60 * 60 * 24 * 120)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        for ev in store.events(matching: predicate)
        where (ev.notes ?? "").contains(Self.demoMarker) {
            try? store.remove(ev, span: .thisEvent, commit: false)
        }
        try? store.commit()
        if refresh { fetchUpcoming() }
    }

    /// 현재 남아있는 데모 일정 수
    func demoEventCount() -> Int {
        let from = Date().addingTimeInterval(-60 * 60 * 24 * 60)
        let to = Date().addingTimeInterval(60 * 60 * 24 * 120)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).filter { ($0.notes ?? "").contains(Self.demoMarker) }.count
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
                    dayOfMonth: Calendar.current.component(.day, from: ek.startDate)
                )
            }
        _ = dayOfMonth
        didFetch = true
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
