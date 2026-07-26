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
