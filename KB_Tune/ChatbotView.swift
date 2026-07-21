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
    let role: Role
    var conclusion: String                 // 결론(본문)
    var reason: String? = nil              // 이유
    var impact: String? = nil              // 영향(전/후)
    var basis: String? = nil               // 계산 근거(접기)
    var preview: EventPreview? = nil       // 대화 속 일정 미리보기
    var showActions: Bool = false
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
    @State private var toast: String?

    private let suggestions = ["금요일 2차 가도 돼?", "배달비 왜 늘었어?", "적금 목표 다시 맞춰줘"]

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
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
            Text("이번 주 사용 가능액 \(formatWon(model.weeklyBudget)) · 목표 확률 \(model.probability)%")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.ink)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(KB.yellowSoft)
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
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(KB.yellow).frame(width: 30, height: 30)
                    Image(systemName: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                }
                agentCard(msg)
                Spacer(minLength: 24)
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

            if msg.showActions {
                HStack(spacing: 8) {
                    smallAction("일정 추가", filled: true) { flash("일정을 계획에 추가했어요.") }
                    smallAction("금액 바꾸기", filled: false) { flash("금액을 조정할 수 있어요.") }
                }
                .padding(.top, 2)
            }
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

    private var typingBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(KB.yellow).frame(width: 30, height: 30)
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(KB.ink)
            }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(KB.muted).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
            Spacer()
        }
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
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.vertical, 10)
    }

    // MARK: 입력창

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("계획에 대해 물어보세요", text: $input)
                .font(.system(size: 14))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit { send(input) }

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
            conclusion: "안녕하세요! 이번 주 계획을 함께 조정해드릴게요.",
            reason: "약속을 잡아도 되는지, 무엇을 옮기면 좋은지 편하게 물어보세요.",
            basis: "최근 3개월(\(model.analysisPeriod)) 소비와 ‘\(model.protectedSummary)’를 기준으로 계산해요."
        ))
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, conclusion: trimmed))
        input = ""
        isThinking = true

        // 1순위: 백엔드 스트리밍(Claude). 실패 시 로컬 폴백.
        Task {
            var streamIndex: Int? = nil
            var streamed = ""
            let ok = await agent.chatStream(trimmed, direction: model.direction) { delta in
                if streamIndex == nil {
                    isThinking = false
                    messages.append(ChatMessage(role: .agent, conclusion: "", isStream: true))
                    streamIndex = messages.count - 1
                }
                streamed += delta
                if let i = streamIndex, i < messages.count {
                    messages[i].conclusion = streamed
                }
            }
            if ok, let i = streamIndex, i < messages.count {
                messages[i].basis = "Claude가 엔진(BudgetEngine) 계산값을 근거로 답했어요."
            } else if !ok {
                // 백엔드/키 없음 → 로컬 엔진 + 스크립트 폴백
                isThinking = false
                if streamIndex == nil {
                    messages.append(agentReply(to: trimmed))
                }
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

    // MARK: 로컬 스크립트 에이전트 (⇦ 교체 지점: 백엔드/Claude)

    private func agentReply(to text: String) -> ChatMessage {
        let q = text.replacingOccurrences(of: " ", with: "")

        if q.contains("금요일") || q.contains("2차") || q.contains("생일") {
            return ChatMessage(
                role: .agent,
                conclusion: "금요일 2차는 조정을 추천해요.",
                reason: "‘생일파티 2차’ 40,000원이 이번 주 예산을 36,000원 넘겨요. 1차까지만 하거나 다음 주로 옮기면 계획을 지킬 수 있어요.",
                impact: "조정 시 52,000원 · 78% 유지 — 그대로 가면 목표 확률 61%",
                basis: "이번 주 확정 지출(팀플·동아리 모임·영화)과 남은 예산 기준. 확률은 현재 계획 기준 시뮬레이션이에요.",
                showActions: true
            )
        }

        if q.contains("모임") || q.contains("더써") || q.contains("더가") || q.contains("일요일") {
            return ChatMessage(
                role: .agent,
                conclusion: "예상 20,000원까지는 괜찮아요.",
                reason: "최근 3개월 모임 지출과 이번 주 일정을 반영했어요. 지키기로 한 ‘모임’은 그대로 두었어요.",
                impact: "사용 가능액 52,000원 → 32,000원 · 목표 확률 78% → 76%",
                basis: "이번 주 확정 지출(팀플·동아리 모임·영화)과 남은 예산 기준. 확률은 현재 계획 기준 시뮬레이션이에요.",
                preview: EventPreview(title: "일요일 모임", amount: 20_000, day: "7월 26일 일요일"),
                showActions: true
            )
        }

        if q.contains("외식") || q.contains("배달") || q.contains("왜늘") {
            return ChatMessage(
                role: .agent,
                conclusion: "시험기간에 배달이 4회 늘어서예요.",
                reason: "4~6월 평균 대비 7월 외식·배달 횟수가 늘었어요. 대부분 시험기간 야식과 팀플 후 식사예요.",
                impact: "외식·배달 카테고리 월 예상 +32,000원",
                basis: "카테고리별 거래 횟수·금액 집계 기준(2026.04~06 대비 07)."
            )
        }

        if q.contains("적금") || q.contains("목표") {
            return ChatMessage(
                role: .agent,
                conclusion: "지금 계획대로면 목표 확률 78%예요.",
                reason: "이번 달 방향 ‘\(model.direction.label)’ 기준이에요. 금요일 2차만 조정하면 확률을 지킬 수 있어요.",
                impact: "조정 시 78% 유지 · 그대로 두면 61%",
                basis: "월 저축 목표 \(formatWon(model.savingsGoal))와 남은 변동지출 기준 시뮬레이션.",
                showActions: true
            )
        }

        return ChatMessage(
            role: .agent,
            conclusion: "이번 주는 \(formatWon(model.weeklyBudget))까지 쓸 수 있어요.",
            reason: "지키기로 한 소비는 유지한 채 계산했어요. 특정 일정이나 금액을 물어보면 더 정확히 알려드릴게요.",
            basis: "최근 3개월(\(model.analysisPeriod)) 소비와 이번 주 확정 지출 기준."
        )
    }
}

#Preview {
    ChatbotView().environmentObject(AppModel())
}
