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
        case moveEvent(day: Int, eventID: UUID, title: String, amount: Int)
        /// 되묻기 — 모르는 걸 추측해서 답하지 않고 사용자가 고르게 한다.
        /// 고른 답이 다시 질문으로 들어가 대화가 이어진다.
        case choices([String])
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

/// 모델이 보내온 자유 문장을 읽기 좋게 그린다.
///
/// 통짜로 한 덩어리를 그리면 결론과 근거가 같은 무게로 붙어 벽이 된다.
/// 빈 줄을 기준으로 문단을 나누고, 첫 문단(결론)만 굵게 세운다.
/// 금액·비율은 굵게 살린다 — 문장 안에 숫자가 묻히면 판단할 근거가 안 보인다.
struct StreamedAnswer: View {
    let text: String

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { i, para in
                Text(Self.highlightNumbers(para))
                    .font(.kb(i == 0 ? 15 : 14, i == 0 ? .semibold : .regular))
                    .foregroundStyle(i == 0 ? KB.ink : KB.ink.opacity(0.88))
                    .lineSpacing(i == 0 ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 금액(1,234원)·비율(39%)·날짜(8월 14일 · 7/30)를 굵게.
    ///
    /// 마크다운으로 감싸는 방법은 쓰지 않는다. `**39%**라서`처럼 닫는 표시 왼쪽이 기호(%)이고
    /// 오른쪽이 한글이면 강조가 닫히지 않아 별표가 그대로 화면에 남는다.
    /// 범위에 직접 굵기만 얹으면 문단마다 다른 글자 크기도 그대로 상속된다.
    static func highlightNumbers(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        let patterns = [
            #"[\d,]+\s*~\s*[\d,]+원"#,   // 범위가 먼저 — 단일 금액 규칙에 잘리지 않게
            #"[\d,]+원"#,
            #"\d+%"#,
            #"\d+월\s*\d+일"#,
            #"\d+/\d+"#,
        ]
        let full = NSRange(s.startIndex..., in: s)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in regex.matches(in: s, range: full) {
                guard let r = Range(m.range, in: s),
                      let ar = Range(r, in: attr) else { continue }
                attr[ar].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return attr
    }
}

/// 적금을 왜 만드는지. 목적에 따라 맞는 기간·상품이 달라서 먼저 물어본다.
enum SavingsPurpose: CaseIterable {
    case emergency, lumpSum, goal

    var label: String {
        switch self {
        case .emergency: "비상금"
        case .lumpSum: "목돈 모으기"
        case .goal: "정해둔 목표"
        }
    }
    /// 사용자가 고른 답을 되받을 때 찾는 말
    var matchKey: String { label.replacingOccurrences(of: " ", with: "") }

    var termLabel: String {
        switch self {
        case .emergency: "언제든 뺄 수 있는 자유적립"
        case .lumpSum: "12개월 정기적금"
        case .goal: "목표일에 맞춘 기간"
        }
    }
    var reason: String {
        switch self {
        case .emergency:
            "비상금은 급할 때 바로 빼 쓸 수 있어야 해서, 금리가 조금 낮아도 중도해지 부담이 없는 쪽이 나아요."
        case .lumpSum:
            "목돈은 만기까지 두는 게 전제라 금리를 우선해서 고르면 돼요."
        case .goal:
            "목표 날짜가 있으면 그 날짜에 만기가 오도록 기간을 맞추는 게 먼저예요."
        }
    }
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
    @State private var showConsent = false
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
        "일정을 같이 보고 있어요",
        "카드 사용까지 확인했어요",
        "답을 정리하고 있어요",
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
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }
                .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: isThinking) { _, _ in scrollToEnd(proxy) }
            }

