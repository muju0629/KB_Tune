//
//  WeeklyPlanView.swift
//  KB_Tune
//
//  주간·월간 계획 화면. 날짜/일정 탭 시 하루 타임테이블을 연다.
//  소비 방향과 설정은 상단에서, 상품은 계획을 세운 뒤 문맥적으로 진입한다.
//  위험 일정이 있으면 경고와 추천을 하나로 묶어 바로 조정할 수 있게 한다.
//

import SwiftUI

struct WeeklyPlanView: View {
    @EnvironmentObject private var model: AppModel

    enum Mode: String, CaseIterable { case week = "주간", month = "월간" }
    @State private var mode: Mode
    @State private var selectedDay: PlanDay? = nil       // 타임테이블로 보는 날
    @State private var selectedMonthDay: Int? = nil      // 월간에서 탭한 (일정 없는) 날짜

    enum Sheet: Identifiable { case products, addEvent, direction, settings; var id: Int { hashValue } }
    @State private var sheet: Sheet?
    @State private var showSuccess = false
    @State private var toast: String?

    private let switchSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    init(initialMode: Mode = .week) {
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            KB.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                planToolbar

                ScrollView {
                    Group {
                        if let day = selectedDay {
                            DayTimetableView(day: day,
                                             onClose: { withAnimation(switchSpring) { selectedDay = nil } },
                                             onAction: { flash($0) },
                                             onMove: { ev in
                                                 model.moveEventToNextWeek(ev, from: day.dayNumber)
                                                 // selectedDay 는 값 복사본 — 모델 변경 후 다시 읽어야 화면이 갱신된다
                                                 withAnimation(switchSpring) { selectedDay = model.day(number: day.dayNumber) }
                                             },
                                             onKeep: { ev in
                                                 model.acceptRisk(of: ev, on: day.dayNumber)
                                                 selectedDay = model.day(number: day.dayNumber)
                                             })
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
            case .products: ProductsSheet().environmentObject(model)
            case .addEvent: AddEventView().environmentObject(model)
            case .direction: directionSheet
            case .settings: SettingsView().environmentObject(model)
            }
        }
        .overlay { if showSuccess { successOverlay } }
    }

    // MARK: - 계획 맥락

    private var planToolbar: some View {
        HStack(spacing: 10) {
            Button { sheet = .direction } label: {
                HStack(spacing: 7) {
                    Text("이번 달 방향")
                        .font(.subheadline)
                        .foregroundStyle(KB.muted)
                    Text(model.direction.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KB.ink)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(KB.muted)
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 40)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(KB.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("이번 달 소비 방향")
            .accessibilityValue(model.direction.label)
            .accessibilityHint("두 번 탭하여 소비 방향을 바꿉니다")

            Spacer(minLength: 4)

            modeSwitcher

            Button { sheet = .settings } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(KB.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("내 계획과 설정")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { option in
                Button {
                    selectedDay = nil
                    withAnimation(switchSpring) { mode = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(mode == option ? KB.ink : KB.muted)
                        .frame(width: 38, height: 30)
                        .background(mode == option ? KB.yellowSoft : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(option == .week ? "plan-mode-week" : "plan-mode-month")
                .accessibilityLabel("\(option.rawValue) 보기")
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.white, in: Capsule())
        .overlay(Capsule().stroke(KB.line, lineWidth: 1))
    }

    // MARK: - 주간

    private var weekContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            weekStrip
            eventCards
            if !model.upcomingSpends.isEmpty { predictedSpends }
            recommendation
            actions
            benefitRow
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.referenceDateLabel) · \(model.userName)님")
                .font(.system(size: 13))
                .foregroundStyle(KB.muted)

            Text("이번 주,\n\(formatWon(roundedWeeklyBudget)) 더 쓸 수 있어요")
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(KB.ink)
            .lineSpacing(4)
            .padding(.top, 14)
            .background(alignment: .bottomLeading) {
                KB.yellow.frame(width: 118, height: 9)
                    .offset(x: 0, y: -6)
            }

            Text("7월 22일 이후 확정 일정을 먼저 뺐어요. 출근은 비용이 들지 않아요.")
                .font(.system(size: 12.5))
                .foregroundStyle(KB.muted)
                .lineSpacing(3)
                .padding(.top, 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("이번 주 추가 사용 가능액 약 \(formatWon(roundedWeeklyBudget)). 7월 22일 이후 확정 일정을 반영했습니다.")
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
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(day.weekday)요일 \(day.dateLabel)")
                .accessibilityValue(day.hasRisk ? "예산 조정이 필요한 일정 있음" : day.hasSpend ? "예정 지출 있음" : day.isToday ? "오늘" : "예정 지출 없음")
                .accessibilityHint("두 번 탭하여 하루 일정을 봅니다")
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
                                // 카드 배경이 상태색이라 배지는 흰색으로 둬야 아이콘이 보인다.
                                IconBadge(systemName: item.symbol, background: .white)
                                if item.isRisky {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(KB.caution)
                                        .offset(x: 4, y: -3)
                                }
                            }
                            Text(item.title).font(.system(size: 12)).foregroundStyle(KB.muted)
                                .lineLimit(1)
                            Text(estimateLabel(low: item.amountLow,
                                               high: item.amountHigh,
                                               estimated: item.isEstimated))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KB.ink)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(item.dayLabel).font(.system(size: 10.5)).foregroundStyle(KB.muted)
                        }
                        .frame(width: 104)
                        .padding(.vertical, 14)
                        .background(item.isRisky ? KB.cautionSoft : (item.isProtected ? KB.greenSoft : KB.yellowSoft),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(item.isRisky ? KB.caution.opacity(0.45) : (item.isProtected ? KB.green.opacity(0.35) : KB.yellow.opacity(0.55)), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.dayLabel), \(item.title), \(estimateLabel(low: item.amountLow, high: item.amountHigh, estimated: item.isEstimated))")
                    .accessibilityValue(item.isRisky ? "예산 조정 필요" : item.isProtected ? "더 필요한 소비로 남겨둔 일정" : "예정 지출")
                    .accessibilityHint("두 번 탭하여 하루 일정을 봅니다")
                }
            }
        }
    }

    /// 캘린더엔 없지만 과거 주기상 이번 주에 나갈 것 같은 지출.
    /// 확정이 아니므로 예산에서 미리 빼지 않고, 반영 여부를 사용자가 고른다.
    private var predictedSpends: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 13)).foregroundStyle(KB.ink)
                Text("이런 소비가 예상돼요").font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.ink)
                Spacer()
                Text("캘린더에 없는 지출").font(.system(size: 11)).foregroundStyle(KB.muted)
            }

            ForEach(model.upcomingSpends) { spend in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconBadge(systemName: spend.pattern.symbol, background: .white, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spend.pattern.key)
                                .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(KB.ink)
                            Text("7월 \(spend.expectedDay)일 즈음")
                                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                        }
                        Spacer(minLength: 8)
                        Text("예상 \(formatWon(spend.amount))")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(KB.ink)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }

                    // 왜 이 금액인지 — 과거 기록을 그대로 보여준다
                    VStack(alignment: .leading, spacing: 3) {
                        Text(spend.reason)
                            .font(.system(size: 12.5)).foregroundStyle(KB.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(SpendHistory.recordSummary(spend.pattern))
                            .font(.system(size: 11)).foregroundStyle(KB.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KB.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: 8) {
                        Button {
                            model.acceptPrediction(spend)
                            flash("‘\(spend.pattern.key)’ \(formatWon(spend.amount))을 계획에 넣었어요.")
                        } label: {
                            Text("계획에 넣기")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(KB.yellow, in: Capsule())
                        }
                        Button {
                            model.dismissPrediction(spend)
                            flash("이번엔 빼둘게요.")
                        } label: {
                            Text("이번엔 안 써요")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(.white, in: Capsule())
                                .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(spend.pattern.key) 예상 \(formatWon(spend.amount)). \(spend.reason)")
            }

            // 예상 소비가 예산을 넘으면 0원으로 뭉개지 말고 부족분을 밝힌다.
            Group {
                if model.predictedShortfall > 0 {
                    Text("모두 쓰면 \(formatWon(model.predictedShortfall)) 모자라요. 하나를 다음 주로 미루면 계획을 지킬 수 있어요.")
                        .foregroundStyle(KB.caution)
                } else {
                    Text("모두 반영하면 이번 주 사용 가능액은 \(formatWon(model.weeklyBudgetAfterPredictions))이 돼요.")
                        .foregroundStyle(KB.muted)
                }
            }
            .font(.system(size: 11.5))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recommendation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image("AgentMascot")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("이번 주 일정비는 \(formatWonRange(model.plannedSpendLow, model.plannedSpendHigh))이에요.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KB.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    // 주간 합계는 지나간 날까지 포함 — 남은 금액과 창이 달라 함께 밝힌다.
                    Text(model.remainingThisWeek > 0
                         ? "7월 22일 기준 아직 안 쓴 건 \(formatWon(model.remainingThisWeek))이에요."
                         : "이번 주 남은 확정 일정은 없어요.")
                        .font(.subheadline)
                        .foregroundStyle(KB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button {
                showSuccess = true
            } label: {
                HStack {
                    Text("계산 기준 보기")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(KB.ink)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(KB.yellow, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("이번 주 사용 가능액의 계산 기준을 봅니다")
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(KB.line, lineWidth: 1))
    }

    private var actions: some View {
        Button { sheet = .addEvent } label: {
            HStack { Image(systemName: "plus"); Text("일정 추가하기") }
        }
        .buttonStyle(SecondaryButtonStyle())
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
            VStack(alignment: .leading, spacing: 4) {
                Text(model.monthLabel)
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(KB.ink)
                Text("캘린더 일정으로 계산한 예상 금액이에요")
                    .font(.system(size: 13)).foregroundStyle(KB.muted)
            }

            // 요약 — 캘린더 바로 위
            VStack(spacing: 0) {
                summaryLine("7월 일정비 예상",
                            formatRange(low: model.julyEstimateLow, high: model.julyEstimateHigh),
                            highlight: true)
                Divider().overlay(KB.line)
                summaryLine("이번 주 일정비 예상",
                            formatRange(low: model.plannedSpendLow, high: model.plannedSpendHigh))
                Divider().overlay(KB.line)
                summaryLine("월말 여유 예상",
                            formatRange(low: model.monthEndRemainingLow, high: model.monthEndRemainingHigh),
                            tint: KB.green)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

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
                    Text(estimateLabel(low: day.spendLow, high: day.spendHigh, estimated: day.hasEstimate))
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted)
                }
            }

            if let day {
                DayTimetableBody(day: day, onAction: { flash($0) },
                                 onMove: { model.moveEventToNextWeek($0, from: day.dayNumber) },
                                 onKeep: { model.acceptRisk(of: $0, on: day.dayNumber) })
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
                .lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: - 시트 · 오버레이

    private var directionSheet: some View {
        SheetContainer(title: "이번 달 소비 방향") {
            Text("더 필요한 소비는 그대로 두고 이번 주 사용 가능액과 목표 확률을 다시 계산해요.")
                .font(.subheadline)
                .foregroundStyle(KB.muted)

            VStack(spacing: 10) {
                ForEach(SpendDirection.allCases) { direction in
                    let isSelected = model.direction == direction
                    Button {
                        model.direction = direction
                        sheet = nil
                        flash("이번 달 방향을 ‘\(direction.label)’로 바꿨어요.")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? KB.ink : KB.line)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(direction.label)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(KB.ink)
                                Text("이번 주 약 \(formatWon(roundToTenThousand(model.weeklyBudget(for: direction)))) · 목표 확률 \(model.probability(for: direction))%")
                                    .font(.subheadline)
                                    .foregroundStyle(KB.muted)
                            }
                            Spacer()
                        }
                        .padding(15)
                        .background(isSelected ? KB.yellowSoft : .white,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? KB.yellow : KB.line, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "equal.circle.fill").font(.system(size: 34)).foregroundStyle(KB.green)
                    Text("약 \(formatWon(roundedWeeklyBudget)) 계산 기준").font(.system(size: 19, weight: .bold)).foregroundStyle(KB.ink)
                }
                Text("월 수입 220만원은 아직 데모 가정이에요. 고정비는 확인한 값이고, 설정에서 언제든 바꿀 수 있어요.")
                    .font(.system(size: 13)).foregroundStyle(KB.muted).lineSpacing(3)
                VStack(spacing: 8) {
                    calculationRow("월 고정비", formatWon(BudgetEngine.fixed))
                    calculationRow("적금 목표", formatWon(model.savingsGoal))
                    calculationRow("7월 21일까지 일정비", formatWon(BudgetEngine.variableSpentToDate))
                    calculationRow("이번 주 남은 확정 일정", formatWon(BudgetEngine.committedThisWeek))
                    if model.userAddedThisWeek > 0 {
                        calculationRow("앱에서 추가한 일정", formatWon(model.userAddedThisWeek))
                    }
                    Divider().overlay(KB.line)
                    calculationRow("추가 사용 가능액", formatWon(model.weeklyBudget), emphasized: true)
                }
                Text("\(formatWon(BudgetEngine.remainingBudget(income: model.monthlyIncome, savingsGoal: model.savingsGoal))) ÷ 남은 2주 − 확정 일정 \(formatWon(BudgetEngine.committedThisWeek + model.userAddedThisWeek))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(KB.muted)
                Button { showSuccess = false } label: { Text("확인") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: 300)
            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 40)
        }
    }

    private var roundedWeeklyBudget: Int { roundToTenThousand(model.weeklyBudget) }

    private func calculationRow(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(emphasized ? KB.ink : KB.muted)
            Spacer()
            Text(value).fontWeight(emphasized ? .bold : .semibold).foregroundStyle(KB.ink)
        }
        .font(.system(size: 13))
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
    var onMove: ((DayEvent) -> Void)? = nil    // 위험 일정 → 다음 주로 이동
    var onKeep: ((DayEvent) -> Void)? = nil    // 위험 감수하고 유지(경고 해제)

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
                    Text(estimateLabel(low: day.spendLow, high: day.spendHigh, estimated: day.hasEstimate))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(KB.muted)
                }
            }

            DayTimetableBody(day: day, onAction: onAction, onMove: onMove, onKeep: onKeep)
        }
    }
}

