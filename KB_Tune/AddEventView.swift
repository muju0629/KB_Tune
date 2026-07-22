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
//  추정은 백엔드 /api/estimate → 실패 시 EventEstimator(로컬) 폴백.
//

import SwiftUI

struct AddEventView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var agent = AgentService()
    @StateObject private var calendar = CalendarStore()

    enum Source: String, CaseIterable { case manual = "직접 입력", device = "캘린더에서" }
    enum Step { case input, result, done }

    @State private var source: Source = .manual
    @State private var step: Step = .input

    @State private var title = ""
    @State private var day = 25
    @State private var estimate: EstimateResponse?
    @State private var amount = 0            // 사용자가 조정 가능한 최종 금액
    @State private var isEstimating = false
    @State private var chosenAdjustment: String?

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

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
                        if s == .device { Task { await loadDeviceEvents() } }
                    } label: {
                        Text(s.rawValue)
                            .font(.system(size: 14, weight: source == s ? .semibold : .regular))
                            .foregroundStyle(KB.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(source == s ? KB.yellow : .clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(KB.line, lineWidth: 1))
            .sensoryFeedback(.selection, trigger: source)

            if source == .manual { manualInput } else { deviceInput }
        }
    }

    private var manualInput: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("무슨 일정인가요?").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                TextField("예: 지민 결혼식, 동아리 회식", text: $title)
                    .font(.system(size: 16))
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                    .submitLabel(.done)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("언제예요?").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                HStack {
                    Text("7월 \(day)일").font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.ink)
                        .monospacedDigit()
                    Spacer()
                    Stepper("", value: $day, in: 22...31).labelsHidden()
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
            }

            Button { runEstimate() } label: {
                if isEstimating { ProgressView().tint(KB.ink) }
                else { Text("예상 지출 계산하기") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isEstimating)
            .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            hint("제목만 쓰면 과거 소비를 바탕으로 예상 금액을 자동으로 잡아드려요.")
        }
    }

    private var deviceInput: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch calendar.access {
            case .notDetermined:
                VStack(alignment: .leading, spacing: 12) {
                    Text("기기 캘린더에서 일정을 가져올게요")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.ink)
                    Text("아이폰 캘린더에 있는 일정을 읽어와요. 설정에 추가한 구글·네이버 캘린더 일정도 함께 보여요. 내용은 기기에서만 사용해요.")
                        .font(.system(size: 13)).foregroundStyle(KB.muted).lineSpacing(2)
                    Button { Task { await loadDeviceEvents() } } label: {
                        if calendar.isLoading { ProgressView().tint(KB.ink) } else { Text("캘린더 불러오기") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    Text("캘린더 접근이 꺼져 있어요").font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.ink)
                    Text("설정 → 개인정보 보호 → 캘린더에서 켤 수 있어요. 직접 입력으로도 추가할 수 있어요.")
                        .font(.system(size: 13)).foregroundStyle(KB.muted)
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
                            .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("가져올 일정을 선택하세요")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                    ForEach(calendar.events) { ev in
                        Button {
                            title = ev.title
                            if (22...31).contains(ev.dayOfMonth) { day = ev.dayOfMonth }
                            runEstimate()
                        } label: {
                            HStack(spacing: 12) {
                                IconBadge(systemName: "calendar", background: KB.yellowSoft, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title).font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(KB.ink).lineLimit(1)
                                    Text(ev.dayLabel).font(.system(size: 12)).foregroundStyle(KB.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(KB.muted)
                            }
                            .padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isEstimating {
                HStack(spacing: 8) { ProgressView().tint(KB.muted); Text("예상 지출을 계산하는 중…")
                    .font(.system(size: 12.5)).foregroundStyle(KB.muted) }
            }
        }
    }

    // MARK: - 2단계: 추정 결과 + 영향 + 조정안

    private var resultStep: some View {
        // '전'은 이미 추가한 일정까지 반영된 현재값 — model.weeklyBudget/probability와 같은 기준.
        let before = model.weeklyBudget
        let after = before - amount
        let probBefore = model.probability
        let probAfter = BudgetEngine.probability(model.direction,
                                                 extraCommitted: model.userAddedTotal + amount,
                                                 income: model.monthlyIncome,
                                                 savingsGoal: model.savingsGoal)
        let risky = (probBefore - probAfter) >= 10 || after < 0

        return VStack(alignment: .leading, spacing: 18) {
            // 추정 결과
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(KB.ink)
                    Text("예상 지출을 이렇게 잡았어요").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                    Spacer()
                    if let e = estimate {
                        Text(e.category).font(.system(size: 11, weight: .medium)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(KB.yellowSoft, in: Capsule())
                    }
                }
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(KB.ink)
                Text("7월 \(day)일").font(.system(size: 12.5)).foregroundStyle(KB.muted)

                HStack {
                    Text(formatWon(amount))
                        .font(.system(size: 26, weight: .bold)).foregroundStyle(KB.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: amount)
                    Spacer()
                    Stepper("", value: $amount, in: 0...500_000, step: 5_000).labelsHidden()
                }
                .padding(.top, 2)

                if let e = estimate {
                    Text(e.basis).font(.system(size: 12)).foregroundStyle(KB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("예상 범위 \(formatWon(e.low))~\(formatWon(e.high))")
                        Text("·")
                        Text("신뢰도 \(Int(e.confidence * 100))%")
                        Text("·")
                        Text(e.method == "local" ? "기기 계산" : "서버 추정")
                    }
                    .font(.system(size: 11)).foregroundStyle(KB.muted.opacity(0.9))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))

            // 영향
            VStack(alignment: .leading, spacing: 10) {
                Text("이 일정을 넣으면").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                impactRow("이번 주 사용 가능액", from: formatWon(before), to: formatWon(max(after, 0)),
                          warn: after < 0)
                impactRow("적금 목표 확률", from: "\(probBefore)%", to: "\(probAfter)%",
                          warn: (probBefore - probAfter) >= 10)
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
                        Text("이대로면 계획이 흔들려요").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KB.ink)
                    }
                    adjustmentRow(id: "keep", title: "그대로 추가",
                                  detail: "사용 가능액 \(formatWon(max(after, 0))) · 확률 \(probAfter)%")
                    adjustmentRow(id: "half", title: "예산을 절반으로 줄이기",
                                  detail: "\(formatWon(amount / 2))로 조정하면 확률 \(BudgetEngine.probability(model.direction, extraCommitted: model.userAddedTotal + amount / 2, income: model.monthlyIncome, savingsGoal: model.savingsGoal))%")
                    adjustmentRow(id: "next", title: "다음 주로 옮기기",
                                  detail: "이번 주 계획을 그대로 지켜요 · 확률 \(probBefore)%")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            }

            Button {
                if chosenAdjustment == "half" { amount /= 2 }
                if chosenAdjustment == "next" { day = min(day + 7, 31) }

                // 최종 금액·날짜 기준으로 위험 재판정 → 위험하면 경고를 일정에 남긴다.
                var note: String? = nil
                var detail: String? = nil
                if model.currentWeekRange.contains(day) {
                    let finalAfter = before - amount
                    let finalProb = BudgetEngine.probability(model.direction,
                                                             extraCommitted: model.userAddedTotal + amount,
                                                             income: model.monthlyIncome,
                                                             savingsGoal: model.savingsGoal)
                    if finalAfter < 0 {
                        note = "이번 주 예산을 \(formatWon(-finalAfter)) 넘겨요"
                        detail = "그대로 두면 적금 목표 확률이 \(probBefore)% → \(finalProb)%로 낮아져요. 금액을 줄이거나 다음 주로 옮기는 걸 추천해요."
                    } else if probBefore - finalProb >= 10 {
                        note = "적금 목표 확률을 \(probBefore - finalProb)%p 낮춰요"
                        detail = "금액을 줄이거나 다음 주로 옮기면 목표 확률을 지킬 수 있어요."
                    }
                }

                model.addEvent(title: title, day: day, amount: amount,
                               category: estimate?.category ?? "기타",
                               basis: estimate?.basis,
                               riskNote: note, riskDetail: detail)
                withAnimation(spring) { step = .done }
            } label: { Text("이 계획으로 일정 추가") }
            .buttonStyle(PrimaryButtonStyle())

            hint("\(model.protectedList) 일정은 \(model.userName)님한테 더 필요한 소비라 조정안에서 제외했어요.")
        }
    }

    private func impactRow(_ label: String, from: String, to: String, warn: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(KB.ink)
            Spacer()
            Text(from).font(.system(size: 13)).foregroundStyle(KB.muted).strikethrough()
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(KB.muted)
            Text(to).font(.system(size: 15, weight: .bold))
                .foregroundStyle(warn ? KB.caution : KB.green)
                .monospacedDigit()
        }
    }

    private func adjustmentRow(id: String, title: String, detail: String) -> some View {
        let on = chosenAdjustment == id
        return Button { chosenAdjustment = on ? nil : id } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 19)).foregroundStyle(on ? KB.ink : KB.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(KB.muted)
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
            Text("일정을 추가했어요").font(.system(size: 20, weight: .bold)).foregroundStyle(KB.ink)
            Text("7월 \(day)일 ‘\(title)’ \(formatWon(amount))을 반영했어요.\n이번 주에는 \(formatWon(model.weeklyBudget))까지 쓸 수 있어요.")
                .font(.system(size: 13.5)).foregroundStyle(KB.muted)
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
            Text(text).font(.system(size: 11.5))
        }
        .foregroundStyle(KB.muted)
    }

    // MARK: - 동작

    private func loadDeviceEvents() async {
        if calendar.access == .authorized { calendar.fetchUpcoming() }
        else { await calendar.connect(); if calendar.access == .authorized { calendar.fetchUpcoming() } }
    }

    /// 백엔드 추정 → 실패 시 로컬 추정기
    private func runEstimate() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        isEstimating = true
        Task {
            let result = await agent.estimate(title: t) ?? EventEstimator.estimate(t)
            estimate = result
            amount = result.amount
            isEstimating = false
            withAnimation(spring) { step = .result }
        }
    }
}

#Preview {
    AddEventView().environmentObject(AppModel())
}
