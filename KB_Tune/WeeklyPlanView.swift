//
//  WeeklyPlanView.swift
//  KB_Tune
//
//  계획 탭: [주간 | 월간] 토글 + 날짜/일정 탭 시 하루 타임테이블.
//  소비 방향은 월초에 온보딩에서 결정 — 이 화면에는 노출하지 않음.
//  위험 일정(예산 초과)은 차분한 주의 톤으로 취소·이동을 추천.
//

import SwiftUI

struct WeeklyPlanView: View {
    @EnvironmentObject private var model: AppModel

    enum Mode: String, CaseIterable { case week = "주간", month = "월간" }
    @State private var mode: Mode = .week
    @State private var selectedDay: PlanDay? = nil       // 타임테이블로 보는 날
    @State private var selectedMonthDay: Int? = nil      // 월간에서 탭한 (일정 없는) 날짜

    enum Sheet: Identifiable { case adjust, products, addEvent; var id: Int { hashValue } }
    @State private var sheet: Sheet?
    @State private var selectedAdjustment = "skip2cha"
    @State private var showSuccess = false
    @State private var toast: String?

    private let switchSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    var body: some View {
        ZStack(alignment: .bottom) {
            KB.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                modeToggle
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ScrollView {
                    Group {
                        if let day = selectedDay {
                            DayTimetableView(day: day,
                                             onClose: { withAnimation(switchSpring) { selectedDay = nil } },
                                             onAction: { flash($0) })
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else if mode == .week {
                            weekContent
                                .transition(.opacity)
                        } else {
                            monthContent
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(KB.ink.opacity(0.92), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .adjust: adjustSheet
            case .products: ProductsSheet().environmentObject(model)
            case .addEvent: AddEventView().environmentObject(model)
            }
        }
        .overlay { if showSuccess { successOverlay } }
    }

    // MARK: [주간 | 월간] 토글 — 타임테이블에서 누르면 해당 화면으로 복귀

    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                let isOn = mode == m && selectedDay == nil
                Button {
                    withAnimation(switchSpring) {
                        selectedDay = nil
                        mode = m
                    }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(KB.ink)
                        .frame(width: 76)
                        .padding(.vertical, 9)
                        .background(isOn ? KB.yellow : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(KB.line, lineWidth: 1))
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.selection, trigger: selectedDay?.dayNumber ?? -1)
    }

    // MARK: - 주간

    private var weekContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            weekStrip
            eventCards
            if model.riskyEvent != nil { riskBanner }
            recommendation
            contextNote
            actions
            benefitRow
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.referenceDateLabel) · \(model.userName)님")
                .font(.system(size: 13))
                .foregroundStyle(KB.muted)

            (Text("이번 주,\n")
             + Text(formatWon(model.weeklyBudget))
             + Text("까지 괜찮아요"))
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(KB.ink)
            .lineSpacing(4)
            .padding(.top, 14)
            .background(alignment: .bottomLeading) {
                KB.yellow.frame(width: 118, height: 9)
                    .offset(x: 0, y: -6)
            }

            Text("이번 주 예산에서 남은 금액이에요.\n계획된 지출을 바탕으로 안전하게 쓸 수 있어요.")
                .font(.system(size: 12.5))
                .foregroundStyle(KB.muted)
                .lineSpacing(3)
                .padding(.top, 14)
        }
    }

