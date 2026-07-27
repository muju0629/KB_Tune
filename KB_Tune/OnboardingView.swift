//
//  OnboardingView.swift
//  KB_Tune
//
//  7월 캘린더를 바탕으로 수입·저축 목표와 지킬 소비를 확인하는 3단계 온보딩.
//
//  소비 방향(줄이기·유지·늘리기)은 묻지 않는다. 목표 달성 확률만 계산하면 알 수 있는 걸
//  시작하자마자 되물으면, 아직 아무 숫자도 못 본 사용자가 답할 근거가 없다.
//  앱이 정해서 완료 화면에서 근거와 함께 알려주고, 바꾸는 건 설정에 둔다.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    var onFinish: () -> Void
    var onBack: (() -> Void)? = nil   // 첫 화면에서 뒤로 = 시작화면으로

    /// 0~2 = 질문 단계, 3 = 에이전트 빌드 연출, 4 = 완료
    @State private var step = 0
    @State private var forward = true
    @State private var buildStep = 0
    @State private var showKBPayConsent = false
    @StateObject private var calendar = CalendarStore()

    private let questionCount = 3
    private let stepSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Group {
                switch step {
                case 0: stepConnect
                case 1: stepIncomeGoal
                case 2: stepKeeps
                case 3: stepBuilding
                default: stepDone
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .background(KB.canvas)
    }

    // MARK: 상단 바

    private var topBar: some View {
        let showsBack = step < questionCount && (step > 0 || onBack != nil)
        return HStack(spacing: 8) {
            if showsBack {
                Button {
                    if step > 0 {
                        forward = false
                        withAnimation(stepSpring) { step -= 1 }
                    } else {
                        onBack?()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.kb(17, .semibold))
                        .foregroundStyle(KB.ink)
                }
            }
            Spacer()
            if step < questionCount {
                HStack(spacing: 6) {
                    ForEach(0..<questionCount, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? KB.ink : (i < step ? KB.yellow : KB.line))
                            .frame(width: i == step ? 20 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            }
            Spacer()
            if showsBack { Color.clear.frame(width: 17, height: 17) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(height: 44)
    }

    // MARK: 공통 helper

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.kb(26, .bold))
                .foregroundStyle(KB.ink)
                .lineSpacing(3)
            Text(sub)
                .font(.kb(14))
                .foregroundStyle(KB.muted)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private func next() {
        forward = true
        withAnimation(stepSpring) { step += 1 }
    }

    private func agentHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
            Text(text).font(.kb(12))
        }
        .foregroundStyle(KB.muted)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)
    }

    // MARK: ① 일정·소비 연결

    private var stepConnect: some View {
        VStack(spacing: 0) {
            header("일정과 소비를\n연결할게요", "둘을 함께 봐야 앞으로 얼마를 쓰게 될지 계산할 수 있어요.")

            VStack(spacing: 11) {
                ConnectRow(symbol: "calendar",
                           tint: KB.green,
                           title: "캘린더",
                           detail: "일정을 읽고, 예산을 잡은 일정은 캘린더에 다시 적어요",
                           state: calendarRowState) {
                    Task { await calendar.connect() }
                }

                ConnectRow(symbol: "creditcard",
                           tint: KB.ink,
                           title: "KB Pay 이용내역",
                           detail: "카드 이용내역을 읽어 소비 패턴을 분석해요",
                           state: model.kbPayLinked ? .linked : .idle) {
                    showKBPayConsent = true
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            if let err = calendar.lastError {
                Text(err)
                    .font(.kb(12)).foregroundStyle(KB.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.top, 10)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    model.usesDemoData = true
                    next()
                } label: { Text(connectedCount > 0 ? "다음" : "7월 데모 일정으로 시작하기") }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            agentHint(connectedCount == 0
                      ? "연결하지 않아도 7월 데모 일정으로 둘러볼 수 있어요"
                      : "연결한 자료로 일정별 예상 금액을 계산할게요")
        }
        .sheet(isPresented: $showKBPayConsent) {
            KBPayConsentSheet { model.kbPayLinked = true }
                .presentationDetents([.large])
        }
        // 설정 앱에서 권한을 켜고 돌아온 경우도 반영한다.
        .onAppear { calendar.refreshAccessStatus() }
    }

    private var calendarRowState: ConnectRow.State {
        if calendar.isLoading { return .loading }
        switch calendar.access {
        case .authorized: return .linked
        case .denied: return .denied
        case .notDetermined: return .idle
        }
    }

    private var connectedCount: Int {
        (calendar.access == .authorized ? 1 : 0) + (model.kbPayLinked ? 1 : 0)
    }

    // MARK: ② 수입 · 저축 목표 (세로 다이얼 2개)

    private var stepIncomeGoal: some View {
        let pct = model.monthlyIncome > 0
            ? Int((Double(model.savingsGoal) / Double(model.monthlyIncome) * 100).rounded())
            : 0
        let afterSaving = max(0, model.monthlyIncome - model.savingsGoal)
        return VStack(spacing: 0) {
            header("월 수입과\n저축 목표를 확인해 주세요", "인턴 급여·용돈처럼 매달 들어오는 금액을 입력해 주세요. 기본값은 일정에 맞춘 추정치예요.")

            HStack(spacing: 12) {
                dialCard("월 수입", value: $model.monthlyIncome,
                         range: 200_000...5_000_000, step: 100_000)
                dialCard("월 저축 목표", value: $model.savingsGoal,
                         range: 0...3_000_000, step: 50_000)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "equal.circle")
                    .font(.kb(14))
                    .foregroundStyle(KB.green)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("저축 목표는 수입의 \(pct)%")
                        .font(.kb(13.5, .semibold))
                        .foregroundStyle(KB.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: pct)
                    Text("저축 후 남는 \(formatWon(afterSaving))에서 예상 지출과 고정비를 계산해요.")
                        .font(.kb(12))
                        .foregroundStyle(KB.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer()

            Button { next() } label: { Text("다음") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            agentHint("수입에 맞춰 이번 주 금액을 계산해요")
        }
    }

    private func dialCard(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.kb(13, .semibold)).foregroundStyle(KB.muted)
            MoneyDial(value: value, range: range, step: step)
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    // MARK: ③ 나한테 더 필요한 소비 (통합 서베이 — 취향 + 예산 조정 제외 대상)

    private var stepKeeps: some View {
        VStack(spacing: 0) {
            header("나한테 더 필요한 소비를\n골라주세요", "좋아하는 걸 고르면 돼요. 예산을 조정할 때도 줄이지 않고 남겨둘게요.")

            FlowChips(items: keepCandidates.map { (tag: $0.tag, label: $0.label, symbol: $0.symbol) },
                      selected: $model.hobbies)
                .padding(.horizontal, 24)
                .padding(.top, 24)

            Spacer()

            // 더 필요한 소비(protectedTags)는 hobbies에서 자동 파생 — 별도 저장 없음
            Button { next() } label: { Text("7월 계획 계산하기") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.hobbies.isEmpty)
                .opacity(model.hobbies.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            agentHint(model.hobbies.isEmpty
                      ? "고른 소비는 예산을 조정할 때 줄이지 않아요"
                      : "\(model.hobbies.sorted().joined(separator: "·")) — 더 필요한 소비로 기억할게요")
        }
    }

    // MARK: 에이전트 빌드 연출

    private var buildRows: [String] {
        let hobbyText = model.hobbies.isEmpty
            ? "취향 프로필 반영"
            : "\(model.hobbies.sorted().prefix(3).joined(separator: "·")) 취향 반영"
        return [
            "7월 인턴 출근 22일 반영",
            "일정별 예상 금액 범위 계산",
            hobbyText,
            "수입 \(formatWon(model.monthlyIncome)) · 저축 \(formatWon(model.savingsGoal)) 반영",
            "\(model.protectedList) 소비는 줄이지 않게 설정",
            "목표 확률로 이번 달 소비 방향 결정",
        ]
    }

    private var stepBuilding: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle().fill(KB.yellow).frame(width: 76, height: 76)
                Image(systemName: "sparkles")
                    .font(.kb(32, .medium))
                    .foregroundStyle(KB.ink)
            }
            .scaleEffect(buildStep % 2 == 0 ? 1.0 : 1.08)
            .animation(.easeInOut(duration: 0.5), value: buildStep)

            Text("7월 계획을\n계산하고 있어요")
                .font(.kb(24, .bold))
                .foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 22)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(buildRows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 10) {
                        if buildStep > i {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.kb(18))
                                .foregroundStyle(KB.green)
                                .transition(.scale.combined(with: .opacity))
                        } else if buildStep == i {
                            ProgressView().tint(KB.muted).scaleEffect(0.8)
                                .frame(width: 18, height: 18)
                        } else {
                            Circle().stroke(KB.line, lineWidth: 1.5).frame(width: 16, height: 16)
                                .padding(1)
                        }
                        Text(row)
                            .font(.kb(14, buildStep >= i ? .medium : .regular))
                            .foregroundStyle(buildStep >= i ? KB.ink : KB.muted)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.top, 28)

            Spacer()
            Spacer()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: buildStep)
        .task {
            for i in 1...buildRows.count {
                try? await Task.sleep(nanoseconds: 550_000_000)
                // 마지막 줄에 맞춰 방향을 정한다 — 연출과 실제 계산이 어긋나지 않게.
                if i == buildRows.count { model.decideDirection() }
                withAnimation(.spring(response: 0.3)) { buildStep = i }
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
            forward = true
            withAnimation(stepSpring) { step = questionCount + 2 }
        }
    }

    // MARK: 완료 (개인화 요약)

    private var stepDone: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.kb(56))
                .foregroundStyle(KB.green)

            Text("\(model.userName)님의 7월 계획이\n준비됐어요")
                .font(.kb(25, .bold))
                .foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 12) {
                summaryRow(symbol: "heart",
                           text: model.userRole)
                summaryRow(symbol: "shield",
                           text: "\(model.protectedList) 소비는 더 필요한 소비라 줄이지 않아요")
                summaryRow(symbol: "banknote",
                           text: "월 수입 \(formatWon(model.monthlyIncome)) · 저축 목표 \(formatWon(model.savingsGoal))")
                summaryRow(symbol: "dial.medium",
                           text: model.directionReason)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Spacer()

            Button(action: onFinish) { Text("7월 계획 보기") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    private func summaryRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.kb(14, .medium))
                .foregroundStyle(KB.green)
                .frame(width: 20)
            Text(text)
                .font(.kb(13.5))
                .foregroundStyle(KB.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 선택 가능한 태그 칩 묶음 (자동 줄바꿈 + 선택 햅틱)
struct FlowChips: View {
    let items: [(tag: String, label: String, symbol: String)]
    @Binding var selected: Set<String>

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(items, id: \.tag) { item in
                let isOn = selected.contains(item.tag)
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        if isOn { selected.remove(item.tag) } else { selected.insert(item.tag) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol).font(.system(size: 15, weight: .regular))
                        Text(item.label).font(.kb(15, .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(isOn ? KB.yellowSoft : .white,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isOn ? KB.yellow : KB.line, lineWidth: 1.5))
                    .foregroundStyle(KB.ink)
                    .scaleEffect(isOn ? 1.02 : 1.0)
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

#Preview {
    OnboardingView(onFinish: {}).environmentObject(AppModel())
}
