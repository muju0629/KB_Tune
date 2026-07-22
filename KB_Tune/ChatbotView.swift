//
//  ChatbotView.swift
//  KB_Tune
//
//  계획을 바꾸는 대화형 도구(범용 챗봇 아님).
//  기준: prompts/02_CHATBOT_PAGE.md — 답변 = 결론→이유→영향→행동.
//
//  연결 구조: send() → AgentService.chatStream(POST /api/chat, 스트리밍) → 실패 시 agentReply(로컬).
//  숫자는 서버 BudgetEngine이 계산해 넘기고, Claude는 판단·문장만 생성(grounded).
//  백엔드/키가 없으면 로컬 BudgetEngine + 스크립트로 폴백 — 항상 동작.
//

import SwiftUI

// MARK: - 메시지 모델

struct ChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, agent }
    enum Actions { case addEvent }
    let role: Role
    var conclusion: String                 // 결론(본문)
    var reason: String? = nil              // 이유
    var impact: String? = nil              // 영향(전/후)
    var basis: String? = nil               // 계산 근거(접기)
    var preview: EventPreview? = nil       // 대화 속 일정 미리보기
    var actions: Actions? = nil
    var isStream: Bool = false             // 백엔드 스트리밍 응답(자유 문장)
}

struct EventPreview {
    var title: String
    var amount: Int
    var day: String
}

// MARK: - 화면

struct ChatbotView: View {
    @EnvironmentObject private var model: AppModel

    @StateObject private var agent = AgentService()
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isThinking = false
    @State private var thinkingStep = 0
    @State private var toast: String?
    @FocusState private var inputFocused: Bool

