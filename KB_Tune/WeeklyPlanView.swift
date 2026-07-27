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
    @State private var scrolledWeek: Int? = nil          // 주간 스트립에서 보고 있는 주(가로 페이징)

    enum Sheet: Identifiable { case addEvent, settings; var id: Int { hashValue } }
    @State private var sheet: Sheet?
    @State private var showSuccess = false
    @State private var toast: String?
    @State private var showBillingDetail = false

    private let switchSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    private let scrollTopID = "planScrollTop"

    init(initialMode: Mode = .week) {
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            KB.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                planToolbar

                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear.frame(height: 0).id(scrollTopID)   // 맨 위 앵커 — 탭 재선택 시 여기로 되돌아온다
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
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            } else {
                                monthContent
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    // 결제예정 바가 가리지 않게 아래를 비워둔다.
                    // 월간·타임테이블로 넘어가면 아래로 미끄러져 나간다.
                    .safeAreaInset(edge: .bottom) {
                        if mode == .week && selectedDay == nil {
                            billingDock
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(switchSpring, value: mode)
                    .animation(switchSpring, value: selectedDay?.dayNumber)
                    // 하단 '주간' 탭을 다시 누르면 어디에 있든 주간 메인으로 되돌리고 맨 위로 부드럽게 스크롤한다.
                    .onChange(of: model.planResetToken) { _, _ in
                        withAnimation(switchSpring) {
                            selectedDay = nil
                            selectedMonthDay = nil
                            mode = .week
                            proxy.scrollTo(scrollTopID, anchor: .top)
                        }
                    }
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
            case .addEvent: AddEventView().environmentObject(model)
            case .settings: SettingsView().environmentObject(model)
            }
        }
        .overlay { if showSuccess { successOverlay } }
        .sheet(isPresented: $showBillingDetail) {
            BillingDetailSheet().environmentObject(model)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 계획 맥락

    /// 툴바에 띄울 날짜 — 오늘로 고정하지 않고 지금 화면에서 보고 있는 날을 따라간다.
    private var viewedDay: Int {
        if let selectedDay { return selectedDay.dayNumber }
        if mode == .month { return selectedMonthDay ?? model.todayDayNumber }
        return model.todayDayNumber
    }

    private var planToolbar: some View {
        HStack(spacing: 10) {
            Text("7월 \(viewedDay)일 \(weekdayName(viewedDay))요일")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(KB.ink)
                .accessibilityLabel(viewedDay == model.todayDayNumber
                                    ? "오늘 7월 \(viewedDay)일 \(weekdayName(viewedDay))요일"
                                    : "7월 \(viewedDay)일 \(weekdayName(viewedDay))요일")

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
            hero.appearStagger(0)
            if model.shouldShowDailyClose { dailyCloseCard.appearStagger(1) }
            cardBillingCard.appearStagger(2)
            weekStripPager.appearStagger(3)
            spendTimeline.appearStagger(4)
            if !model.upcomingSpends.isEmpty { predictedSpends.appearStagger(5) }
            recommendation.appearStagger(6)
            actions.appearStagger(7)
            benefitRow.appearStagger(8)
        }
    }

    /// 화면 맨 아래 붙어 있는 결제예정 바 — KB Pay 홈의 시그니처.
    /// 카드 앱에서 제일 중요한 숫자는 스크롤 위치와 상관없이 늘 보여야 한다.
    private var billingDock: some View {
        let b = model.billing
        return Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showBillingDetail = true }
        } label: {
            HStack(spacing: 8) {
                Text("결제예정금액").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink)
                DDayBadge(days: b.daysUntilPay)
                Spacer()
                Text(formatWon(b.dueNext)).money(16.5).foregroundStyle(KB.ink)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(KB.ink.opacity(0.55))
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(KB.yellow)
        }
        .buttonStyle(.plain)
    }

    /// 하루 마감 — 예정돼 있었는데 카드 결제 기록이 없는 지출만 뜬다(기획 보고서 8.2).
    /// KB Pay 연동 시 카드로 결제된 건 자동 확정되므로, 여기선 "현금으로 쓰셨나요?"만 되묻는다.
    private var dailyCloseCard: some View {
        let items = model.todayCloseItems
        let total = items.reduce(0) { $0 + $1.amount }
        let names = items.map(\.title).joined(separator: "·")
        return VStack(alignment: .leading, spacing: 12) {
            LabelBadge(text: "확인 필요", color: KB.caution)
            Text("결제 기록이 없는 지출이 있어요")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.ink)
            Text("‘\(names)’에 \(formatWon(total)) 쓸 예정이었는데 카드 결제 기록이 없어요. 현금으로 결제하셨나요?")
                .font(.system(size: 13)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(items) { ev in
                    HStack {
                        Text(ev.title).font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                        Spacer()
                        Text(formatWon(ev.amount)).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                    }
                }
            }
            .padding(10)
            .background(KB.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    model.resolveDailyClose(paidCash: true)
                    flash("현금 지출로 확인했어요. \(formatWon(total))을 이번 달 지출에 반영했어요.")
                } label: {
                    Text("현금으로 결제했어요")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(KB.yellow, in: Capsule())
                }

                Button {
                    model.resolveDailyClose(paidCash: false)
                    flash("아직 안 쓴 걸로 두고 예정 예산은 그대로 둘게요.")
                } label: {
                    Text("아직 안 썼어요")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .elevatedCard(16)
    }

    /// 다음 결제일에 실제로 빠질 카드값 (기획 보고서 7.3 '카드 결제예정액').
    ///
    /// 카드사 앱은 '이용금액'만 보여줘서 할부가 다음 달로 얼마나 밀리는지 알기 어렵다.
    /// 여기선 이용금액과 실제 청구액을 나눠 보여주고, 이용기간 마감이 임박하면
    /// 하루 차이로 결제일이 한 달 밀린다는 점을 알려준다.
    private var cardBillingCard: some View {
        let b = model.billing
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                LabelBadge(text: "카드값", color: KB.tangerine)
                DDayBadge(days: b.daysUntilPay)
                Spacer()
                Text("KB ALL").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(KB.ink)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(KB.yellowSoft, in: Capsule())
            }

            Text("\(b.payLabel)에 빠질 카드값")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.ink)

            CountUpWon(value: b.dueNext, size: 30)

            Text("이용기간 \(b.periodLabel)에 \(b.count)건 \(formatWon(b.usage))을 썼어요. 그중 \(formatWon(b.deferred))은 할부라 \(b.nextPayLabel)로 넘어가요.")
                .font(.system(size: 13)).foregroundStyle(KB.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !b.installments.isEmpty {
                VStack(spacing: 6) {
                    ForEach(b.installments) { tx in
                        HStack {
                            Text("\(tx.merchant) \(tx.installmentMonths)개월")
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("월 \(formatWon(tx.installmentAmount(round: 1)))")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.caution)
                        }
                    }
                }
                .padding(10)
                .background(KB.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: model.isBillingCloseDay ? "exclamationmark.circle.fill" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(model.isBillingCloseDay ? KB.caution : KB.muted)
                Text(billingCloseNote(b))
                    .font(.system(size: 12)).foregroundStyle(model.isBillingCloseDay ? KB.caution : KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard(16)
    }

    private func billingCloseNote(_ b: BillingSummary) -> String {
        if model.isBillingCloseDay {
            return "오늘이 이용기간 마지막 날이에요. 오늘 쓰면 \(b.payLabel)에, 내일 쓰면 \(b.nextPayLabel)에 빠져나가요."
        }
        if b.daysUntilClose > 0 {
            return "\(b.closeLabel)까지 \(b.daysUntilClose)일 남았어요. 그때까지 쓴 돈이 \(b.payLabel)에 한 번에 빠져요."
        }
        return "이번 이용기간은 마감됐어요. 지금 쓰는 돈은 \(b.nextPayLabel)에 빠져나가요."
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.userName)님의 이번 주 일정비는 \(formatWon(model.plannedSpendTotal))")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(KB.muted)

            // 화면에서 가장 큰 숫자라 더 조용하게 — 마지막 3%만 움직인다.
            CountUpWon(value: roundedWeeklyBudget, size: 46, weight: .heavy, from: 0.97)
                .padding(.trailing, 2)
                .background(alignment: .bottom) {
                    KB.yellow.frame(height: 13)
                        .padding(.horizontal, -4)
                        .offset(y: -5)
                }
                .padding(.top, 2)

            Text("더 쓸 수 있어요")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(KB.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("이번 주 일정비 \(formatWon(model.plannedSpendTotal)), 추가 사용 가능액 약 \(formatWon(roundedWeeklyBudget)).")
    }

    /// 주간 날짜 스트립 — 가로로 넘기면 다른 주(3주차·4주차…)를 본다. 날짜를 누르면 그 날 타임테이블.
    private var weekStripPager: some View {
        let viewed = scrolledWeek ?? model.currentWeekIndex
        return VStack(spacing: 10) {
            HStack {
                Text("7월 \(viewed + 1)주차")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                if viewed == model.currentWeekIndex {
                    Text("이번 주").font(.system(size: 10.5, weight: .bold)).foregroundStyle(KB.ink)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(KB.yellow, in: Capsule())
                }
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(model.julyWeeks.enumerated()), id: \.offset) { index, slots in
                            HStack(spacing: 0) {
                                ForEach(Array(slots.enumerated()), id: \.offset) { _, dayNumber in
                                    if let dayNumber, let day = model.day(number: dayNumber) {
                                        dayColumn(day)
                                    } else {
                                        Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                                    }
                                }
                            }
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledWeek)
                .onAppear {
                    if scrolledWeek == nil {
                        scrolledWeek = model.currentWeekIndex
                        proxy.scrollTo(model.currentWeekIndex, anchor: .center)
                    }
                }
            }
        }
    }

    /// 스트립 한 칸(하루). 여러 주에 걸쳐 재사용.
    private func dayColumn(_ day: PlanDay) -> some View {
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

    /// 이번 주 지출을 세로 타임라인으로 — 일자별 노드를 수직선으로 잇는다. 항목을 누르면 그 날 타임테이블.
    private var spendTimeline: some View {
        let groups = Dictionary(grouping: model.weekSpendItems, by: \.dayNumber)
            .sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 15)).foregroundStyle(KB.green)
                    Text("이번 주 예정된 지출이 없어요.").font(.system(size: 13)).foregroundStyle(KB.muted)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.key) { index, entry in
                    timelineDay(dayNumber: entry.key, items: entry.value, isLast: index == groups.count - 1)
                }
            }
        }
    }

    private func timelineDay(dayNumber: Int, items: [WeekSpendItem], isLast: Bool) -> some View {
        let isToday = model.day(number: dayNumber)?.isToday == true
        let risky = items.contains { $0.isRisky }
        let nodeColor = risky ? KB.caution : (isToday ? KB.ink : KB.yellow)
        let total = items.reduce(0) { $0 + $1.amount }
        return HStack(alignment: .top, spacing: 14) {
            // 레일: 노드 + 아래로 잇는 수직선 (마지막 날은 선 없음)
            VStack(spacing: 0) {
                Circle().fill(nodeColor).frame(width: 11, height: 11).padding(.top, 3)
                if !isLast {
                    Rectangle().fill(KB.line).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 11)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(items.first?.dayLabel ?? "")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.ink)
                    if isToday {
                        Text("오늘").font(.system(size: 9.5, weight: .bold)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(KB.yellow, in: Capsule())
                    }
                    Spacer()
                    Text(formatWon(total))
                        .money(12.5, weight: .semibold).foregroundStyle(KB.muted)
                }
                ForEach(items) { item in
                    Button {
                        if let d = model.day(number: item.dayNumber) {
                            withAnimation(switchSpring) { selectedDay = d }
                        }
                    } label: { timelineItemRow(item) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.dayLabel), \(item.title), \(estimateLabel(low: item.amountLow, high: item.amountHigh, estimated: item.isEstimated))")
                    .accessibilityValue(item.isRisky ? "예산 조정 필요" : item.isProtected ? "더 필요한 소비로 남겨둔 일정" : "예정 지출")
                    .accessibilityHint("두 번 탭하여 하루 일정을 봅니다")
                }
            }
            .padding(.bottom, isLast ? 0 : 20)
        }
    }

    private func timelineItemRow(_ item: WeekSpendItem) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemName: item.symbol,
                      background: item.isRisky ? KB.cautionSoft : (item.isProtected ? KB.greenSoft : KB.yellowSoft),
                      size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
                    if item.isProtected {
                        Image(systemName: "shield.fill").font(.system(size: 10)).foregroundStyle(KB.green)
                    }
                    if item.isRisky {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(KB.caution)
                    }
                    if item.state == .reserved { stateBadge(.reserved) }
                }
                HStack(spacing: 6) {
                    Text(estimateLabel(low: item.amountLow, high: item.amountHigh, estimated: item.isEstimated))
                        .money(12.5, weight: .medium).foregroundStyle(KB.muted)
                    if let purpose = item.purpose {
                        Text(purpose).font(.system(size: 10.5, weight: .medium)).foregroundStyle(KB.muted)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(KB.line.opacity(0.4), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(KB.muted.opacity(0.6))
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .elevatedCard(14)
    }

    /// 캘린더엔 없지만 과거 주기상 이번 주에 나갈 것 같은 지출.
    /// 확정이 아니므로 예산에서 미리 빼지 않고, 반영 여부를 사용자가 고른다.
    private var predictedSpends: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                LabelBadge(text: "AI 예측", color: KB.violet)
                Text("이런 소비가 예상돼요").font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.ink)
                Spacer()
                Text("캘린더에 없는 지출").font(.system(size: 11)).foregroundStyle(KB.muted)
            }

            ForEach(model.upcomingSpends, id: \.pattern.key) { spend in
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
                            .money(14, weight: .bold).foregroundStyle(KB.ink)
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
                            flash("‘\(spend.pattern.key)’ \(formatWon(spend.amount))을 계획에 넣었어요.")
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                model.acceptPrediction(spend)
                            }
                        } label: {
                            Text("계획에 넣기")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(KB.yellow, in: Capsule())
                        }
                        Button {
                            flash("이번엔 빼둘게요.")
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                model.dismissPrediction(spend)
                            }
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
                .padding(16)
                .elevatedCard(16)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
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
                         ? "7월 \(model.todayDayNumber)일 기준 아직 안 쓴 건 \(formatWon(model.remainingThisWeek))이에요."
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
        .padding(18)
        .elevatedCard(18)
    }

    private var actions: some View {
        Button { sheet = .addEvent } label: {
            HStack { Image(systemName: "plus"); Text("일정 추가하기") }
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var benefitRow: some View {
        Button { model.selectedTab = .products } label: {
            HStack(spacing: 12) {
                IconBadge(systemName: "magnifyingglass", background: KB.yellowSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("내 소비에 맞는 카드·적금 알아보기").font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                    Text("계획을 세운 뒤 참고할 수 있어요").font(.system(size: 12)).foregroundStyle(KB.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(KB.muted)
            }
            .padding(16)
            .elevatedCard(16)
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
                Text("타임테이블")
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
            VStack(spacing: 2) {
                Text("\(d)")
                    .font(.system(size: 13.5, weight: isToday ? .bold : .regular))
                    .foregroundStyle(KB.ink)
                    .frame(width: 30, height: 30)
                    .background {
                        if isToday { Circle().fill(KB.yellow) }
                        else if isSelected { Circle().stroke(KB.yellow, lineWidth: 2) }
                    }
                if let day, day.spendTotal > 0 {
                    Text(compactSpend(day.spendTotal))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KB.expenseRed)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(height: 50, alignment: .top)
            .frame(maxWidth: .infinity)
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
                    calculationRow("7월 \(model.todayDayNumber - 1)일까지 일정비", formatWon(BudgetEngine.variableSpentToDate))
                    if BudgetEngine.installmentCarryover > 0 {
                        calculationRow("할부로 다음 달에 넘어갈 돈", formatWon(BudgetEngine.installmentCarryover))
                    }
                    calculationRow("이번 주 남은 확정 일정", formatWon(BudgetEngine.committedThisWeek))
                    if model.userAddedThisWeek > 0 {
                        calculationRow("앱에서 추가한 일정", formatWon(model.userAddedThisWeek))
                    }
                    Divider().overlay(KB.line)
                    calculationRow("추가 사용 가능액", formatWon(model.weeklyBudget), emphasized: true)
                }
                Text("\(formatWon(BudgetEngine.remainingBudget(income: model.monthlyIncome, savingsGoal: model.savingsGoal))) ÷ 남은 \(BudgetEngine.remainingWeeks)주 − 확정 일정 \(formatWon(BudgetEngine.committedThisWeek + model.userAddedThisWeek))")
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
            // 헤더 — 화면 성격("타임테이블")을 제목으로, 날짜는 보조 정보로 아래에 둔다.
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(KB.ink)
                }
                // 날짜는 상단 툴바가 따라오므로 여기서는 화면 성격만 밝힌다.
                Text("타임테이블")
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
    private let gutter: CGFloat = 50        // 시간 눈금이 차지하는 왼쪽 폭
    private let columnGap: CGFloat = 6      // 좌우로 나뉜 블록 사이 간격

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

    /// 일정 블록의 가로 배치 결과 — 같은 시간대에 몰린 일정을 몇 번째 열에 놓을지.
    private struct EventSlot: Identifiable {
        let event: DayEvent
        let column: Int
        let columnCount: Int
        var id: DayEvent.ID { event.id }
    }

    /// 블록이 실제로 차지하는 세로 길이(시간 환산).
    /// 내용이 duration보다 길면 블록이 늘어나므로, 겹침 판정도 이 값으로 해야 한다.
    /// 실제 렌더 높이보다 조금 넉넉하게 잡는다 — 과하게 잡으면 불필요하게 열이 나뉠 뿐이지만,
    /// 모자라게 잡으면 블록이 겹쳐 보인다.
    private func occupiedHours(_ ev: DayEvent) -> Double {
        let content: CGFloat = (ev.isPredicted && ev.estimateBasis != nil) ? 112 : 80
        return Double(max(CGFloat(ev.duration) * hourHeight, content) / hourHeight)
    }

    /// 겹치는 일정끼리 묶어 좌우로 나눈다 (캘린더 앱과 같은 방식).
    private var placedEvents: [EventSlot] {
        var slots: [EventSlot] = []
        var cluster: [(event: DayEvent, column: Int)] = []   // 서로 겹쳐 폭을 나눠 쓸 일정들
        var columnEnds: [Double] = []                        // 열별로 마지막 일정이 끝나는 지점
        var clusterEnd = -Double.infinity

        // 열 개수는 묶음 전체가 같아야 폭이 어긋나지 않으므로, 묶음이 끝난 뒤 한꺼번에 확정한다.
        func flush() {
            slots += cluster.map { EventSlot(event: $0.event, column: $0.column, columnCount: columnEnds.count) }
            cluster = []
            columnEnds = []
        }

        for ev in day.events.sorted(by: { $0.startHour < $1.startHour }) {
            if ev.startHour >= clusterEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= ev.startHour } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(0) }
            columnEnds[column] = ev.startHour + occupiedHours(ev)
            cluster.append((ev, column))
            clusterEnd = max(clusterEnd, columnEnds[column])
        }
        flush()
        return slots
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

            // 일정 블록 — 겹치는 일정은 좌우로 나눠 놓는다
            GeometryReader { geo in
                let lane = geo.size.width - gutter
                ForEach(placedEvents) { slot in
                    let width = (lane - CGFloat(slot.columnCount - 1) * columnGap) / CGFloat(slot.columnCount)
                    eventBlock(slot.event)
                        .frame(width: width)
                        .offset(x: gutter + CGFloat(slot.column) * (width + columnGap),
                                y: CGFloat(slot.event.startHour - startHour) * hourHeight + 4)
                }
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
                    if ev.state == .reserved { stateBadge(.reserved) }
                }
                HStack(spacing: 6) {
                    Text("\(hourString(ev.startHour))–\(hourString(ev.startHour + ev.duration))")
                        .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                    if let purpose = ev.purpose {
                        Text(purpose).font(.system(size: 10, weight: .medium)).foregroundStyle(KB.muted)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(KB.line.opacity(0.4), in: Capsule())
                    }
                }
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
        .frame(minHeight: height, alignment: .top)
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

/// 월간 캘린더 날짜 칸처럼 좁은 자리에 넣는 축약 지출 표기 (예: -73,000 → "-7.3만")
private func compactSpend(_ amount: Int) -> String {
    if amount < 10_000 { return "-\(decimalString(amount))" }
    let man = (Double(amount) / 1_000).rounded() / 10
    return man == man.rounded() ? "-\(Int(man))만" : String(format: "-%.1f만", man)
}

private func formatRange(low: Int, high: Int) -> String {
    if low == high { return formatWon(low) }
    return "\(formatWon(low))~\(formatWon(high))"
}

private func estimateLabel(low: Int, high: Int, estimated: Bool) -> String {
    let prefix = estimated ? "예상 " : ""
    return prefix + formatRange(low: low, high: high)
}

/// 확정·예약·예상 상태를 구분하는 작은 배지(기획 보고서 11.1). 확정은 기본 상태라 표시하지 않는다.
@ViewBuilder
private func stateBadge(_ state: SpendState) -> some View {
    switch state {
    case .reserved:
        HStack(spacing: 2) {
            Image(systemName: "clock.fill").font(.system(size: 8))
            Text("예약").font(.system(size: 9.5, weight: .bold))
        }
        .foregroundStyle(KB.ink)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(KB.yellowSoft, in: Capsule())
    case .pattern:
        HStack(spacing: 2) {
            Image(systemName: "wand.and.stars").font(.system(size: 8))
            Text("예상").font(.system(size: 9.5, weight: .bold))
        }
        .foregroundStyle(KB.muted)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(KB.line.opacity(0.35), in: Capsule())
    case .confirmed:
        EmptyView()
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