    /// 주간 날짜 스트립 — 날짜를 누르면 그 날 타임테이블
    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(model.week) { day in
                Button {
                    withAnimation(switchSpring) { selectedDay = day }
                } label: {
                    VStack(spacing: 6) {
                        Text(day.weekday).font(.system(size: 12)).foregroundStyle(KB.muted)
                        Text(day.dateLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KB.ink)
                            .frame(width: 36, height: 34)
                            .background {
                                if day.isToday {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(KB.yellowSoft)
                                }
                            }
                        Circle()
                            .fill(day.hasRisk ? KB.caution : (day.isToday ? KB.ink : (day.hasSpend ? KB.yellow : .clear)))
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 이번 주 지출 일정 카드 — 누르면 그 날 타임테이블
    private var eventCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.weekSpendItems) { item in
                    Button {
                        if let day = model.day(number: item.dayNumber) {
                            withAnimation(switchSpring) { selectedDay = day }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                IconBadge(systemName: item.symbol,
                                          background: item.isRisky ? KB.cautionSoft : (item.isProtected ? KB.greenSoft : KB.yellowSoft))
                                if item.isRisky {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(KB.caution)
                                        .offset(x: 4, y: -3)
                                }
                            }
                            Text(item.title).font(.system(size: 12)).foregroundStyle(KB.muted)
                                .lineLimit(1)
                            Text(formatWon(item.amount)).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KB.ink)
                            Text(item.dayLabel).font(.system(size: 10.5)).foregroundStyle(KB.muted)
                        }
                        .frame(width: 104)
                        .padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(item.isRisky ? KB.caution.opacity(0.45) : KB.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 위험 일정 배너 (차분한 주의) — 누르면 그 날 타임테이블
    private var riskBanner: some View {
        Button {
            if let day = model.riskyDay {
                withAnimation(switchSpring) { selectedDay = day }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(KB.caution)
                VStack(alignment: .leading, spacing: 3) {
                    Text("금요일 ‘\(model.riskyEvent?.title ?? "")’ 이 \(model.riskyEvent?.riskNote ?? "")")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(KB.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("취소하거나 다음 주로 옮기는 걸 추천해요 ")
                        .font(.system(size: 12))
                        .foregroundStyle(KB.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(KB.muted)
            }
            .padding(14)
            .background(KB.cautionSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(KB.caution.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var recommendation: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(KB.yellow).frame(width: 44, height: 44)
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(KB.ink)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.direction.note)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("적금 목표 달성 확률 \(model.probability)%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KB.green)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private var contextNote: some View {
        (Text("최근 3개월(\(model.analysisPeriod)) 소비와 ")
         + Text("‘\(model.protectedSummary)’").bold()
         + Text("를 반영했어요. 이번 달 방향은 ‘\(model.direction.label)’예요."))
        .font(.system(size: 12))
        .foregroundStyle(KB.muted)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { sheet = .addEvent } label: {
                HStack { Image(systemName: "plus"); Text("일정 추가하기") }
            }
            .buttonStyle(PrimaryButtonStyle())

            Button { showSuccess = true } label: {
                HStack { Text("일정 확정하기"); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)) }
            }
            .buttonStyle(SecondaryButtonStyle())

            Button { sheet = .adjust } label: {
                HStack { Text("다른 조정안 보기"); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)) }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var benefitRow: some View {
        Button { sheet = .products } label: {
            HStack(spacing: 12) {
                IconBadge(systemName: "magnifyingglass", background: KB.yellowSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("내 소비에 맞는 카드·적금 알아보기").font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                    Text("계획을 세운 뒤 참고할 수 있어요").font(.system(size: 12)).foregroundStyle(KB.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(KB.muted)
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 월간

    private var monthContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 헤더
            HStack(alignment: .top, spacing: 10) {
                Button {
                    withAnimation(switchSpring) { mode = .week }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(KB.ink)
                        .padding(.top, 5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.monthLabel)
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(KB.ink)
                    Text("지금 계획대로면 괜찮아요")
                        .font(.system(size: 13)).foregroundStyle(KB.muted)
                }
            }

            // 요약 — 캘린더 바로 위
            VStack(spacing: 0) {
                summaryLine("이번 달 남은 사용 가능액", formatWon(model.monthRemaining), highlight: true)
                Divider().overlay(KB.line)
                summaryLine("이번 주 예정 지출 \(model.weekSpendItems.count)건", formatWon(model.plannedSpendTotal))
                Divider().overlay(KB.line)
                summaryLine("적금 목표 확률", "\(model.probability)%", tint: KB.green)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            Text("‘\(model.protectedSummary)’를 반영한 계획이에요.")
                .font(.system(size: 12)).foregroundStyle(KB.muted)

            monthGrid

            // 선택 날짜 타임테이블 — 캘린더 아래 인라인
            monthDayDetail
        }
    }

    /// 월간에서 선택한(기본=오늘) 날짜의 하루 타임테이블
    private var monthDayDetail: some View {
        let d = selectedMonthDay ?? model.todayDayNumber
        let day = model.day(number: d)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("7월 \(d)일 \(weekdayName(d))요일")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.ink)
                if d == model.todayDayNumber {
                    Text("오늘").font(.system(size: 10.5, weight: .bold)).foregroundStyle(KB.ink)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(KB.yellow, in: Capsule())
                }
                Spacer()
                if let day, day.spendTotal > 0 {
                    Text("예상 지출 \(formatWon(day.spendTotal))")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted)
                }
            }

            if let day {
                DayTimetableBody(day: day, onAction: { flash($0) })
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(KB.muted)
                    Text("이 날은 예정된 지출이 없어요. 대화 탭에서 일정을 추가할 수 있어요.")
                        .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .id(d)
        .transition(.opacity)
    }

    /// 7월 날짜 → 요일 (7/1 = 수)
    private func weekdayName(_ d: Int) -> String {
        let names = ["월", "화", "수", "목", "금", "토", "일"]
        return names[(model.firstWeekdayOffset + d - 1) % 7]
    }

    private var monthGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(["월", "화", "수", "목", "금", "토", "일"], id: \.self) { w in
                    Text(w).font(.system(size: 12)).foregroundStyle(KB.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                // 7/1 = 수요일 → 월·화 빈칸
                ForEach(0..<model.firstWeekdayOffset, id: \.self) { _ in Color.clear.frame(height: 44) }
                ForEach(1...model.daysInMonth, id: \.self) { d in
                    monthDayCell(d)
                }
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func monthDayCell(_ d: Int) -> some View {
        let day = model.day(number: d)
        let isToday = d == model.todayDayNumber
        let isSelected = selectedMonthDay == d && !isToday
        return Button {
            withAnimation(.snappy(duration: 0.25)) { selectedMonthDay = d }
        } label: {
            VStack(spacing: 4) {
                Text("\(d)")
                    .font(.system(size: 13.5, weight: isToday ? .bold : .regular))
                    .foregroundStyle(KB.ink)
                    .frame(width: 30, height: 30)
                    .background {
                        if isToday { Circle().fill(KB.yellow) }
                        else if isSelected { Circle().stroke(KB.yellow, lineWidth: 2) }
                    }
                Circle()
                    .fill(day?.hasRisk == true ? KB.caution : (day?.hasSpend == true ? KB.yellow : .clear))
                    .frame(width: 4.5, height: 4.5)
            }
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selectedMonthDay)
    }

    private func summaryLine(_ title: String, _ value: String, highlight: Bool = false, tint: Color = KB.ink) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(highlight ? KB.ink : KB.muted)
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: - 시트 · 오버레이

    private var adjustSheet: some View {
        SheetContainer(title: "다른 조정안 보기") {
            Text("포기하고 싶지 않은 모임은 유지한 채 바꿀 수 있는 계획이에요.")
                .font(.system(size: 13)).foregroundStyle(KB.muted)

            VStack(spacing: 10) {
                ForEach(model.adjustments) { opt in
                    let isOn = selectedAdjustment == opt.id
                    Button { selectedAdjustment = opt.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 20)).foregroundStyle(isOn ? KB.ink : KB.line)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                                Text(opt.detail).font(.system(size: 12)).foregroundStyle(KB.muted)
                            }
                            Spacer()
                            Text(formatWon(opt.budget)).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                        }
                        .padding(14)
                        .background(isOn ? KB.yellowSoft : .white,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isOn ? KB.yellow : KB.line, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                let choice = model.adjustments.first { $0.id == selectedAdjustment }
                sheet = nil
                flash("\(choice?.title ?? "조정안")을 반영했어요.")
            } label: { Text("이 조정안 반영하기") }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
    }

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(KB.green)
                Text("일정을 확정했어요").font(.system(size: 19, weight: .bold)).foregroundStyle(KB.ink)
                Text("이번 주 계획을 반영했어요.\n\(formatWon(model.weeklyBudget))까지 쓸 수 있어요.")
                    .font(.system(size: 13)).foregroundStyle(KB.muted)
                    .multilineTextAlignment(.center).lineSpacing(3)
                Button { showSuccess = false } label: { Text("확인") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: 300)
            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 40)
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut) { toast = nil }
        }
    }
}

// MARK: - 하루 타임테이블

struct DayTimetableView: View {
    let day: PlanDay
    var onClose: () -> Void
    var onAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 헤더
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(KB.ink)
                }
                Text("7월 \(day.dayNumber)일 \(day.weekday)요일")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(KB.ink)
                if day.isToday {
                    Text("오늘").font(.system(size: 11, weight: .bold)).foregroundStyle(KB.ink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(KB.yellow, in: Capsule())
                }
                Spacer()
                if day.spendTotal > 0 {
                    Text("예상 지출 \(formatWon(day.spendTotal))")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(KB.muted)
                }
            }

            DayTimetableBody(day: day, onAction: onAction)
        }
    }
}

/// 하루 타임테이블 본문 (위험카드 + 시간표) — 주간 전체화면·월간 인라인 공용
struct DayTimetableBody: View {
    let day: PlanDay
    var onAction: (String) -> Void

    private let startHour: Double = 8
    private let endHour: Double = 24
    private let hourHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let risky = day.events.first(where: { $0.riskNote != nil }) {
                riskCard(risky)
            }
            if day.events.isEmpty {
                emptyState
            } else {
                timetable
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 26, weight: .light)).foregroundStyle(KB.muted)
            Text("예정된 변동지출이 없어요")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(KB.ink)
            Text("대화 탭에서 ‘일정 추가’라고 말해보세요")
                .font(.system(size: 12)).foregroundStyle(KB.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func riskCard(_ ev: DayEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15)).foregroundStyle(KB.caution)
                Text("‘\(ev.title)’ — \(ev.riskNote ?? "")")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ev.riskDetail ?? "")
                .font(.system(size: 13)).foregroundStyle(KB.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    onAction("‘\(ev.title)’를 다음 주로 옮겼어요. 사용 가능액과 목표 확률을 지켰어요.")
                } label: {
                    Text("다음 주로 옮기기")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(KB.yellow, in: Capsule())
                }
                Button {
                    onAction("일정을 유지했어요. 목표 확률이 낮아질 수 있어요.")
                } label: {
                    Text("그대로 둘게요")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.white, in: Capsule())
                        .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(KB.cautionSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(KB.caution.opacity(0.3), lineWidth: 1))
    }

    private var timetable: some View {
        let totalHeight = CGFloat(endHour - startHour) * hourHeight
        return ZStack(alignment: .topLeading) {
            // 시간 눈금
            VStack(spacing: 0) {
                ForEach(Int(startHour)..<Int(endHour), id: \.self) { h in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(h)시")
                            .font(.system(size: 10.5))
                            .foregroundStyle(KB.muted)
                            .frame(width: 34, alignment: .trailing)
                        VStack { Divider().overlay(KB.line.opacity(0.7)) }
                            .padding(.top, 7)
                    }
                    .frame(height: hourHeight, alignment: .top)
                }
            }

            // 일정 블록
            ForEach(day.events) { ev in
                eventBlock(ev)
                    .padding(.leading, 50)
                    .offset(y: CGFloat(ev.startHour - startHour) * hourHeight + 4)
            }
        }
        .frame(height: totalHeight)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func eventBlock(_ ev: DayEvent) -> some View {
        let height = max(CGFloat(ev.duration) * hourHeight - 8, 40)
        let isRisky = ev.riskNote != nil
        return HStack(alignment: .top, spacing: 10) {
            IconBadge(systemName: ev.symbol,
                      background: isRisky ? .white : (ev.isProtected ? .white : KB.yellowSoft),
                      size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ev.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink)
                    if ev.isProtected {
                        Image(systemName: "shield.fill").font(.system(size: 11)).foregroundStyle(KB.green)
                    }
                    if isRisky {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(KB.caution)
                    }
                }
                Text("\(hourString(ev.startHour))–\(hourString(ev.startHour + ev.duration))")
                    .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                Text(ev.amount > 0 ? formatWon(ev.amount) : "무지출")
                    .font(.system(size: 12.5, weight: ev.amount > 0 ? .semibold : .regular))
                    .foregroundStyle(ev.amount > 0 ? KB.ink : KB.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isRisky ? KB.cautionSoft : (ev.isProtected ? KB.greenSoft : .white),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isRisky ? KB.caution.opacity(0.4) : (ev.isProtected ? KB.green.opacity(0.35) : KB.line), lineWidth: 1))
    }

    private func hourString(_ h: Double) -> String {
        let hh = Int(h)
        let mm = Int((h - Double(hh)) * 60)
        return String(format: "%02d:%02d", hh, mm)
    }
}

/// 바텀시트 공통 컨테이너 (핸들 + 제목 + 콘텐츠)
struct SheetContainer<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(KB.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.muted)
                }
            }
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(KB.canvas)
    }
}

#Preview {
    WeeklyPlanView().environmentObject(AppModel())
}
