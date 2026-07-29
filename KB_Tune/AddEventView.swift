//
//  AddEventView.swift
//  KB_Tune
//
//  제품 핵심 루프 — 일정 추가 → 예상 지출 자동 추정 → 영향(사용가능액·목표확률) → 조정안.
//  기준: prompts/04_CALENDAR_EVENT_DECISION.md
//
//  입력 경로 2가지
//    · 직접 입력            : 제목·날짜를 사용자가 씀
//    · 캘린더에서 가져오기   : EventKit으로 기기 캘린더(iCloud·구글·네이버 동기화분 포함) 읽기
//  추정은 과거 소비 이력 + 온디바이스 EventEstimator가 맡는다.
//

import SwiftUI

struct AddEventView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var calendar = CalendarStore()

    enum Source: String, CaseIterable { case manual = "직접 입력", device = "캘린더에서" }
    enum Step { case input, result, done }

    @State private var source: Source = .manual
    @State private var step: Step = .input

    @State private var title = ""
    @State private var date: Date = AddEventView.defaultDate   // 날짜+시간을 함께 고른다
    @State private var estimate: EstimateResponse?
    @State private var amount = 0            // 사용자가 조정 가능한 최종 금액
    @State private var amountText = ""       // 입력 단계에서 사용자가 직접 적은 금액(비면 추정치 사용)
    @State private var suggested: EstimateResponse?  // 제목으로 미리 잡은 회색 예상 금액
    @State private var isEstimating = false
    @State private var chosenAdjustment: String?
    /// 기기 캘린더에서 읽은 일정은 이미 EventKit에 존재한다. 다시 save하면
    /// 같은 일정이 두 개 생기므로 앱 모델에만 연결한다.
    @State private var importedFromDeviceCalendar = false

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    // 오늘부터 데모 캘린더 마지막 날(8월 말)까지 고르게 한다.
    private static let cal = Calendar(identifier: .gregorian)

    /// 통산일을 실제 달력 날짜로 — 날짜 선택기는 진짜 Date 를 다뤄야 해서.
    private static func date(_ day: Int, hour: Int, minute: Int) -> Date {
        cal.date(from: DateComponents(year: DemoClock.demoYear,
                                      month: DemoClock.month(of: day),
                                      day: DemoClock.dayOfMonth(of: day),
                                      hour: hour, minute: minute))!
    }
    private static var defaultDate: Date { date(DemoClock.today, hour: 19, minute: 0) }
    private static var dateRange: ClosedRange<Date> {
        date(DemoClock.today, hour: 0, minute: 0)...date(DemoClock.lastDay, hour: 23, minute: 59)
    }
    /// 고른 날짜를 다시 통산일로 되돌린다.
    private var dayNumber: Int {
        DemoClock.serial(month: Self.cal.component(.month, from: date),
                         day: Self.cal.component(.day, from: date))
    }
    private var startHour: Double {
        Double(Self.cal.component(.hour, from: date)) + Double(Self.cal.component(.minute, from: date)) / 60
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .input:  inputStep
                    case .result: resultStep
                    case .done:   doneStep
                    }
                }
                .padding(20)
            }
            .background(KB.canvas)
            .navigationTitle(step == .done ? "추가 완료" : "일정 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == .result {
                        Button { withAnimation(spring) { step = .input } } label: {
                            Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(KB.ink)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(KB.muted)
                    }
                }
            }
        }
    }

    // MARK: - 1단계: 입력

    private var inputStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 경로 선택
            HStack(spacing: 0) {
                ForEach(Source.allCases, id: \.self) { s in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { source = s }
                        if s == .manual { importedFromDeviceCalendar = false }
                        if s == .device { Task { await loadDeviceEvents() } }
                    } label: {
                        Text(s.rawValue)
                            .font(.kb(14, source == s ? .semibold : .regular))
                            .foregroundStyle(source == s ? KB.onYellow : KB.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(source == s ? KB.yellow : .clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(KB.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(KB.line, lineWidth: 1))
            .sensoryFeedback(.selection, trigger: source)

            if source == .manual { manualInput } else { deviceInput }
        }
    }

    private var manualInput: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("무슨 일정인가요?").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
                TextField("예: 지민 결혼식, 동아리 회식", text: $title)
                    .font(.kb(16))
                    .padding(14)
                    .background(KB.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                    .submitLabel(.done)
                    .onChange(of: title) { _, newValue in
                        let t = newValue.trimmingCharacters(in: .whitespaces)
                        suggested = t.isEmpty ? nil : EventEstimator.estimate(t)
                    }
            }

            // 예상 지출 금액 — 제목으로 잡은 추정치를 회색으로 미리 얹어두고,
            // 사용자가 직접 적으면 그 값이 우선한다(회색 안내는 사라진다).
            VStack(alignment: .leading, spacing: 8) {
                Text("예상 지출 금액").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
                HStack(spacing: 6) {
                    TextField("", text: $amountText,
                              prompt: Text(suggested.map { formatWon($0.amount) } ?? "금액을 입력하세요"))
                        .font(.kb(16))
                        .keyboardType(.numberPad)
                    if !amountText.isEmpty {
                        Text("원").font(.kb(16)).foregroundStyle(KB.muted)
                    }
                }
                .padding(14)
                .background(KB.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))

                if amountText.isEmpty, let s = suggested, s.amount > 0 {
                    Text(s.basis)
                        .font(.kb(12)).foregroundStyle(KB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("언제예요?").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
                DatePicker("", selection: $date, in: Self.dateRange,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .tint(KB.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(KB.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
            }

            Button { runEstimate() } label: {
                if isEstimating { ProgressView().tint(KB.ink) }
                else { Text("예상 지출 계산하기") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isEstimating)
            .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            hint("금액을 비워 두면 과거 소비를 바탕으로 잡은 예상 금액을 그대로 써요.")
        }
    }

    private var deviceInput: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch calendar.access {
            case .notDetermined:
                VStack(alignment: .leading, spacing: 12) {
                    Text("기기 캘린더에서 일정을 가져올게요")
                        .font(.kb(15, .semibold)).foregroundStyle(KB.ink)
                    Text("아이폰 캘린더에 있는 일정을 읽어와요. 설정에 추가한 구글·네이버 캘린더 일정도 함께 보여요. 내용은 기기에서만 사용해요.")
                        .font(.kb(13)).foregroundStyle(KB.muted).lineSpacing(2)
                    Button { Task { await loadDeviceEvents() } } label: {
                        if calendar.isLoading { ProgressView().tint(KB.ink) } else { Text("캘린더 불러오기") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
                .background(KB.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    Text("캘린더 접근이 꺼져 있어요").font(.kb(15, .semibold)).foregroundStyle(KB.ink)
                    Text("설정 → 개인정보 보호 → 캘린더에서 켤 수 있어요. 직접 입력으로도 추가할 수 있어요.")
                        .font(.kb(13)).foregroundStyle(KB.muted)
                    Button { withAnimation(.snappy) { source = .manual } } label: { Text("직접 입력으로 추가") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
                .background(KB.cautionSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(KB.caution.opacity(0.3), lineWidth: 1))

            case .authorized:
                if calendar.events.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar").foregroundStyle(KB.muted)
                        Text("앞으로 30일간 등록된 일정이 없어요. 직접 입력으로 추가해 보세요.")
                            .font(.kb(12.5)).foregroundStyle(KB.muted)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("가져올 일정을 선택하세요")
                        .font(.kb(13, .semibold)).foregroundStyle(KB.muted)
                    ForEach(calendar.events) { ev in
                        Button {
                            title = ev.title
                            if (DemoClock.today...DemoClock.lastDay).contains(ev.dayOfMonth) {
                                let hour = Int(ev.startHour)
                                let minute = Int((ev.startHour - Double(hour)) * 60)
                                date = Self.date(ev.dayOfMonth, hour: hour, minute: minute)
                            }
                            importedFromDeviceCalendar = true
                            runEstimate()
                        } label: {
                            HStack(spacing: 12) {
                                IconBadge(systemName: "calendar", background: KB.yellowSoft, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title).font(.kb(14.5, .medium))
                                        .foregroundStyle(KB.ink).lineLimit(1)
                                    Text(ev.dayLabel).font(.kb(12)).foregroundStyle(KB.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(KB.muted)
                            }
                            .padding(14)
                            .background(KB.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isEstimating {
                HStack(spacing: 8) { ProgressView().tint(KB.muted); Text("예상 지출을 계산하는 중…")
                    .font(.kb(12.5)).foregroundStyle(KB.muted) }
            }
        }
    }

    /// 카드로 결제한다고 보면 이 지출이 어느 결제일에 얹히는지 (기획 보고서 7.3).
    /// 이용기간(26일)을 넘겨 쓰면 한 달 뒤 결제일로 밀린다 — 그 차이를 여기서 보여준다.
    @ViewBuilder
    private var cardImpactRow: some View {
        let b = model.billing
        let paymentLabel = BillingCycle.paymentLabel(for: dayNumber)
        if BillingCycle.isInReferenceStatement(dayNumber) {
            impactRow("\(paymentLabel) 카드 청구액",
                      from: formatWon(b.dueNext),
                      to: formatWon(BillingCycle.projectedDue(adding: amount, on: dayNumber)),
                      warn: false, tint: KB.ink)
        } else {
            HStack {
                Text("\(paymentLabel) 카드 청구액").font(.kb(13)).foregroundStyle(KB.muted)
                Spacer()
                Text("+\(formatWon(amount))").font(.kb(13, .semibold))
                    .foregroundStyle(KB.ink)
            }
        }
    }

    // MARK: - 2단계: 추정 결과 + 영향 + 조정안

    private var resultStep: some View {
        // '전'은 이미 추가한 일정까지 반영된 현재값 — model.weeklyBudget/probability와 같은 기준.
        let before = model.weeklyBudget(for: model.direction, on: dayNumber)
        let after = before - amount
        let probBefore = model.probability(for: model.direction, on: dayNumber)
        let probAfter = model.probability(for: model.direction,
                                          extraCommitted: amount, on: dayNumber)
        let risky = (probBefore - probAfter) >= 10 || after < 0

        return VStack(alignment: .leading, spacing: 18) {
            // 추정 결과
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(KB.ink)
                    Text("예상 지출을 이렇게 잡았어요").font(.kb(13, .semibold)).foregroundStyle(KB.ink)
                    Spacer()
                    if let e = estimate {
                        Text(e.category).font(.kb(11, .medium)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(KB.yellowSoft, in: Capsule())
                    }
                }
                Text(title).font(.kb(17, .bold)).foregroundStyle(KB.ink)
                Text(DemoClock.dayLabel(of: dayNumber)).font(.kb(12.5)).foregroundStyle(KB.muted)

                HStack {
                    Text(formatWon(amount))
                        .font(.kb(26, .bold)).foregroundStyle(KB.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: amount)
                    Spacer()
                    Stepper("", value: $amount, in: 0...500_000, step: 5_000).labelsHidden()
                }
                .padding(.top, 2)

                if let e = estimate {
                    Text(e.basis).font(.kb(12)).foregroundStyle(KB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("예상 범위 \(formatWon(e.low))~\(formatWon(e.high))")
                        Text("·")
                        Text("신뢰도 \(Int(e.confidence * 100))%")
                        Text("·")
                        Text(e.method == "local" ? "기기 계산" : "서버 추정")
                    }
                    .font(.kb(11)).foregroundStyle(KB.muted.opacity(0.9))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))

            // 영향
            VStack(alignment: .leading, spacing: 10) {
                Text("이 일정을 넣으면").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
                impactRow("이번 주 추가 사용 가능액", from: formatWon(before), to: formatWon(max(after, 0)),
                          warn: after < 0)
                impactRow("적금 목표 확률", from: "\(probBefore)%", to: "\(probAfter)%",
                          warn: (probBefore - probAfter) >= 10)
                cardImpactRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(risky ? KB.cautionSoft : KB.greenSoft,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            // 조정안 (위험할 때만)
            if risky {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                            .foregroundStyle(KB.caution)
                        Text("이대로면 계획이 흔들려요").font(.kb(13, .semibold))
                            .foregroundStyle(KB.ink)
                    }
                    adjustmentRow(id: "keep", title: "그대로 추가",
                                  detail: "추가 사용 가능액 \(formatWon(max(after, 0))) · 확률 \(probAfter)%")
                    adjustmentRow(id: "half", title: "예산을 절반으로 줄이기",
                                  detail: "\(formatWon(amount / 2))로 조정하면 확률 \(model.probability(for: model.direction, extraCommitted: amount / 2, on: dayNumber))%")
                    adjustmentRow(id: "next", title: "다음 주로 옮기기",
                                  detail: "이번 주 계획을 그대로 지켜요 · 확률 \(probBefore)%")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            }

            Button {
                if chosenAdjustment == "half" { amount /= 2 }
                if chosenAdjustment == "next",
                   let moved = Self.cal.date(byAdding: .day, value: 7, to: date) {
                    date = min(moved, Self.dateRange.upperBound)
                }

                // 최종 금액·날짜 기준으로 위험 재판정 → 위험하면 경고를 일정에 남긴다.
                var note: String? = nil
                var detail: String? = nil
                let finalBefore = model.weeklyBudget(for: model.direction, on: dayNumber)
                let finalAfter = finalBefore - amount
                let finalProbBefore = model.probability(for: model.direction, on: dayNumber)
                let finalProb = model.probability(for: model.direction,
                                                  extraCommitted: amount, on: dayNumber)
                if finalAfter < 0 {
                        note = "이 주 예산을 \(formatWon(-finalAfter)) 넘겨요"
                        detail = "그대로 두면 적금 목표 확률이 \(finalProbBefore)% → \(finalProb)%로 낮아져요. 금액을 줄이거나 다음 주로 옮기는 걸 추천해요."
                    } else if finalProbBefore - finalProb >= 10 {
                        note = "적금 목표 확률을 \(finalProbBefore - finalProb)%p 낮춰요"
                        detail = "금액을 줄이거나 다음 주로 옮기면 목표 확률을 지킬 수 있어요."
                }

                // 사용자가 직접 넣은 일정은 기기 캘린더에도 남긴다.
                // 권한이 없으면 앱 안에만 두고 넘어간다 — 캘린더를 안 줘도 계획은 세워져야 한다.
                // 돌려받은 식별자가 있어야 나중에 이 일정을 캘린더에서도 고치거나 지울 수 있다.
                let calendarID = importedFromDeviceCalendar
                    ? nil
                    : calendar.save(title: title, day: dayNumber,
                                    startHour: startHour, duration: 2)
                model.addEvent(title: title, day: dayNumber, amount: amount,
                               category: estimate?.category ?? "기타",
                               basis: estimate?.basis, startHour: startHour,
                               riskNote: note, riskDetail: detail,
                               calendarEventID: calendarID)
                withAnimation(spring) { step = .done }
            } label: { Text("이 계획으로 일정 추가") }
            .buttonStyle(PrimaryButtonStyle())

            hint("\(model.protectedList) 일정은 \(model.userName)님한테 더 필요한 소비라 조정안에서 제외했어요.")
        }
    }

    /// - Parameter tint: 기본은 warn 여부로 초록/주의색. 좋고 나쁨을 말할 수 없는 값
    ///   (예: 카드값은 쓰면 늘어나는 게 당연하다)은 중립색을 직접 넘긴다.
    private func impactRow(_ label: String, from: String, to: String,
                           warn: Bool, tint: Color? = nil) -> some View {
        HStack {
            Text(label).font(.kb(13.5)).foregroundStyle(KB.ink)
            Spacer()
            Text(from).font(.kb(13)).foregroundStyle(KB.muted).strikethrough()
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(KB.muted)
            Text(to).font(.kb(15, .bold))
                .foregroundStyle(tint ?? (warn ? KB.caution : KB.green))
                .monospacedDigit()
        }
    }

    private func adjustmentRow(id: String, title: String, detail: String) -> some View {
        let on = chosenAdjustment == id
        return Button { chosenAdjustment = on ? nil : id } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.kb(19)).foregroundStyle(on ? KB.ink : KB.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.kb(14, .semibold)).foregroundStyle(KB.ink)
                    Text(detail).font(.kb(12)).foregroundStyle(KB.muted)
                }
                Spacer()
            }
            .padding(12)
            .background(on ? KB.yellowSoft : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(on ? KB.yellow : KB.line, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3단계: 완료

    private var doneStep: some View {
        // addEvent 가 이미 반영된 상태 — 모델의 현재값이 곧 '추가 후' 숫자다.
        return VStack(spacing: 14) {
            Spacer(minLength: 40)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(KB.green)
            Text("일정을 추가했어요").font(.kb(20, .bold)).foregroundStyle(KB.ink)
            Text("\(DemoClock.dayLabel(of: dayNumber)) ‘\(title)’ \(formatWon(amount))을 반영했어요.\n그 주에는 \(formatWon(model.weeklyBudget(for: model.direction, on: dayNumber)))까지 더 쓸 수 있어요.")
                .font(.kb(13.5)).foregroundStyle(KB.muted)
                .multilineTextAlignment(.center).lineSpacing(3)
            Spacer()
            Button { dismiss() } label: { Text("확인") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 10))
            Text(text).font(.kb(11.5))
        }
        .foregroundStyle(KB.muted)
    }

    // MARK: - 동작

    private func loadDeviceEvents() async {
        if calendar.access == .authorized { calendar.fetchUpcoming() }
        else { await calendar.connect(); if calendar.access == .authorized { calendar.fetchUpcoming() } }
    }

    /// 일정 원문을 밖으로 보내지 않는 온디바이스 추정기
    private func runEstimate() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        isEstimating = true
        Task { @MainActor in
            var result = EventEstimator.estimate(t)
            if let searched = await searchIfTooVague(t, result) { result = searched }
            estimate = result
            // 사용자가 직접 적은 금액이 있으면 그 값이 우선, 없으면 추정치.
            let typed = Int(amountText.filter(\.isNumber)) ?? 0
            amount = typed > 0 ? typed : result.amount
            isEstimating = false
            withAnimation(spring) { step = .result }
        }
    }

    /// 규칙 기본값밖에 못 낸 일정만 웹에서 찾아본다.
    ///
    /// 개인 이력이나 공개 통계로 답이 나온 건 검색하지 않는다 — 그쪽이 더 정확하고,
    /// 검색은 검색어가 기기 밖으로 나가는 유일한 추정 경로라 필요한 만큼만 쓴다.
    /// 보내는 건 `SearchQuery.make()` 가 코드에 있는 말로만 조립한 문장이다.
    private func searchIfTooVague(_ title: String,
                                  _ current: EstimateResponse) async -> EstimateResponse? {
        guard AIConsent.granted,
              current.method == "local" || current.method == "rule",
              let built = SearchQuery.make(title: title, category: current.category),
              let found = await AgentService.searchCost(query: built.query),
              let amount = found.amount else { return nil }

        // 검색은 1인 기준으로 물어본다. 제목에 인원이 적혀 있으면 여기서 곱한다.
        let people = SearchQuery.headcount(in: title)
        let source = found.sources.first.map { " 참고: \($0)" } ?? ""
        return EstimateResponse(
            title: title, category: current.category,
            amount: amount * people,
            low: (found.low ?? amount) * people, high: (found.high ?? amount) * people,
            confidence: 0.4,
            basis: "‘\(built.query)’로 웹에서 찾았어요. \(found.basis)\(source)",
            method: "web"
        )
    }
}

#Preview {
    AddEventView().environmentObject(AppModel())
}
