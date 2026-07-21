//
//  Models.swift
//  KB_Tune
//
//  데이터 모델 + 앱 상태.
//  데모 페르소나: 김민지(22) · 대학 3학년 · 카페 알바(월 80만원) · 동아리 활동
//  기준일 2026-07-21(화) · 분석기간 2026.04~06
//

import SwiftUI
import Combine

// MARK: - 소비 방향

enum SpendDirection: String, CaseIterable, Identifiable {
    case reduce, maintain, increase
    var id: String { rawValue }

    var label: String {
        switch self {
        case .reduce: "줄이기"
        case .maintain: "유지"
        case .increase: "늘리기"
        }
    }

    /// 이번 주 사용 가능액
    var budget: Int {
        switch self {
        case .reduce: 38_000
        case .maintain: 52_000
        case .increase: 70_000
        }
    }

    /// 적금 목표 달성 확률(%)
    var probability: Int {
        switch self {
        case .reduce: 86
        case .maintain: 78
        case .increase: 69
        }
    }

    /// 에이전트 조언 문구
    var note: String {
        switch self {
        case .reduce: "약속은 지키고, 이번 주 변동지출을 조금 가볍게 잡았어요."
        case .maintain: "동아리 모임은 그대로 가세요. 금요일 2차만 조정하면 돼요."
        case .increase: "이번 달 여유를 늘렸어요. 적금 목표 확률은 조금 낮아져요."
        }
    }
}

// MARK: - 하루 일정(타임테이블)

struct DayEvent: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var startHour: Double     // 19.0 = 19:00, 17.5 = 17:30
    var duration: Double      // 시간 단위
    var amount: Int           // 0 = 무지출 일정(수업·알바 등)
    var isProtected: Bool = false
    var riskNote: String? = nil     // 위험 일정 한 줄 요약
    var riskDetail: String? = nil   // 상세 설명 + 추천
}

struct PlanDay: Identifiable {
    let id = UUID()
    var weekday: String       // "월"
    var dateLabel: String     // "7/20"
    var dayNumber: Int        // 20
    var isToday: Bool = false
    var events: [DayEvent] = []

    var spendTotal: Int { events.reduce(0) { $0 + $1.amount } }
    var hasSpend: Bool { events.contains { $0.amount > 0 } }
    var hasRisk: Bool { events.contains { $0.riskNote != nil } }
}

/// 주간 지출 카드용 파생 아이템
struct WeekSpendItem: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var dayLabel: String      // "금 7/24"
    var dayNumber: Int
    var amount: Int
    var isProtected: Bool
    var isRisky: Bool
}

// MARK: - 기기 캘린더 행(EventKit 연동용)

struct PlanEvent: Identifiable {
    let id = UUID()
    var title: String
    var amount: Int
    var symbol: String
    var dayLabel: String
    var featured: Bool = false
    var fromDeviceCalendar: Bool = false
    var dayOfMonth: Int = 0     // 기기 캘린더에서 가져온 일정의 '일'
}

// MARK: - 조정안 · 소비 카테고리

struct AdjustmentOption: Identifiable {
    let id: String
    var title: String
    var detail: String
    var budget: Int
}

struct SpendCategory: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let total3m: Int          // 최근 3개월 합계
    var monthly: Int { total3m / 3 }
}

// MARK: - 앱 상태

final class AppModel: ObservableObject {
    // 페르소나
    let userName = "민지"
    let userAge = 22          // 상품 추천 연령 하드필터용

    @Published var hasOnboarded = false

    // 온보딩 입력값 (페르소나 기본값)
    @Published var usesDemoData = true
    @Published var monthlyIncome = 800_000    // 카페 알바
    @Published var savingsGoal = 200_000
    @Published var protectedTags: Set<String> = ["모임"]
    @Published var hobbies: Set<String> = []  // 좋아하고 지키고 싶은 것들(통합 서베이)

    /// 취향 → 상품 매칭 태그 변환 (Products.matchTags와 맞춤)
    var interestTags: Set<String> {
        var tags: Set<String> = []
        for h in hobbies {
            switch h {
            case "음식", "카페": tags.insert("외식")
            case "술", "모임": tags.insert("모임")
            case "가족": tags.insert("가족")
            default: tags.insert("취미")
            }
        }
        return tags
    }

    // 계획 상태 (방향은 월초에 한 번 결정)
    @Published var direction: SpendDirection = .maintain

    var weeklyBudget: Int { direction.budget }
    var probability: Int { direction.probability }
    var protectedSummary: String { "모임은 포기하지 않기" }

    let referenceDateLabel = "2026년 7월 21일 화요일"
    let analysisPeriod = "2026.04~06"

    // MARK: 이번 주 일정 (민지의 한 주)