    private let suggestions = ["이번 주 얼마까지 써도 돼?", "적금 목표 지킬 수 있어?", "다음 주 데이트 예산 잡아줘"]
    private let thinkingSteps = [
        "질문에 맞는 일정을 찾고 있어요",
        "예상 지출을 더하고 있어요",
        "남은 금액을 계산하고 있어요",
    ]

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            Divider().overlay(KB.line)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { msg in
                            bubble(msg).id(msg.id)
                        }
                        if isThinking { typingBubble.id("typing") }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }
                .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: isThinking) { _, _ in scrollToEnd(proxy) }
            }

            chips
            inputBar
        }
        .background(KB.canvas)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(KB.green, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear(perform: seedIfNeeded)
        .task { await agent.ping() }
    }

    // MARK: 컨텍스트 바

    private var contextBar: some View {
        HStack(spacing: 10) {
            Image("AgentMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("계획 도우미")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KB.ink)
                Text("이번 주 약 \(formatWon(roundedWeeklyBudget)) · 목표 \(model.probability)%")
                    .font(.caption)
                    .foregroundStyle(KB.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(KB.yellowSoft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("계획 도우미. 이번 주 사용 가능액 약 \(formatWon(roundedWeeklyBudget)), 목표 확률 \(model.probability)%")
    }

    // MARK: 말풍선

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(msg.conclusion)
                    .font(.system(size: 14)).foregroundStyle(KB.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(KB.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                agentCard(msg)
                Spacer(minLength: 44)
            }
        }
    }

    private func agentCard(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(msg.conclusion)
                .font(.system(size: 14, weight: msg.isStream ? .regular : .semibold)).foregroundStyle(KB.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = msg.reason {
                Text(reason).font(.system(size: 13)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let impact = msg.impact {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap").font(.system(size: 12)).foregroundStyle(KB.green)
                    Text(impact).font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.green)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if let preview = msg.preview {
                previewRow(preview)
            }

            if let basis = msg.basis {
                DisclosureGroup {
                    Text(basis).font(.system(size: 12)).foregroundStyle(KB.muted)
                        .padding(.top, 4)
                } label: {
                    Text("계산 근거").font(.system(size: 12, weight: .medium)).foregroundStyle(KB.muted)
                }
                .tint(KB.muted)
            }

            actionButtons(for: msg.actions)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func previewRow(_ p: EventPreview) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemName: "calendar", background: KB.yellowSoft, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                Text(p.day).font(.system(size: 11.5)).foregroundStyle(KB.muted)
            }
            Spacer()
            Text(formatWon(p.amount)).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
        }
        .padding(10)
        .background(KB.canvas, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func smallAction(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(filled ? KB.yellow : .clear, in: Capsule())
                .overlay(Capsule().stroke(filled ? .clear : KB.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionButtons(for actions: ChatMessage.Actions?) -> some View {
        switch actions {
        case .addEvent:
            HStack(spacing: 8) {
                // 8월은 아직 계획 모델 밖 — 실제로 반영되지 않으니 문구도 그렇게 말한다.
                smallAction("예산 초안으로 기억", filled: true) { flash("8월 2일 데이트를 100,000원 초안으로 기억해둘게요.") }
                smallAction("금액 바꾸기", filled: false) {
                    input = "200일 데이트 예산을 "
                    inputFocused = true
                }
            }
            .padding(.top, 2)
        case nil:
            EmptyView()
        }
    }

    private var typingBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(KB.ink)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(thinkingSteps[min(thinkingStep, thinkingSteps.count - 1)])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KB.ink)
                        .accessibilityIdentifier("chat-thinking")
                    Text("캘린더와 예산을 맞춰 보는 중이에요")
                        .font(.caption)
                        .foregroundStyle(KB.muted)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            Spacer(minLength: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thinkingSteps[min(thinkingStep, thinkingSteps.count - 1)])
    }

    // MARK: 추천 질문 칩

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { q in
                    Button { send(q) } label: {
                        Text(q).font(.system(size: 13)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.white, in: Capsule())
                            .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isThinking)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.vertical, 10)
    }

    // MARK: 입력창

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("일정이나 금액을 물어보세요", text: $input)
                .font(.system(size: 14))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit { send(input) }
                .focused($inputFocused)
                .disabled(isThinking)

            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(KB.ink)
                    .frame(width: 44, height: 44)
                    .background(KB.yellow, in: Circle())
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .accessibilityLabel("질문 보내기")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }

    // MARK: 동작

    private func seedIfNeeded() {
        guard messages.isEmpty else { return }
        messages.append(ChatMessage(
            role: .agent,
            conclusion: "성제님, 이번 주 예산부터 볼까요?",
            reason: "일정 이름을 말해 주면 예상 금액과 남는 돈을 같이 계산해요."
        ))
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, conclusion: trimmed))
        input = ""
        inputFocused = false
        thinkingStep = 0
        isThinking = true

        Task {
            let minimumDelay = Task {
                try? await Task.sleep(for: .milliseconds(1_600))
            }
            let stageUpdates = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                thinkingStep = 1
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                thinkingStep = 2
            }

            var streamed = ""
            let ok = await agent.chatStream(trimmed, model: model) { delta in
                streamed += delta
            }

            _ = await minimumDelay.result
            stageUpdates.cancel()
            isThinking = false

            if ok, !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(ChatMessage(
                    role: .agent,
                    conclusion: streamed.trimmingCharacters(in: .whitespacesAndNewlines),
                    basis: "2026년 7월 캘린더 · 입력한 월수입과 저축 목표",
                    isStream: true
                ))
            } else {
                messages.append(agentReply(to: trimmed))
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if isThinking { proxy.scrollTo("typing", anchor: .bottom) }
            else if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut) { toast = nil }
        }
    }

    private var roundedWeeklyBudget: Int {
        max(0, Int((Double(model.weeklyBudget) / 10_000).rounded()) * 10_000)
    }

    private func rangeText(low: Int, high: Int) -> String {
        formatWonRange(low, high)
    }

    // MARK: 로컬 스크립트 에이전트 (백엔드가 없을 때)

    private func agentReply(to text: String) -> ChatMessage {
        let q = text.replacingOccurrences(of: " ", with: "")

        if q.contains("출근") || q.contains("인턴") || q.contains("점심") || q.contains("교통") {
            return ChatMessage(
                role: .agent,
                conclusion: "출근 비용은 따로 잡지 않았어요.",
                reason: "점심은 돈이 들지 않고, 교통비와 유류비는 월 고정비 210,000원에 이미 들어 있어요.",
                impact: "출근 22일 × 0원 · 일정비 합계에 영향 없음",
                basis: "확인한 고정비: 교통 150,000원 + 유류 60,000원"
            )
        }

        if q.contains("200일") || q.contains("데이트") || q.contains("다음주") || q.contains("8월2일") {
            return ChatMessage(
                role: .agent,
                conclusion: "8월 2일 200일 데이트는 100,000원을 먼저 빼둘게요.",
                reason: "아직 금액이 없어서 식사·카페·이동을 포함한 예산 초안으로 잡았어요.",
                impact: "7월 계산에는 넣지 않고, 8월 예산에서 따로 확보",
                basis: "8월 2일 캘린더의 ‘200일’·‘데이트’ 일정",
                preview: EventPreview(title: "200일 데이트", amount: 100_000, day: "8월 2일 일요일"),
                actions: .addEvent
            )
        }

        // 과거 이력에 같은 일정이 있으면 주기·평균으로 답한다.
        if let p = SpendHistory.patterns.first(where: {
            q.contains($0.key.replacingOccurrences(of: " ", with: ""))
        }) {
            return ChatMessage(
                role: .agent,
                conclusion: "\(p.key)는 \(formatWon(p.avgAmount)) 정도로 보고 있어요.",
                reason: SpendHistory.reason(for: p),
                impact: "최근 \(p.records.count)번 평균 · \(formatWon(p.low))~\(formatWon(p.high))",
                basis: SpendHistory.recordSummary(p)
            )
        }

        if q.contains("레이저") || q.contains("제모") {
            return ChatMessage(
                role: .agent,
                conclusion: "레이저 제모는 50,000원으로 잡았어요.",
                reason: "당일 결제로 확인돼서 범위 없이 확정 금액으로 반영했어요.",
                impact: "이번 주 일정비 \(rangeText(low: model.plannedSpendLow, high: model.plannedSpendHigh))",
                basis: "7월 20일 캘린더 일정 · 확인된 금액"
            )
        }

        if q.contains("가족") {
            return ChatMessage(
                role: .agent,
                conclusion: "가족 일정은 줄이지 않는 항목으로 두었어요.",
                reason: "7월 12일 가족 식사는 20,000원으로 반영했고, 다른 예산을 계산할 때 먼저 남겨둬요.",
                impact: "더 필요한 소비 · 가족과 데이트",
                basis: "성제님이 더 필요한 소비로 골라둔 일정이에요"
            )
        }

        if q.contains("적금") || q.contains("저축") || q.contains("목표") {
            return ChatMessage(
                role: .agent,
                conclusion: "현재 계획이면 \(formatWon(model.savingsGoal)) 저축 목표를 유지할 확률은 \(model.probability)%예요.",
                reason: "7월 일정비와 확인된 고정비를 먼저 반영했어요.",
                impact: "이번 주 추가 사용 가능액 약 \(formatWon(roundedWeeklyBudget))",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 7월 캘린더 · 저축 목표"
            )
        }

        if q.contains("이번주") || q.contains("얼마") || q.contains("더써") || q.contains("더쓸") || q.contains("괜찮") {
            return ChatMessage(
                role: .agent,
                conclusion: "이번 주에는 약 \(formatWon(roundedWeeklyBudget))을 더 써도 돼요.",
                reason: "7월 22일 기준 이번 주 남은 확정 일정은 ‘와드’ 40,000원뿐이에요. 출근과 회의는 비용이 들지 않아요.",
                impact: "이번 주 일정비 \(rangeText(low: model.plannedSpendLow, high: model.plannedSpendHigh)) 예상",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 저축 \(formatWon(model.savingsGoal)) · 확인된 일정 금액 기준"
            )
        }

        return ChatMessage(
            role: .agent,
            conclusion: "이번 주에는 약 \(formatWon(roundedWeeklyBudget))을 더 쓸 수 있어요.",
            reason: "어떤 일정인지 알려주면 그 비용까지 넣어 다시 계산할게요.",
            impact: "현재 일정비 \(rangeText(low: model.plannedSpendLow, high: model.plannedSpendHigh)) 예상",
            basis: "2026년 7월 캘린더 · 입력한 월수입과 저축 목표"
        )
    }
}

#Preview {
    ChatbotView().environmentObject(AppModel())
}