/// 하루 타임테이블 본문 (위험카드 + 시간표) — 주간 전체화면·월간 인라인 공용
struct DayTimetableBody: View {
    let day: PlanDay
    var onAction: (String) -> Void
    var onMove: ((DayEvent) -> Void)? = nil
    var onKeep: ((DayEvent) -> Void)? = nil

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
                    onMove?(ev)
                    onAction("‘\(ev.title)’를 다음 주로 옮겼어요. 이번 주 사용 가능액을 지켰어요.")
                } label: {
                    Text("다음 주로 옮기기")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(KB.yellow, in: Capsule())
                }
                Button {
                    onKeep?(ev)
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
            // 블록 배경이 상태색이라 배지는 흰색으로 둬야 아이콘이 보인다.
            IconBadge(systemName: ev.symbol, background: .white, size: 34)
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
                Text(ev.amount > 0
                     ? estimateLabel(low: ev.amountLow, high: ev.amountHigh, estimated: ev.isEstimated)
                     : "비용 없음")
                    .font(.system(size: 12.5, weight: ev.amount > 0 ? .semibold : .regular))
                    .foregroundStyle(ev.amount > 0 ? KB.ink : KB.muted)
                // AI가 이력으로 채운 금액은 근거를 함께 보여준다
                if ev.isPredicted, let basis = ev.estimateBasis {
                    Text(basis)
                        .font(.system(size: 11)).foregroundStyle(KB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isRisky ? KB.cautionSoft : (ev.isProtected ? KB.greenSoft : KB.yellowSoft),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isRisky ? KB.caution.opacity(0.4) : (ev.isProtected ? KB.green.opacity(0.35) : KB.yellow.opacity(0.55)), lineWidth: 1))
    }

    private func hourString(_ h: Double) -> String {
        let hh = Int(h)
        let mm = Int((h - Double(hh)) * 60)
        return String(format: "%02d:%02d", hh, mm)
    }
}

private func roundToTenThousand(_ amount: Int) -> Int {
    Int((Double(amount) / 10_000).rounded()) * 10_000
}

private func formatRange(low: Int, high: Int) -> String {
    if low == high { return formatWon(low) }
    return "\(formatWon(low))~\(formatWon(high))"
}

private func estimateLabel(low: Int, high: Int, estimated: Bool) -> String {
    let prefix = estimated ? "예상 " : ""
    return prefix + formatRange(low: low, high: high)
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
