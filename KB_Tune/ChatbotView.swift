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
    /// 답변에 붙는 실행 버튼. 에이전트가 말만 하지 않고 계획을 실제로 바꾸거나
    /// 다음 화면으로 데려가는 자리다. (기획 보고서 3절 '도구 호출 구조로 승격'의 축소판)
    enum Actions: Equatable {
        case addEvent
        case setDirection(SpendDirection)   // 다음 달 소비 방향을 저장
        case openProducts                   // 카드·적금 탭으로 이동
    }
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

    // 데모 흐름 순서대로 — 소비 질문 → 절감 지점 → 패턴 → 다음 달 방향 → 적금
    private let suggestions = [
        "오늘 7만원짜리 바지 사도 될까?",
        "어디서 줄이는 게 좋을까?",
        "내 소비 패턴 어때?",
        "다음 달은 어떻게 하는 게 좋을까?",
        "적금 통장 하나 더 만들고 싶은데?",
    ]
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
                // 확률 한 줄 대신, 목표를 지켰을 때 남는 돈과 예측 오차를 함께 보여준다(11.2).
                Text("이번 주 약 \(formatWon(roundedWeeklyBudget)) · 목표 달성 후 \(formatWon(monthEndSurplus)) 여유 · 오차 ±\(formatWon(monthEndMargin))")
                    .font(.caption)
                    .foregroundStyle(KB.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(KB.yellowSoft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("계획 도우미. 이번 주 사용 가능액 약 \(formatWon(roundedWeeklyBudget)), 저축 목표 달성 후 약 \(formatWon(monthEndSurplus)) 여유, 예상 오차 ±\(formatWon(monthEndMargin))")
    }

    /// 저축 목표를 지킨 뒤 월말에 남을 것으로 보이는 금액(예상범위의 대표값)
    private var monthEndSurplus: Int {
        (model.monthEndRemainingLow + model.monthEndRemainingHigh) / 2
    }
    /// 예상범위의 폭 — 대표금액 대비 오차로 보여준다
    private var monthEndMargin: Int {
        (model.monthEndRemainingHigh - model.monthEndRemainingLow) / 2
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
                smallAction("100,000원 예약", filled: true) { flash("8월 2일 데이트 100,000원을 8월 계획 예산에 예약했어요.") }
                smallAction("금액 변경", filled: false) {
                    input = "200일 데이트 예산을 "
                    inputFocused = true
                }
                smallAction("예약하지 않기", filled: false) { flash("이번엔 예약하지 않을게요.") }
            }
            .padding(.top, 2)

        case .setDirection(let dir):
            HStack(spacing: 8) {
                smallAction("\(dir.label)로 정하기", filled: true) {
                    withAnimation(.snappy(duration: 0.25)) { model.direction = dir }
                    flash("다음 달 소비 방향을 ‘\(dir.label)’로 저장했어요. 설정에서 언제든 바꿀 수 있어요.")
                }
                smallAction("지금은 유지", filled: false) { flash("방향은 그대로 둘게요.") }
            }
            .padding(.top, 2)

        case .openProducts:
            HStack(spacing: 8) {
                smallAction("적금 보러 가기", filled: true) {
                    withAnimation(.easeInOut(duration: 0.3)) { model.selectedTab = .products }
                }
                smallAction("나중에", filled: false) { flash("필요할 때 다시 물어봐 주세요.") }
            }
            .padding(.top, 2)

        case nil:
            EmptyView()
        }
    }

    private var typingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image("AgentMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(thinkingSteps[min(thinkingStep, thinkingSteps.count - 1)])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KB.ink)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("chat-thinking")
                TypingDots()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .elevatedCard(16)

            Spacer(minLength: 44)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
        withAnimation(.easeOut(duration: 0.25)) { isThinking = true }

        Task {
            let minimumDelay = Task {
                try? await Task.sleep(for: .milliseconds(1_600))
            }
            let stageUpdates = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { thinkingStep = 1 }
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { thinkingStep = 2 }
            }

            // LLM 키가 없으면 백엔드도 템플릿으로 답한다. 그 템플릿보다 앱 답변이
            // 카드 청구·앞으로의 일정·카테고리까지 알고 있어서 낫다. 그래서 키가 있을 때만 호출한다.
            var streamed = ""
            var ok = false
            if agent.llmEnabled {
                ok = await agent.chatStream(trimmed, model: model) { delta in
                    streamed += delta
                }
            }

            _ = await minimumDelay.result
            stageUpdates.cancel()
            withAnimation(.easeOut(duration: 0.25)) { isThinking = false }

            if ok, !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(ChatMessage(
                    role: .agent,
                    conclusion: streamed.trimmingCharacters(in: .whitespacesAndNewlines),
                    basis: "2026년 7월 캘린더 · 입력한 월수입과 저축 목표",
                    // 실제 LLM이 답할 때도 실행 버튼은 붙어야 한다. 문장은 모델이 만들고
                    // 무엇을 할 수 있는지는 질문 의도로 정한다.
                    actions: demoActions(for: trimmed),
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

    /// 오늘 기준 이번 주에 남은 확정 일정을 그대로 읽어준다 — 날짜가 바뀌면 문장도 바뀐다.
    private var remainingWeekReason: String {
        let events = model.week
            .filter { $0.dayNumber >= model.todayDayNumber }
            .flatMap(\.events)
            .filter { $0.amount > 0 }
        guard !events.isEmpty else {
            return "7월 \(model.todayDayNumber)일 기준 이번 주에 남은 확정 일정은 없어요. 출근과 회의는 비용이 들지 않아요."
        }
        let names = events.map(\.title).joined(separator: "·")
        let total = events.reduce(0) { $0 + $1.amount }
        return "7월 \(model.todayDayNumber)일 기준 이번 주 남은 확정 일정은 ‘\(names)’ \(formatWon(total))이에요. 출근과 회의는 비용이 들지 않아요."
    }

    // MARK: 로컬 스크립트 에이전트 (백엔드가 없을 때)

    /// 질문 의도로 실행 버튼을 정한다. 답변 문장은 LLM이 만들어도 '무엇을 할 수 있는지'는
    /// 앱이 알아야 하므로, 문장 파싱이 아니라 질문에서 판단한다.
    private func demoActions(for text: String) -> ChatMessage.Actions? {
        let q = text.replacingOccurrences(of: " ", with: "")
        if q.contains("적금") || q.contains("통장") { return .openProducts }
        if q.contains("다음달") || q.contains("방향") {
            return .setDirection(model.probability < AppModel.atRiskProbability ? .reduce : .maintain)
        }
        return nil
    }

    /// 오늘 이후 잡혀 있는 지출 일정 — 조언의 근거로 되풀이해 쓰인다.
    private var upcomingEvents: [(day: Int, title: String, amount: Int)] {
        model.calendarDays
            .filter { $0.dayNumber >= model.todayDayNumber }
            .flatMap { d in d.events.filter { $0.amount > 0 }.map { (d.dayNumber, $0.title, $0.amount) } }
    }

    private var upcomingTotal: Int { upcomingEvents.reduce(0) { $0 + $1.amount } }

    private var upcomingSummary: String {
        upcomingEvents.map { "7/\($0.day) \($0.title) \(formatWon($0.amount))" }
            .joined(separator: " · ")
    }

    /// 분석 탭 기준 가장 큰 지출 카테고리 — "어디 줄이지?"의 답이 되는 곳.
    private var topCategory: SpendCategory? {
        model.spendProfile.max { $0.monthly < $1.monthly }
    }

    private func agentReply(to text: String) -> ChatMessage {
        let q = text.replacingOccurrences(of: " ", with: "")
        let b = model.billing

        // ① 지금 이걸 사도 되나 — 이번 주 예산 + 앞으로의 일정 + 다음 달 카드값을 함께 본다.
        if q.contains("사도") || q.contains("살까") || q.contains("바지") || q.contains("구매") || q.contains("지를") {
            let over = max(0, upcomingTotal - BudgetEngine.remainingBudget(income: model.monthlyIncome,
                                                                          savingsGoal: model.savingsGoal))
            let tight = model.weeklyBudget == 0 || over > 0
            return ChatMessage(
                role: .agent,
                conclusion: tight
                    ? "지금 사면 이번 달 계획이 흔들려요. 사고 싶으면 앞으로의 약속 중 하나를 다음 달로 옮기는 걸 먼저 볼게요."
                    : "이번 주 여유 안에서는 가능해요. 다만 다음 달 카드값도 같이 보고 정하는 게 좋아요.",
                reason: upcomingEvents.isEmpty
                    ? "이번 주 남은 확정 일정은 없어요."
                    : "앞으로 \(upcomingSummary)이 잡혀 있어서 남은 예산 \(formatWon(BudgetEngine.remainingBudget(income: model.monthlyIncome, savingsGoal: model.savingsGoal)))에서 \(formatWon(upcomingTotal))이 이미 예약된 상태예요.",
                impact: "이번 주 사용 가능액 \(formatWon(model.weeklyBudget)) · \(b.payLabel) 카드값 \(formatWon(b.dueNext))에 얹혀요",
                basis: "7월 캘린더 · KB ALL 카드 이용내역 \(b.count)건 \(formatWon(b.usage)) · 할부 이월 \(formatWon(b.carryover))"
            )
        }

        // ② 어디서 줄일까 — 보호 소비는 건드리지 않고 가장 큰 카테고리부터 제안한다.
        if q.contains("줄") || q.contains("아껴") || q.contains("절약") || q.contains("어디서") {
            let top = topCategory
            return ChatMessage(
                role: .agent,
                conclusion: top.map { "\($0.name)부터 보는 게 효과가 커요. 이번 달 \(formatWon($0.monthly))으로 가장 크거든요." }
                    ?? "줄일 곳을 찾으려면 이번 달 지출부터 볼게요.",
                reason: "\(model.protectedList) 소비는 지키기로 했으니 그대로 두고, 나머지에서 찾았어요.",
                impact: "분석 탭에서 필수·기타로 나눈 내역을 보면 어디가 늘었는지 바로 보여요",
                basis: "7월 캘린더 일정비 \(formatWon(model.spendMonthly)) 기준"
            )
        }

        // ③ 내 소비 패턴 — 반복되는 것과 이번 달에 튄 것을 구분해 말한다.
        if q.contains("패턴") || q.contains("어떻게썼") || q.contains("소비습관") || q.contains("분석") {
            let cadences = SpendHistory.patterns.prefix(3)
                .map { "\($0.key) \($0.cadenceLabel)마다 \(formatWon($0.avgAmount))" }
                .joined(separator: " · ")
            return ChatMessage(
                role: .agent,
                conclusion: "반복되는 소비가 뚜렷한 편이에요. \(cadences).",
                reason: topCategory.map { "이번 달은 \($0.name)이 \(formatWon($0.monthly))으로 가장 컸어요." } ?? "",
                impact: "주기가 규칙적이라 다음 달 지출도 미리 잡아둘 수 있어요",
                basis: "최근 이력에서 찾은 반복 주기 · 7월 캘린더"
            )
        }

        // ④ 다음 달은 어떻게 — 방향을 제안하고 그 자리에서 저장까지.
        if q.contains("다음달") || q.contains("다음달엔") || q.contains("방향") || q.contains("어떻게하") {
            let suggested: SpendDirection = model.probability < AppModel.atRiskProbability ? .reduce : .maintain
            return ChatMessage(
                role: .agent,
                conclusion: "다음 달은 ‘\(suggested.label)’를 추천해요.",
                reason: "지금 목표 확률이 \(model.probability)%이고, \(b.nextPayLabel)에 할부 \(formatWon(b.carryover))이 자동으로 얹혀서 시작부터 여유가 줄어요.",
                impact: suggested.note,
                basis: "적금 목표 \(formatWon(model.savingsGoal)) · 카드 할부 잔여 \(formatWon(b.carryover))",
                actions: .setDirection(suggested)
            )
        }

        // ⑤ 적금 — 지금 여력으로 넣을 수 있는 금액을 말하고 상품 탭으로 넘긴다.
        if q.contains("적금") || q.contains("통장") || q.contains("저축") && q.contains("만들") {
            return ChatMessage(
                role: .agent,
                conclusion: "지금 계획이면 적금을 하나 더 만들 여지가 있어요.",
                reason: "이번 달 남은 예산이 \(formatWon(BudgetEngine.remainingBudget(income: model.monthlyIncome, savingsGoal: model.savingsGoal)))이고, 목표 확률은 \(model.probability)%예요.",
                impact: "\(b.nextPayLabel)에 카드 할부 \(formatWon(b.carryover))이 빠지는 것까지 고려해서 금액을 정하는 게 좋아요",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 저축 목표 \(formatWon(model.savingsGoal))",
                actions: .openProducts
            )
        }

        // ⑥ 카드값 — 이용액과 실제 청구액의 차이를 짚는다.
        if q.contains("카드값") || q.contains("청구") || q.contains("할부") || q.contains("결제일") {
            return ChatMessage(
                role: .agent,
                conclusion: "\(b.payLabel)에 \(formatWon(b.dueNext))이 빠져나가요.",
                reason: "이번 이용기간에 \(b.count)건 \(formatWon(b.usage))을 썼는데, 그중 \(formatWon(b.carryover))은 할부라 \(b.nextPayLabel)로 넘어가요.",
                impact: "다음 달은 시작부터 \(formatWon(b.carryover))이 얹힌 상태예요",
                basis: "KB ALL 카드(2054) 이용기간 \(b.periodLabel)"
            )
        }

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
                conclusion: "8월 2일 200일 데이트 비용으로 100,000원을 8월 계획 예산에 예약할까요? 실제 출금은 없어요.",
                reason: "아직 금액이 없어서 식사·카페·이동을 포함한 예산으로 잡았어요.",
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
                reason: remainingWeekReason,
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

/// 답변을 기다리는 동안 살아 있는 느낌을 주는 타이핑 점(웨이브 애니메이션).
private struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(KB.ink.opacity(0.5))
                    .frame(width: 6.5, height: 6.5)
                    .scaleEffect(animating ? 1 : 0.5)
                    .opacity(animating ? 1 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

#Preview {
    ChatbotView().environmentObject(AppModel())
}
