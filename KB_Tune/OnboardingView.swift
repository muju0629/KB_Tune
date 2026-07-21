//
//  OnboardingView.swift
//  KB_Tune
//
//  랜딩/세팅 = 나만의 소비 에이전트를 '조립'하는 과정. 4문항으로 간소화.
//  흐름: ①거래연결 ②수입·저축목표(세로 다이얼) ③좋아하고 지키고 싶은 것 ④이번달 방향
//        → '에이전트 만드는 중' 빌드 연출 → 개인화된 완료 화면
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    var onFinish: () -> Void
    var onBack: (() -> Void)? = nil   // 첫 화면에서 뒤로 = 시작화면으로

    /// 0~3 = 질문 단계, 4 = 에이전트 빌드 연출, 5 = 완료
    @State private var step = 0
    @State private var forward = true
    @State private var buildStep = 0

    private let questionCount = 4
    private let stepSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Group {
                switch step {
                case 0: stepConnect
                case 1: stepIncomeGoal
                case 2: stepKeeps
                case 3: stepDirection
                case 4: stepBuilding
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
                        .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(KB.ink)
                .lineSpacing(3)
            Text(sub)
                .font(.system(size: 14))
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
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(KB.muted)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)
    }

    // MARK: ① 거래 연결 / 데모

    private var stepConnect: some View {
        VStack(spacing: 0) {
            header("최근 3개월 소비를\n먼저 살펴볼게요", "은행·카드 거래를 분석해 지금 얼마까지 써도 되는지 계산해요. 지금은 데모 데이터로 바로 체험할 수 있어요.")

            Spacer()
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 60, weight: .thin))
                .foregroundStyle(KB.yellow)
            Spacer()

            VStack(spacing: 12) {
                Button {
                    model.usesDemoData = true
                    next()
                } label: { Text("데모 거래로 시작하기") }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    model.usesDemoData = true
                    next()
                } label: { Text("내 계좌·카드 연결 (준비 중)") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(true)
                .opacity(0.55)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            agentHint("에이전트가 소비 패턴 학습을 시작해요")
        }
    }

    // MARK: ② 수입 · 저축 목표 (세로 다이얼 2개)

    private var stepIncomeGoal: some View {
        let pct = model.monthlyIncome > 0
            ? Int((Double(model.savingsGoal) / Double(model.monthlyIncome) * 100).rounded())
            : 0
        let peerNote: String = {
            switch pct {
            case ..<15: "또래보다 여유 있게 잡았어요. 부담 없이 시작하기 좋아요."
            case 15...25: "\(model.userName)님 나이대와 비슷한 수준이에요."
            default: "또래 평균보다 높아요. 지킬 수 있는 선인지 확인해 보세요."
            }
        }()
        return VStack(spacing: 0) {
            header("한 달 수입과\n저축 목표를 알려주세요", "알바비·용돈 등 매달 들어오는 금액이면 돼요. 대략적이어도 괜찮아요.")

            HStack(spacing: 12) {
                dialCard("월 수입", value: $model.monthlyIncome,
                         range: 200_000...5_000_000, step: 100_000)
                dialCard("월 저축 목표", value: $model.savingsGoal,
                         range: 0...1_000_000, step: 50_000)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            // 또래 비교 안내
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 14))
                    .foregroundStyle(KB.green)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("지금 계획은 수입의 \(pct)%예요.")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(KB.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: pct)
                    Text("20대 초반은 보통 수입의 15~25%를 모아요. \(peerNote)")
                        .font(.system(size: 12))
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

            agentHint("수입에 맞춰 주간 예산을 설계해요")
        }
    }

    private func dialCard(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            MoneyDial(value: value, range: range, step: step)
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    // MARK: ③ 좋아하고 지키고 싶은 것 (통합 서베이)

    private var stepKeeps: some View {
        VStack(spacing: 0) {
            header("좋아하는 것과\n지키고 싶은 소비를 골라주세요", "고른 것들은 ‘줄일 대상’이 아니라 ‘지킬 이유’가 돼요. 계획을 조정할 때 끝까지 지켜드릴게요.")

            FlowChips(items: keepCandidates.map { (tag: $0.tag, label: $0.label, symbol: $0.symbol) },
                      selected: $model.hobbies)
                .padding(.horizontal, 24)
                .padding(.top, 24)

            Spacer()

            Button {
                // 보호 소비 파생: 관계·행사성 태그는 보호 대상으로
                let prot = model.hobbies.intersection(["모임", "가족", "경조사", "운동"])
                model.protectedTags = prot.isEmpty ? ["모임"] : prot
                next()
            } label: { Text("다음") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.hobbies.isEmpty)
                .opacity(model.hobbies.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            agentHint(model.hobbies.isEmpty
                      ? "취향은 에이전트의 판단 기준이 돼요"
                      : "\(model.hobbies.sorted().joined(separator: "·")) — 기억할게요")
        }
    }

    // MARK: ④ 소비 방향 (월초 1회 결정)

    private var stepDirection: some View {
        VStack(spacing: 0) {
            header("7월 소비 방향을\n정해볼까요?", "한 달에 한 번, 월초에 정하는 방향이에요. 에이전트가 이 방향을 지키도록 도와드려요.")

            VStack(spacing: 12) {
                ForEach(SpendDirection.allCases) { dir in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { model.direction = dir }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dir.label).font(.system(size: 16, weight: .semibold))
                                Text("이번 주 \(formatWon(dir.budget)) · 목표 확률 \(dir.probability)%")
                                    .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                            }
                            Spacer()
                            Image(systemName: model.direction == dir ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(model.direction == dir ? KB.ink : KB.line)
                        }
                        .padding(16)
                        .background(model.direction == dir ? KB.yellowSoft : .white,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(model.direction == dir ? KB.yellow : KB.line, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KB.ink)
                }
            }
            .sensoryFeedback(.selection, trigger: model.direction)
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer()

            Button { next() } label: { Text("에이전트 만들기") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    // MARK: 에이전트 빌드 연출

    private var buildRows: [String] {
        let hobbyText = model.hobbies.isEmpty
            ? "취향 프로필 반영"
            : "\(model.hobbies.sorted().prefix(3).joined(separator: "·")) 취향 반영"
        return [
            "최근 3개월(2026.04~06) 소비 패턴 분석",
            hobbyText,
            "월 수입 \(formatWon(model.monthlyIncome)) 기준 주간 예산 설계",
            "‘\(model.protectedSummary)’ 보호 설정",
            "저축 목표 \(formatWon(model.savingsGoal)) 달성 확률 계산",
        ]
    }

    private var stepBuilding: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle().fill(KB.yellow).frame(width: 76, height: 76)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(KB.ink)
            }
            .scaleEffect(buildStep % 2 == 0 ? 1.0 : 1.08)
            .animation(.easeInOut(duration: 0.5), value: buildStep)

            Text("나만의 소비 에이전트를\n만들고 있어요")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 22)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(buildRows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 10) {
                        if buildStep > i {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
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
                            .font(.system(size: 14, weight: buildStep >= i ? .medium : .regular))
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
                withAnimation(.spring(response: 0.3)) { buildStep = i }
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
            forward = true
            withAnimation(stepSpring) { step = 5 }
        }
    }

    // MARK: 완료 (개인화 요약)

    private var stepDone: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(KB.green)

            Text("\(model.userName)님만의 에이전트가\n준비됐어요")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 12) {
                summaryRow(symbol: "heart",
                           text: model.hobbies.isEmpty
                               ? "취향을 계속 배워갈게요"
                               : "\(model.hobbies.sorted().prefix(3).joined(separator: "·"))을 즐기는 \(model.userName)님")
                summaryRow(symbol: "shield",
                           text: "‘\(model.protectedSummary)’는 끝까지 지켜요")
                summaryRow(symbol: "banknote",
                           text: "월 수입 \(formatWon(model.monthlyIncome)) 중 \(formatWon(model.savingsGoal)) 저축 목표")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Text("이번 주 \(formatWon(model.weeklyBudget))까지 괜찮아요")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KB.ink)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(KB.yellowSoft, in: Capsule())
                .overlay(Capsule().stroke(KB.yellow, lineWidth: 1))
                .padding(.top, 18)

            Spacer()

            Button(action: onFinish) { Text("내 계획 보기") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    private func summaryRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(KB.green)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13.5))
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
                        Text(item.label).font(.system(size: 15, weight: .medium))
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