    let week: [PlanDay] = [
        PlanDay(weekday: "월", dateLabel: "7/20", dayNumber: 20, events: [
            DayEvent(title: "전공 수업", symbol: "book", startHour: 10, duration: 3, amount: 0),
        ]),
        PlanDay(weekday: "화", dateLabel: "7/21", dayNumber: 21, isToday: true, events: [
            DayEvent(title: "전공 수업", symbol: "book", startHour: 10, duration: 2, amount: 0),
            DayEvent(title: "카페 알바", symbol: "cup.and.saucer", startHour: 17, duration: 5, amount: 0),
        ]),
        PlanDay(weekday: "수", dateLabel: "7/22", dayNumber: 22, events: [
            DayEvent(title: "팀플 스터디", symbol: "person.3", startHour: 14, duration: 2, amount: 8_000),
        ]),
        PlanDay(weekday: "목", dateLabel: "7/23", dayNumber: 23, events: [
            DayEvent(title: "동아리 정기모임", symbol: "person.2", startHour: 18, duration: 3, amount: 25_000, isProtected: true),
        ]),
        PlanDay(weekday: "금", dateLabel: "7/24", dayNumber: 24, events: [
            DayEvent(title: "카페 알바", symbol: "cup.and.saucer", startHour: 12, duration: 4, amount: 0),
            DayEvent(title: "생일파티 2차", symbol: "party.popper", startHour: 19, duration: 3, amount: 40_000,
                     riskNote: "이번 주 예산을 36,000원 넘겨요",
                     riskDetail: "그대로 가면 적금 목표 확률이 78% → 61%로 떨어져요. 1차까지만 하거나 다음 주로 옮기는 걸 추천해요."),
        ]),
        PlanDay(weekday: "토", dateLabel: "7/25", dayNumber: 25, events: [
            DayEvent(title: "영화 관람", symbol: "film", startHour: 15, duration: 2.5, amount: 15_000),
        ]),
        PlanDay(weekday: "일", dateLabel: "7/26", dayNumber: 26),
    ]

    var weekSpendItems: [WeekSpendItem] {
        week.flatMap { day in
            day.events
                .filter { $0.amount > 0 }
                .map { ev in
                    WeekSpendItem(title: ev.title, symbol: ev.symbol,
                                  dayLabel: "\(day.weekday) \(day.dateLabel)",
                                  dayNumber: day.dayNumber,
                                  amount: ev.amount,
                                  isProtected: ev.isProtected,
                                  isRisky: ev.riskNote != nil)
                }
        }
    }

    var plannedSpendTotal: Int { weekSpendItems.reduce(0) { $0 + $1.amount } }

    /// 이번 주 위험 일정 (예산 초과)
    var riskyDay: PlanDay? { week.first { $0.hasRisk } }
    var riskyEvent: DayEvent? { riskyDay?.events.first { $0.riskNote != nil } }

    func day(number: Int) -> PlanDay? { week.first { $0.dayNumber == number } }

    // MARK: 월간 (2026년 7월)

    let monthLabel = "2026년 7월"
    let daysInMonth = 31
    let firstWeekdayOffset = 2        // 7/1 = 수요일 (월요일 시작 기준 빈칸 2)
    let todayDayNumber = 21
    var weekDayNumbers: ClosedRange<Int> { 20...26 }
    let monthRemaining = 208_000      // 이번 달 남은 사용 가능액(데모)

    // MARK: 조정안

    let adjustments: [AdjustmentOption] = [
        AdjustmentOption(id: "skip2cha", title: "금요일 2차를 다음 주로", detail: "모임은 지키고 적금 확률 78% 유지", budget: 52_000),
        AdjustmentOption(id: "first-only", title: "2차 대신 1차까지만", detail: "예상 지출 40,000 → 15,000원", budget: 27_000),
        AdjustmentOption(id: "movie", title: "영화를 다음 주로 옮기기", detail: "적금 확률 74%", budget: 37_000),
    ]

    // MARK: 최근 3개월 소비 프로파일 (대학생 스케일)

    let spendProfile: [SpendCategory] = [
        SpendCategory(name: "외식", symbol: "fork.knife", total3m: 210_000),
        SpendCategory(name: "술·모임", symbol: "wineglass", total3m: 180_000),
        SpendCategory(name: "쇼핑", symbol: "handbag", total3m: 120_000),
        SpendCategory(name: "카페", symbol: "cup.and.saucer", total3m: 96_000),
        SpendCategory(name: "교통", symbol: "bus", total3m: 90_000),
        SpendCategory(name: "배달", symbol: "bag", total3m: 60_000),
        SpendCategory(name: "구독", symbol: "play.rectangle", total3m: 45_000),
    ]
    private let diningLikeNames: Set<String> = ["외식", "배달", "카페"]
    var diningLike3m: Int { spendProfile.filter { diningLikeNames.contains($0.name) }.reduce(0) { $0 + $1.total3m } }
    var diningLikeMonthly: Int { diningLike3m / 3 }
    var spendTotal3m: Int { spendProfile.reduce(0) { $0 + $1.total3m } }
    var spendMonthly: Int { spendTotal3m / 3 }
}

// 온보딩 통합 서베이 후보 (좋아하는 것 + 지키고 싶은 것)
let keepCandidates: [(tag: String, label: String, symbol: String)] = [
    ("모임", "모임·친구", "person.2"),
    ("영화", "영화", "film"),
    ("카페", "카페", "cup.and.saucer"),
    ("음식", "맛집·음식", "fork.knife"),
    ("여행", "여행", "airplane"),
    ("운동", "운동", "figure.run"),
    ("전시", "전시·공연", "paintpalette"),
    ("게임", "게임", "gamecontroller"),
    ("가족", "가족", "house"),
    ("경조사", "경조사", "gift"),
]