            // 답변 안에 실행 버튼이 있을 때 추천 질문이 그 버튼과 경쟁하지 않게 한다.
            if !isThinking, messages.last?.actions == nil {
                chips
            }
            inputBar
        }
        .background(KB.canvas)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.kb(13, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(KB.green, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear(perform: seedIfNeeded)
        .task {
            await agent.ping()
            // 백엔드가 실제로 외부 모델을 쓸 때만 물어본다. offline이면 나가는 게 없으니
            // 동의를 받을 일도 없다 — 의미 없는 팝업을 띄우지 않기 위해서.
            showConsent = agent.llmEnabled && !EventTitleConsent.asked
        }
        .sheet(isPresented: $showConsent) { consentSheet }
    }

    // MARK: 일정 제목 공유 동의

    private var consentSheet: some View {
        SheetContainer(title: "일정 제목도 같이 볼까요?") {
            VStack(alignment: .leading, spacing: 16) {
                Text("답변은 AI가 만들어요. 이때 이번 달 일정과 금액이 AI 제공자에게 전달돼요.")
                    .font(.kb(14)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)

                consentRow(icon: "text.bubble.fill", tint: KB.green, title: "제목까지 보내면",
                           detail: "\"25일 결혼식이 있으니 이번 주 지출을 옮겨보세요\"처럼 구체적으로 답해요.")
                consentRow(icon: "lock.fill", tint: KB.muted, title: "유형·금액만 보내면",
                           detail: "\"25일 경조사 지출이 있어요\"까지만 답해요. 제목은 기기 밖으로 안 나가요.")

                Text("이름과 나이는 어느 쪽이든 보내지 않아요. 설정에서 언제든 바꿀 수 있어요.")
                    .font(.kb(11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    consentButton("유형·금액만", filled: false) { chooseConsent(false) }
                    consentButton("제목까지 함께", filled: true) { chooseConsent(true) }
                }
            }
        }
        // X로 닫거나 쓸어내리면 '보내지 않음'으로 본다 — 답을 안 한 걸 동의로 치지 않는다.
        .onDisappear { if !EventTitleConsent.asked { EventTitleConsent.set(false) } }
    }

    private func consentRow(icon: String, tint: Color,
                            title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.kb(13.5, .semibold)).foregroundStyle(KB.ink)
                Text(detail).font(.kb(12)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func consentButton(_ label: String, filled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.kb(14, .semibold))
                .foregroundStyle(KB.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(filled ? KB.yellow : .white,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(filled ? .clear : KB.line, lineWidth: 1))
        }
    }

    private func chooseConsent(_ granted: Bool) {
        EventTitleConsent.set(granted)
        showConsent = false
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
                HStack(spacing: 5) {
                    Text("Tune")
                    Circle().fill(KB.green).frame(width: 6, height: 6)
                }
                    .font(.kb(15, .semibold))
                    .foregroundStyle(KB.ink)
                Text("일정과 소비를 함께 보고 있어요")
                    .font(.kb(12))
                    .foregroundStyle(KB.muted)
            }
            Spacer()
            Text("이번 주 \(formatWon(model.weeklyBudget))")
                .font(.kb(11.5, .semibold))
                .foregroundStyle(KB.ink)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.8), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(KB.yellowSoft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tune 계획 도우미. 이번 주 추가 사용 가능액 \(formatWon(model.weeklyBudget))")
    }

    // MARK: 말풍선

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(msg.conclusion)
                    .font(.kb(14)).foregroundStyle(KB.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(KB.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image("AgentMascot")
                    .resizable().scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tune")
                        .font(.kb(11, .semibold))
                        .foregroundStyle(KB.muted)
                    agentCard(msg)
                }
                Spacer(minLength: 28)
            }
        }
    }

    private func agentCard(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if msg.isStream {
                StreamedAnswer(text: msg.conclusion)
            } else {
                Text(msg.conclusion)
                    .font(.kb(14, .semibold)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reason = msg.reason {
                Text(reason).font(.kb(13)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let impact = msg.impact {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(KB.violet)
                    Text(impact).font(.kb(12.5, .medium)).foregroundStyle(KB.ink)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(KB.canvas, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if let preview = msg.preview {
                previewRow(preview)
            }

            if let basis = msg.basis {
                DisclosureGroup {
                    Text(basis).font(.kb(12)).foregroundStyle(KB.muted)
                        .padding(.top, 4)
                } label: {
                    Text("왜 이렇게 답했어요?").font(.kb(12, .medium)).foregroundStyle(KB.muted)
                }
                .tint(KB.muted)
            }

            actionButtons(for: msg.actions)
        }
        .padding(14)
        .background(.white, in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 16,
                                                       bottomTrailingRadius: 16, topTrailingRadius: 16,
                                                       style: .continuous))
        .shadow(color: KB.cardShadow.opacity(0.65), radius: 8, x: 0, y: 3)
    }

    private func previewRow(_ p: EventPreview) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemName: "calendar", background: KB.yellowSoft, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.kb(13, .medium)).foregroundStyle(KB.ink)
                Text(p.day).font(.kb(11.5)).foregroundStyle(KB.muted)
            }
            Spacer()
            Text(formatWon(p.amount)).font(.kb(13, .semibold)).foregroundStyle(KB.ink)
        }
        .padding(10)
        .background(KB.canvas, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func smallAction(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.kb(12.5, .semibold)).foregroundStyle(KB.ink)
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

        case .choices(let options):
            // 고르면 그 답이 그대로 다음 질문이 된다 — 타이핑 없이 대화가 이어진다.
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    smallAction(option, filled: false) { send(option) }
                }
            }
            .padding(.top, 4)

        case .openProducts:
            HStack(spacing: 8) {
                smallAction("적금 보러 가기", filled: true) {
                    model.wantsSavings = true    // 넘어간 화면이 적금 쪽을 열어둔다
                    withAnimation(.easeInOut(duration: 0.3)) { model.selectedTab = .products }
                }
                smallAction("나중에", filled: false) { flash("필요할 때 다시 물어봐 주세요.") }
            }
            .padding(.top, 2)

        case .moveEvent(let day, let eventID, let title, let amount):
            HStack(spacing: 8) {
                smallAction("다음 주로 옮기기", filled: true) {
                    guard let event = model.day(number: day)?.events.first(where: { $0.id == eventID }) else {
                        flash("일정을 다시 확인해 주세요.")
                        return
                    }
                    model.moveEventToNextWeek(event, from: day)
                    flash("‘\(title)’을 다음 주로 옮겼어요. 이번 주에 \(formatWon(amount)) 여유가 생겼어요.")
                }
                smallAction("다른 일정 보기", filled: false) {
                    input = "다른 일정 중에서 미룰 만한 건 뭐야?"
                    inputFocused = true
                }
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
                    .font(.kb(13, .medium))
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

    /// 아직 물어보지 않은 질문만 최대 2개. 대화가 진행될수록 다음 단계가 앞으로 나온다.
    private var remainingSuggestions: [String] {
        let asked = Set(messages.filter { $0.role == .user }.map(\.conclusion))
        let last = messages.last(where: { $0.role == .user })?.conclusion
            .replacingOccurrences(of: " ", with: "") ?? ""
        let contextual: [String]
        if last.contains("사도") || last.contains("구매") || last.contains("바지") {
            contextual = ["그럼 뭘 미루면 돼?", "안 사고 아끼면 뭐가 달라져?"]
        } else if last.contains("패턴") || last.contains("분석") {
            contextual = ["다음 달엔 뭘 먼저 줄일까?", "반복 지출만 따로 보여줘"]
        } else if last.contains("적금") || last.contains("통장") {
            contextual = ["비상금으로 만들고 싶어", "월 얼마가 무리 없을까?"]
        } else if last.contains("미루") || last.contains("미뤄") || last.contains("미룰") || last.contains("옮겨") || last.contains("연기") {
            contextual = ["옮기면 이번 주 얼마가 남아?", "다른 일정도 비교해줘"]
        } else {
            contextual = suggestions.filter { !asked.contains($0) }
        }
        return Array(contextual.prefix(2))
    }

    /// 가로 스크롤을 쓰지 않는다 — 페이지형 탭 안에서 가로 스와이프는 탭 전환에 먹혀,
    /// 칩을 넘기려던 손짓이 화면을 바꿔버린다. 줄바꿈으로 감싸면 그 충돌 자체가 없다.
    private var chips: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(messages.count <= 1 ? "이렇게 물어보세요" : "이어서 물어보기")
                .font(.kb(11.5, .medium)).foregroundStyle(KB.muted)
            FlowLayout(spacing: 8) {
                ForEach(remainingSuggestions, id: \.self) { q in
                    Button { send(q) } label: {
                        Text(q).font(.kb(13)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.white, in: Capsule())
                            .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isThinking)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.25), value: remainingSuggestions)
    }

    // MARK: 입력창

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("편하게 말해 주세요", text: $input)
                .font(.kb(14))
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
                    .font(.kb(17, .bold)).foregroundStyle(KB.ink)
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
            conclusion: "성제님, 지금 계획은 제가 같이 볼게요.",
            reason: "사고 싶은 게 있거나 미루고 싶은 일정이 있으면 편하게 말해 주세요."
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
                try? await Task.sleep(for: .milliseconds(850))
            }
            let stageUpdates = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { thinkingStep = 1 }
                try? await Task.sleep(for: .milliseconds(300))
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
        Task { @MainActor in
            // 답변과 추천 영역이 같은 프레임에서 바뀐 뒤의 실제 높이를 기준으로 맞춘다.
            await Task.yield()
            withAnimation(.easeOut(duration: 0.25)) {
                if isThinking { proxy.scrollTo("typing", anchor: .bottom) }
                else { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut) { toast = nil }
        }
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
            return "\(DemoClock.dayLabel(of: model.todayDayNumber)) 기준 이번 주에 남은 확정 일정은 없어요. 출근과 회의는 비용이 들지 않아요."
        }
        let names = events.map(\.title).joined(separator: "·")
        let total = events.reduce(0) { $0 + $1.amount }
        return "\(DemoClock.dayLabel(of: model.todayDayNumber)) 기준 이번 주 남은 확정 일정은 ‘\(names)’ \(formatWon(total))이에요. 출근과 회의는 비용이 들지 않아요."
    }

    // MARK: 로컬 스크립트 에이전트 (백엔드가 없을 때)

    /// 질문 의도로 실행 버튼을 정한다. 답변 문장은 LLM이 만들어도 '무엇을 할 수 있는지'는
    /// 앱이 알아야 하므로, 문장 파싱이 아니라 질문에서 판단한다.
    private func demoActions(for text: String) -> ChatMessage.Actions? {
        let q = text.replacingOccurrences(of: " ", with: "")
        if q.contains("적금") || q.contains("통장") { return .openProducts }
        // 미루기는 LLM이 답할 때도 실행 버튼이 붙어야 한다. 문장만 주고 주간 화면으로
        // 돌려보내면 "대화에서 바로 조정한다"는 이 앱의 핵심이 사라진다.
        if isMoveRequest(q), let candidate = model.movableEventThisWeek {
            return .moveEvent(day: candidate.day, eventID: candidate.event.id,
                              title: candidate.event.title, amount: candidate.event.amount)
        }
        if q.contains("다음달") || q.contains("방향") {
            return .setDirection(model.probability < AppModel.atRiskProbability ? .reduce : .maintain)
        }
        return nil
    }

    /// 일정을 미뤄달라는 뜻인지 — 로컬 답변과 LLM 답변이 같은 기준을 쓴다.
    private func isMoveRequest(_ q: String) -> Bool {
        q.contains("미루") || q.contains("미뤄") || q.contains("미룰")
            || q.contains("옮겨") || q.contains("연기")
    }

    /// 오늘 이후 잡혀 있는 지출 일정 — 조언의 근거로 되풀이해 쓰인다.
    private var upcomingEvents: [(day: Int, title: String, amount: Int)] {
        model.calendarDays
            .filter { $0.dayNumber >= model.todayDayNumber }
            .flatMap { d in d.events.filter { $0.amount > 0 }.map { (d.dayNumber, $0.title, $0.amount) } }
    }

    private var upcomingTotal: Int { upcomingEvents.reduce(0) { $0 + $1.amount } }

    private var upcomingSummary: String {
        upcomingEvents.map { "\(DemoClock.shortLabel(of: $0.day)) \($0.title) \(formatWon($0.amount))" }
            .joined(separator: " · ")
    }

    /// 분석 탭 기준 가장 큰 지출 카테고리 — "어디 줄이지?"의 답이 되는 곳.
    private var topCategory: SpendCategory? {
        model.spendProfile.max { $0.monthly < $1.monthly }
    }

    private func agentReply(to text: String) -> ChatMessage {
        let q = text.replacingOccurrences(of: " ", with: "").lowercased()
        let b = model.billing

        // 금융 질문 사이에 짧은 인사가 들어와도 갑자기 예산 답변으로 돌리지 않는다.
        if q.contains("안녕") || q == "hi" || q == "hello" {
            return ChatMessage(
                role: .agent,
                conclusion: "안녕하세요, 성제님. 오늘은 어떤 소비가 마음에 걸려요?",
                reason: "금액만 말해도 되고, 미루고 싶은 일정 이름만 말해도 돼요."
            )
        }

        // 대화에서 바로 일정 이동까지 이어진다. 말만 추천하고 주간 화면으로 돌려보내지 않는다.
        if isMoveRequest(q) {
            guard let candidate = model.movableEventThisWeek else {
                // 달의 마지막 주에는 옮길 곳이 이 달 안에 없다. 그때는 금액을 줄이는 쪽을 알려준다.
                if case .reduce(_, let event, let to)? = model.suggestedAdjustment {
                    return ChatMessage(
                        role: .agent,
                        conclusion: "이번 주는 이 달의 마지막 주라, 다음 주로 옮기면 8월이 돼요.",
                        reason: "대신 ‘\(event.title)’ 예산을 \(formatWon(to))으로 줄이는 방법이 있어요. 주간 화면의 조정안에서 바로 적용할 수 있어요.",
                        impact: "줄이면 이번 주에 \(formatWon(event.amount - to)) 여유가 생겨요"
                    )
                }
                return ChatMessage(
                    role: .agent,
                    conclusion: "이번 주에 옮기거나 줄일 수 있는 일정은 없어요.",
                    reason: "남은 일정이 모두 지켜두기로 한 소비예요."
                )
            }
            return ChatMessage(
                role: .agent,
                conclusion: "‘\(candidate.event.title)’을 다음 주로 옮기는 게 가장 자연스러워요.",
                reason: "지켜두기로 한 소비는 건드리지 않고, 날짜를 바꿀 수 있는 일정부터 골랐어요.",
                impact: "옮기면 이번 주 추가 사용 가능액이 \(formatWon(candidate.event.amount)) 늘어요",
                basis: "\(DemoClock.dayLabel(of: candidate.day)) 일정 · 현재 금액 \(formatWon(candidate.event.amount))",
                actions: .moveEvent(day: candidate.day, eventID: candidate.event.id,
                                    title: candidate.event.title, amount: candidate.event.amount)
            )
        }

        // ① 지금 이걸 사도 되나 — 이번 주 예산 + 앞으로의 일정 + 다음 달 카드값을 함께 본다.
        if q.contains("사도") || q.contains("살까") || q.contains("바지") || q.contains("구매") || q.contains("지를") {
            let over = max(0, upcomingTotal - BudgetEngine.remainingBudget(income: model.monthlyIncome,
                                                                          savingsGoal: model.savingsGoal))
            let tight = model.weeklyBudget == 0 || over > 0
            return ChatMessage(
                role: .agent,
                conclusion: tight
                    ? "지금 사면 이번 달 계획이 흔들려요. 사고 싶으면 앞으로의 약속 중 하나를 다음 달로 옮기는 걸 먼저 볼게요."
                    : "이번 주 여유 안에서는 가능해요. 다만 다음 달 카드 청구액도 같이 보고 정하는 게 좋아요.",
                reason: upcomingEvents.isEmpty
                    ? "이번 주 남은 확정 일정은 없어요."
                    : "앞으로 \(upcomingSummary)이 잡혀 있어서 남은 예산 \(formatWon(BudgetEngine.remainingBudget(income: model.monthlyIncome, savingsGoal: model.savingsGoal)))에서 \(formatWon(upcomingTotal))이 이미 예약된 상태예요.",
                impact: "이번 주 추가 사용 가능액 \(formatWon(model.weeklyBudget)) · \(b.payLabel) 카드 청구액 \(formatWon(b.dueNext))에 얹혀요",
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
                basis: "7월 캘린더 예상 지출 \(formatWon(model.spendMonthly)) 기준"
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

        // ⑤-1 적금 목적을 고른 뒤 — 목적에 맞춰 기간·금액을 잡는다.
        if let purpose = SavingsPurpose.allCases.first(where: { q.contains($0.matchKey) }) {
            let monthly = model.suggestedSavingsAmount
            return ChatMessage(
                role: .agent,
                conclusion: "\(purpose.label)이면 \(purpose.termLabel)로 잡는 게 맞아요. 월 \(formatWon(monthly)) 정도가 지금 여력이에요.",
                reason: purpose.reason,
                impact: "이번 달 남은 예산 \(formatWon(model.remainingBudget)) · \(b.nextPayLabel) 할부 \(formatWon(b.carryover))을 빼고 잡은 금액이에요",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 저축 목표 \(formatWon(model.savingsGoal)) · 카드 할부 잔여 \(formatWon(b.carryover))",
                actions: .openProducts
            )
        }

        // ⑤ 적금 — 여력이 없으면 없다고 말한다. 금융 앱이 무리한 저축을 권하면 안 된다.
        if q.contains("적금") || q.contains("통장") || q.contains("저축") && q.contains("만들") {
            let remaining = BudgetEngine.remainingBudget(income: model.monthlyIncome,
                                                         savingsGoal: model.savingsGoal)
            let roomy = model.probability >= AppModel.atRiskProbability && remaining > b.carryover
            return ChatMessage(
                role: .agent,
                conclusion: roomy
                    ? "지금 계획이면 적금을 하나 더 만들 여지가 있어요."
                    : "지금 새로 시작하기엔 빠듯해요. 상품을 미리 봐두고, 시작 시점만 뒤로 잡는 걸 추천해요.",
                reason: "이번 달 남은 예산이 \(formatWon(remaining))이고 목표 확률은 \(model.probability)%예요."
                    + (roomy ? "" : " 이미 넣고 있는 \(formatWon(model.savingsGoal))부터 지키는 게 먼저예요."),
                impact: "\(b.nextPayLabel)에 카드 할부 \(formatWon(b.carryover))이 빠지니, 그게 끝난 뒤가 여유로워요",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 저축 목표 \(formatWon(model.savingsGoal)) · 카드 할부 잔여 \(formatWon(b.carryover))",
                // 목적을 모르면 어떤 상품이 맞는지 고를 수 없다. 추측하지 말고 되묻는다.
                actions: .choices(SavingsPurpose.allCases.map(\.label))
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
                impact: "출근 22일 × 0원 · 예상 지출 합계에 영향 없음",
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
                impact: "이번 주 예상 지출 \(rangeText(low: model.plannedSpendLow, high: model.plannedSpendHigh))",
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
                reason: "7월 예상 지출과 확인된 고정비를 먼저 반영했어요.",
                impact: "이번 주 추가 사용 가능액 \(formatWon(model.weeklyBudget))",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 7월 캘린더 · 저축 목표"
            )
        }

        if q.contains("이번주") || q.contains("얼마") || q.contains("더써") || q.contains("더쓸") || q.contains("괜찮") {
            return ChatMessage(
                role: .agent,
                conclusion: "이번 주에는 \(formatWon(model.weeklyBudget))을 더 써도 돼요.",
                reason: remainingWeekReason,
                impact: "이번 주 예상 지출 \(rangeText(low: model.plannedSpendLow, high: model.plannedSpendHigh)) 예상",
                basis: "월수입 \(formatWon(model.monthlyIncome)) · 저축 \(formatWon(model.savingsGoal)) · 확인된 일정 금액 기준"
            )
        }

        return ChatMessage(
            role: .agent,
            conclusion: "그 질문은 지금 소비 계획만으로는 정확히 답하기 어려워요.",
            reason: "사려는 것의 금액이나 바꾸고 싶은 일정 이름을 한 가지만 더 알려주실래요? 자연스럽게 이어서 말해도 괜찮아요.",
            impact: "현재 추가 사용 가능액 \(formatWon(model.weeklyBudget))",
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
