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
        /// 제안 당시의 초안을 메시지에 고정한다. 이후 다른 제안이 생겨도 과거 버튼이
        /// 전역 pending 값을 잘못 추가하지 않는다.
        case addEvent(EventPhrase.Draft)
        case setDirection(SpendDirection)   // 다음 달 소비 방향을 저장
        case openProducts                   // 카드·적금 탭으로 이동
        case moveEvent(day: Int, eventID: UUID, title: String, amount: Int)
        /// 되묻기 — 모르는 걸 추측해서 답하지 않고 사용자가 고르게 한다.
        /// 고른 답이 다시 질문으로 들어가 대화가 이어진다.
        case choices([String])
        /// 앱 데이터로는 답할 수 없는 질문. 누르면 그때 질문 원문이 검색으로 나간다.
        case searchWeb(String)
        /// 대화 에이전트가 제안한 계획 변경. 누를 때까지 아무것도 바뀌지 않는다 —
        /// 모델이 혼자 일정을 넣거나 지우는 일은 없다.
        case planChanges([AgentAction])
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

/// 검색 동의 시트에 실어 보낼 질문. `sheet(item:)`이 Identifiable을 요구해서 한 겹 감싼다.
private struct SearchPrompt: Identifiable {
    let id = UUID()
    let query: String
}

/// 모델이 보내온 자유 문장을 읽기 좋게 그린다.
///
/// 통짜로 한 덩어리를 그리면 결론과 근거가 같은 무게로 붙어 벽이 된다.
/// 빈 줄을 기준으로 문단을 나누고, 첫 문단(결론)만 굵게 세운다.
/// 금액·비율은 굵게 살린다 — 문장 안에 숫자가 묻히면 판단할 근거가 안 보인다.
struct StreamedAnswer: View {
    let text: String

    private var paragraphs: [String] {
        let raw = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard raw.count > 4 else { return raw }
        return Array(raw.prefix(3)) + [raw.dropFirst(3).joined(separator: " ")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { i, para in
                if i == 0 {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(KB.yellow)
                            .frame(width: 4)
                        Text(Self.highlightNumbers(para))
                            .font(.kb(15, .semibold))
                            .foregroundStyle(KB.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(KB.yellowSoft,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text(Self.highlightNumbers(para))
                        .font(.kb(13.5))
                        .foregroundStyle(KB.ink.opacity(0.86))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                attr[ar].foregroundColor = KB.green
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
    @StateObject private var speech = SpeechService()
    @StateObject private var calendar = CalendarStore()

    /// 대화로 제안 중인 일정. "추가해줘"나 금액 수정이 이걸 가리킨다.
    @State private var pending: EventPhrase.Draft?
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isThinking = false
    @State private var thinkingStep = 0
    @State private var toast: String?
    @State private var showConsent = false
    /// 검색 동의를 아직 안 받았을 때 띄우는 시트. 검색이 필요한 질문이 나온 순간에만 뜬다.
    @State private var pendingSearchQuery: SearchPrompt?
    /// 지금 이 순간 질문 원문이 검색으로 나가는 중인지. 배지가 이걸 보고 바뀐다.
    @State private var searchingNow = false
    /// 마지막 에이전트 턴에서 매긴 일정 번호표. 버튼을 누를 때 번호로 일정을 되찾는다.
    @State private var agentIndex = AgentEventIndex(model: AppModel())
    /// 입력줄의 검색 스위치. 켜 두면 보내는 말이 예산 계산이 아니라 웹 검색으로 간다.
    /// 언제 원문이 나가는지를 앱이 눈치로 정하지 않고 사용자가 직접 정하게 하는 자리다.
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
                            // 마지막 실행 카드 아래에 실제 여유 공간을 둔다. 키보드·입력창 높이가
                            // 달라도 버튼이 가려지지 않고 scrollTo의 기준 프레임에도 포함된다.
                            bubble(msg)
                                .padding(.bottom, msg.id == messages.last?.id ? 56 : 0)
                                .id(msg.id)
                        }
                        if isThinking { typingBubble.id("typing") }
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }
                .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: messages.last?.id) { _, messageID in
                    guard let messageID else { return }
                    Task { @MainActor in
                        // 실행 카드가 실제 높이를 얻은 뒤 그 카드 자체를 기준으로 맞춘다.
                        try? await Task.sleep(for: .milliseconds(120))
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(messageID, anchor: .bottom)
                        }
                    }
                }
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
        .onChange(of: speech.isRecording) { wasRecording, isRecording in
            if wasRecording, !isRecording { adoptSpeechTranscript() }
        }
        .onDisappear { speech.stop() }
        .task {
            await agent.ping()
            // 외부 모델뿐 아니라 원격 백엔드도 재무 집계값이 기기를 떠나는 경계다.
            showConsent = agent.requiresOffDeviceConsent && !AIConsent.asked
        }
        .sheet(isPresented: $showConsent) { consentSheet }
        .sheet(item: $pendingSearchQuery) { searchConsentSheet($0) }
    }

    // MARK: 검색 동의

    /// 검색이 필요한 질문이 나온 그 순간에만 묻는다. 앱을 처음 켤 때 미리 받아두지 않는다 —
    /// 무엇이 나가는지 사용자가 눈앞의 질문으로 확인할 수 있을 때 물어야 판단이 된다.
    private func searchConsentSheet(_ prompt: SearchPrompt) -> some View {
        let query = prompt.query.trimmingCharacters(in: .whitespaces)
        return SheetContainer(title: "검색해서 알아볼까요?") {
            VStack(alignment: .leading, spacing: 16) {
                Text(false
                     ? "켜 두는 동안 보내는 말이 그대로 검색에 나가요. 예산 계산은 하지 않아요."
                     : "이 질문 한 줄이 그대로 검색에 나가요.")
                    .font(.kb(14)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !query.isEmpty {
                    Text("“\(query)”")
                        .font(.kb(14, .semibold)).foregroundStyle(KB.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KB.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(KB.line, lineWidth: 1))
                }

                consentRow(icon: "magnifyingglass", tint: KB.caution, title: "나가는 것",
                           detail: "위 질문 문장 하나예요.")
                consentRow(icon: "lock", tint: KB.green, title: "나가지 않는 것",
                           detail: "일정 제목, 금액, 예산, 카드 내역, 이름은 검색으로 보내지 않아요.")

                Text("검색하는 동안에는 위쪽 배지가 ‘검색 사용 중’으로 바뀌어요. 설정에서 언제든 끌 수 있어요.")
                    .font(.kb(11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 9) {
                    consentButton("검색할게요", filled: true) {
                        ConsentStore.set(.overseas, true)
                        pendingSearchQuery = nil
                        Task { await runSearch(query) }
                    }
                    consentButton("안 할래요", filled: false) {
                        ConsentStore.set(.overseas, false)
                        pendingSearchQuery = nil
                    }
                }
            }
        }
    }

    /// 질문 원문을 검색에 보내고 결과를 답변으로 붙인다.
    /// 이 함수가 도는 동안에만 배지가 '검색 사용 중'이 된다.
    @MainActor
    /// 계획 에이전트 한 턴. 답변과 '실행할 동작'을 함께 받아 버튼으로 보여준다.
    ///
    /// 동작은 여기서 실행하지 않는다 — 사용자가 버튼을 눌러야 계획이 바뀐다.
    /// 검색이 실제로 일어났으면 나간 검색어를 그대로 화면에 적는다. 무엇이 나갔는지
    /// 사용자가 나중에라도 확인할 수 있어야 한다.
    private func runAgent(_ message: String, history: [AgentChatTurn]) async {
        defer { isThinking = false }

        // 이 턴에 쓸 번호표. 답이 돌아온 뒤 버튼을 누를 때 같은 표로 되찾는다.
        let index = AgentEventIndex(model: model)
        agentIndex = index

        guard let result = await agent.agentTurn(message, model: model,
                                                 maySearch: AIConsent.granted,
                                                 events: index.refs,
                                                 history: history) else {
            messages.append(ChatMessage(
                role: .agent,
                conclusion: "지금은 서버에 닿지 않아요. 잠시 뒤에 다시 말씀해 주세요."))
            return
        }

        var reply = ChatMessage(role: .agent, conclusion: result.reply, isStream: true)
        if !result.actions.isEmpty {
            reply.actions = .planChanges(result.actions)
        }
        if let query = result.searchedQuery {
            reply.basis = "웹에 보낸 검색어: ‘\(query)’"
                + (result.sources.isEmpty ? "" : "\n출처: " + result.sources.joined(separator: "\n"))
        }
        messages.append(reply)
    }

    private func runSearch(_ query: String) async {
        searchingNow = true
        isThinking = true
        defer {
            searchingNow = false
            isThinking = false
        }
        let answer = await agent.search(query)
        messages.append(answer ?? ChatMessage(
            role: .agent,
            conclusion: "검색이 지금은 안 돼요.",
            reason: "검색을 담당하는 서버에 닿지 못했어요. 잠시 뒤에 다시 물어봐 주세요.",
            basis: "검색 요청 실패"
        ))
    }

    // MARK: 외부 AI 동의

    private var consentSheet: some View {
        SheetContainer(title: "AI 분석 방식을 골라주세요") {
            VStack(alignment: .leading, spacing: 16) {
                Text("외부 AI를 쓰지 않아도 예산 계산과 일정 추가는 기기 안에서 그대로 동작해요.")
                    .font(.kb(14)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)

                consentRow(icon: "iphone", tint: KB.green, title: "기기 안에서만",
                           detail: "과거 소비 패턴과 예산 엔진으로 답해요. 외부 AI로 금융 문맥을 보내지 않아요.")
                consentRow(icon: "person.crop.circle.badge.checkmark", tint: KB.green,
                           title: "식별정보 없이 분석",
                           detail: "질문 원문·실명·일정 제목은 보내지 않아요. 답변에 필요한 날짜·유형·금액과 재무 집계값만 외부 AI에 보내요.")

                Text("선택은 설정에서 언제든 바꿀 수 있어요. 아무것도 고르지 않고 닫으면 ‘기기 안에서만’으로 저장돼요.")
                    .font(.kb(11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 9) {
                    consentButton("기기 안에서만", filled: true) {
                        chooseConsent(cloud: false)
                    }
                    consentButton("식별정보 없이 분석", filled: false) {
                        chooseConsent(cloud: true)
                    }
                }
            }
        }
        // X로 닫거나 쓸어내리면 외부 전송에 동의하지 않은 것으로 본다.
        .onDisappear {
            if !AIConsent.asked { chooseConsent(cloud: false) }
        }
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
                .foregroundStyle(filled ? KB.onYellow : KB.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(filled ? KB.yellow : KB.surface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(filled ? .clear : KB.line, lineWidth: 1))
        }
    }

    private func chooseConsent(cloud: Bool) {
        // 국외 이전 동의와 같은 값이다. 여기서 AIConsent 를 직접 쓰면 동의 기록이 안 남는다.
        ConsentStore.set(.overseas, cloud)
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
                    Label(privacyBadgeLabel,
                          systemImage: "lock.fill")
                        .font(.kb(9.5, .medium))
                        .foregroundStyle(KB.green)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(KB.surface.opacity(0.75), in: Capsule())
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
                .background(KB.surface.opacity(0.8), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(KB.yellowSoft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tune 계획 도우미. \(privacyBadgeLabel). 이번 주 추가 사용 가능액 \(formatWon(model.weeklyBudget))")
    }

    /// 지금 이 대화에서 무엇이 기기 밖으로 나가는지 한 줄로 알린다.
    /// 검색은 질문 원문이 그대로 나가므로 가장 강한 표기가 되어야 한다.
    private var privacyBadgeLabel: String {
        if searchingNow { return "검색 사용 중" }
        guard AIConsent.granted else { return "기기 안에서만" }
        return "직접식별자·원문 비공개"
    }

    // MARK: 말풍선

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(msg.conclusion)
                    .font(.kb(14)).foregroundStyle(KB.onYellow)
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

            actionButtons(for: msg)
        }
        .padding(14)
        .background(KB.surface, in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 16,
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
            Text(title).font(.kb(12.5, .semibold)).foregroundStyle(filled ? KB.onYellow : KB.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(filled ? KB.yellow : .clear, in: Capsule())
                .overlay(Capsule().stroke(filled ? .clear : KB.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionButtons(for message: ChatMessage) -> some View {
        switch message.actions {
        case .addEvent(let draft):
            HStack(spacing: 8) {
                smallAction("일정 추가", filled: true) {
                    messages.append(confirm(draft))
                    consumeAction(message.id)
                }
                smallAction("금액 변경", filled: false) {
                    pending = draft
                    input = "\(draft.title) 예산을 "
                    inputFocused = true
                }
                smallAction("안 넣을래요", filled: false) {
                    if pending == draft { pending = nil }
                    consumeAction(message.id)
                    flash("이번엔 넣지 않을게요.")
                }
            }
            .padding(.top, 2)

        case .setDirection(let dir):
            HStack(spacing: 8) {
                smallAction("\(dir.label)로 정하기", filled: true) {
                    withAnimation(.snappy(duration: 0.25)) { model.direction = dir }
                    consumeAction(message.id)
                    flash("다음 달 소비 방향을 ‘\(dir.label)’로 저장했어요. 설정에서 언제든 바꿀 수 있어요.")
                }
                smallAction("지금은 유지", filled: false) {
                    consumeAction(message.id)
                    flash("방향은 그대로 둘게요.")
                }
            }
            .padding(.top, 2)

        case .choices(let options):
            // 고르면 그 답이 그대로 다음 질문이 된다 — 타이핑 없이 대화가 이어진다.
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    smallAction(option, filled: false) {
                        consumeAction(message.id)
                        send(option)
                    }
                }
            }
            .padding(.top, 4)

        case .searchWeb(let query):
            // 검색은 사용자가 이 버튼을 누를 때만 시작한다. 누르기 전까지 원문은 기기 밖으로
            // 나가지 않는다. 동의를 아직 안 받았으면 여기서 시트가 먼저 뜬다.
            HStack(spacing: 8) {
                smallAction("검색해서 알아보기", filled: true) {
                    consumeAction(message.id)
                    if AIConsent.granted {
                        Task { await runSearch(query) }
                    } else {
                        pendingSearchQuery = SearchPrompt(query: query)
                    }
                }
                smallAction("괜찮아요", filled: false) {
                    consumeAction(message.id)
                }
            }
            .padding(.top, 2)

        case .planChanges(let actions):
            // 모델이 제안한 계획 변경. 누르는 순간에만 실제로 바뀐다.
            FlowLayout(spacing: 8) {
                ForEach(actions) { action in
                    smallAction(action.label, filled: action.kind == .addEvent) {
                        consumeAction(message.id)
                        let outcome = AgentActionRunner.run(action, on: model,
                                                            index: agentIndex)
                        flash(outcome.message)
                    }
                }
                smallAction("그냥 둘래요", filled: false) {
                    consumeAction(message.id)
                }
            }
            .padding(.top, 4)

        case .openProducts:
            HStack(spacing: 8) {
                // 카드 질문에도 쓰이는 버튼이라 상품을 특정하지 않는다.
                smallAction("카드·적금 보러 가기", filled: true) {
                    model.wantsSavings = true    // 넘어간 화면이 적금 쪽을 열어둔다
                    consumeAction(message.id)
                    withAnimation(.easeInOut(duration: 0.3)) { model.selectedTab = .products }
                }
                smallAction("나중에", filled: false) {
                    consumeAction(message.id)
                    flash("필요할 때 다시 물어봐 주세요.")
                }
            }
            .padding(.top, 2)

        case .moveEvent(let day, let eventID, let title, let amount):
            HStack(spacing: 8) {
                smallAction("다음 주로 옮기기", filled: true) {
                    guard let event = model.day(number: day)?.events.first(where: { $0.id == eventID }) else {
                        flash("일정을 다시 확인해 주세요.")
                        return
                    }
                    let calendarID = event.calendarEventID
                    let startHour = event.startHour
                    guard let target = model.moveEventToNextWeek(event, from: day) else {
                        flash("다음 주로 옮길 수 없는 일정이에요.")
                        return
                    }
                    let calendarSynced = calendarID.map {
                        calendar.reschedule(eventID: $0, day: target, startHour: startHour)
                    } ?? true
                    consumeAction(message.id)
                    flash(calendarSynced
                          ? "‘\(title)’을 다음 주로 옮겼어요. 이번 주에 \(formatWon(amount)) 여유가 생겼어요."
                          : "앱 계획은 옮겼지만 기기 캘린더는 바꾸지 못했어요.")
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
                            .background(KB.surface, in: Capsule())
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
        VStack(spacing: 6) {
            if speech.isRecording || speech.error != nil {
                micStatus
            }
            inputRow
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }

    /// 녹음 중일 때만 뜨는 줄. 어디서 처리되는지(기기/서버)를 같이 밝힌다.
    private var micStatus: some View {
        HStack(spacing: 6) {
            if let err = speech.error {
                Image(systemName: "exclamationmark.circle").font(.kb(11))
                Text(err).font(.kb(11.5))
            } else {
                Image(systemName: "waveform").font(.kb(11))
                Text(speech.transcript.isEmpty ? "듣고 있어요" : speech.transcript)
                    .font(.kb(11.5)).lineLimit(1)
                Spacer()
                Text("기기에서 인식")
                    .font(.kb(10.5))
            }
        }
        .foregroundStyle(speech.error != nil ? KB.ink : KB.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {

            TextField("편하게 말해 주세요", text: $input)
                .font(.kb(14))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(KB.surface, in: Capsule())
                .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit { send(input) }
                .focused($inputFocused)
                .disabled(isThinking)

            // 말로 넣기. 누르면 듣기 시작하고 다시 누르면 멈춘다.
            // 알아들은 문장은 입력창에 들어가므로, 보내기 전에 고칠 수 있다.
            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                    .font(.kb(16, .bold))
                    .foregroundStyle(speech.isRecording ? .white : KB.ink)
                    .frame(width: 44, height: 44)
                    .background(speech.isRecording ? KB.green : KB.yellowSoft, in: Circle())
            }
            .disabled(isThinking)
            .accessibilityLabel(speech.isRecording ? "녹음 멈추기" : "말로 입력하기")

            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.kb(17, .bold)).foregroundStyle(KB.onYellow)
                    .frame(width: 44, height: 44)
                    .background(KB.yellow, in: Circle())
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .accessibilityLabel("질문 보내기")
        }
    }


    /// 녹음 시작/정지. 멈출 때 알아들은 문장을 입력창으로 옮긴다.
    private func toggleRecording() async {
        if speech.isRecording {
            speech.stop()
            adoptSpeechTranscript()
        } else {
            await speech.start()
        }
    }

    /// 사용자가 버튼을 다시 누르지 않아도 인식기가 자동으로 끝낸 최종 문장을 입력창에 둔다.
    private func adoptSpeechTranscript() {
        let text = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = text
        inputFocused = true
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
        let history = recentAgentHistory()
        input = ""
        inputFocused = false
        thinkingStep = 0

        // 계획 에이전트를 켰으면 여기로 다 보낸다. 일정 추가·수정·삭제·가격 조회·웹 검색을
        // 한 경로에서 처리하므로, 예전처럼 모드를 골라 가며 쓰지 않아도 된다.
        // 검색은 에이전트가 필요하다고 판단할 때만 일어나고, 그 전에 서버의 검증기가
        // 검색어를 검사한다.
        if AIConsent.granted {
            withAnimation(.easeOut(duration: 0.25)) { isThinking = true }
            Task { await runAgent(trimmed, history: history) }
            return
        }

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

            // 앱이 아는 질문은 앱이 답한다. 인사·적금 목적·일정 미루기처럼 정해진 답이 있는 건
            // 앱 쪽이 정확한 금액과 실행 버튼, 되묻기까지 함께 주기 때문이다.
            // 예전에는 백엔드가 켜지면 전부 LLM 으로 넘겨서 "안녕"에도 맥락 없는 답이 돌아왔다.
            // 앱이 직접 맡아야 하는 건 둘뿐이다.
            //   · 일정 잡기 — 실제로 계획과 캘린더를 바꾸는 동작이라 모델에 맡길 수 없다.
            //   · 인사 — 서버가 안 되더라도 즉답해야 한다.
            // 나머지는 전부 LLM 이 답한다. 앱이 가진 숫자(주간 가능액·카드 청구·일정)가
            // 요청에 함께 실려 나가므로, 소비 질문도 내 데이터를 근거로 답한다.
            // 규칙 답변을 앞세우면 "추천해줄래"의 '줄' 같은 글자에 걸려 엉뚱한 답이 나간다.
            // 상품 추천은 앱이 답한다. 규칙이 좋아서가 아니라 상품 목록과 혜택 계산이
            // 앱에만 있기 때문이다 — LLM 은 어떤 카드·적금이 있는지 모르니 일반론밖에 못 한다.
            let scripted = eventTurn(trimmed) ?? greetingReply(trimmed) ?? productReply(trimmed)

            // 켠 직후 헬스체크가 늦어 실패했을 뿐 서버는 멀쩡한 경우가 많다. 한 번 더 확인한다.
            if scripted == nil, !agent.llmEnabled { await agent.ping() }

            var streamed = ""
            var ok = false
            if scripted == nil, agent.llmEnabled {
                ok = await agent.chatStream(trimmed, history: history, model: model) { delta in
                    streamed += delta
                }
            }

            _ = await minimumDelay.result
            stageUpdates.cancel()
            withAnimation(.easeOut(duration: 0.25)) { isThinking = false }

            if let scripted {
                messages.append(scripted)
            } else if ok, !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            // 실행 버튼이 붙는 답변은 메시지 추가와 칩 제거가 같은 렌더링 주기에 일어난다.
            // 한 번의 yield만으로는 이전 높이를 잡아 버튼이 입력창 뒤에 남을 수 있어,
            // 레이아웃이 확정된 다음 프레임에 스크롤한다.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.25)) {
                if isThinking { proxy.scrollTo("typing", anchor: .bottom) }
                // LazyVStack의 투명 1pt 앵커는 최적화되며 scrollTo가 무시될 수 있다.
                // 실제 마지막 말풍선을 기준으로 맞춰 실행 버튼까지 입력창 위에 올린다.
                else if let lastMessageID = messages.last?.id {
                    proxy.scrollTo(lastMessageID, anchor: .bottom)
                } else {
                    proxy.scrollTo("chat-end", anchor: .bottom)
                }
            }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut) { toast = nil }
        }
    }

    /// 실행이 끝난 메시지의 버튼을 없애 중복 추가·중복 이동을 막는다.
    private func consumeAction(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].actions = nil
    }

    /// 현재 질문 직전의 짧은 문맥만 보낸다. 일정 미리보기와 실행 버튼이 붙은 메시지는
    /// 원문 제목이나 동작 상태를 포함할 수 있어 제외한다. 실제 전송 시 사용자 발화는
    /// AgentService가 자유문장 대신 구조화된 금융 의도로 바꾼다.
    private func recentAgentHistory() -> [AgentChatTurn] {
        messages.dropLast()
            .filter { $0.preview == nil && $0.actions == nil }
            .suffix(6)
            .map { message in
                let role = message.role == .user ? "user" : "assistant"
                let content = [message.conclusion, message.reason]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                return AgentChatTurn(role: role, content: content)
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
        // 인사는 넓게 받는다. 서버가 잠깐 안 되더라도 인사에 답을 못 하면 안 된다.
        if Self.greetings.contains(where: { q.contains($0) }) {
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
        //
        // 안 되는 상황에서는 결론을 흐리지 않는다. "흔들려요"처럼 여지를 두면 사도 된다는
        // 뜻으로 읽힌다. 안 된다고 먼저 말하고, 얼마가 모자라고 무엇이 깨지는지 숫자로 보여준
        // 다음에 대안을 준다. 다만 사람을 평가하지는 않는다 — 판단은 돈에 대해서만 한다.
        if q.contains("사도") || q.contains("살까") || q.contains("바지") || q.contains("구매") || q.contains("지를") {
            let over = max(0, upcomingTotal - model.remainingBudget)
            // 얼마짜리인지 말했으면 그 금액으로 따진다. 안 말했으면 초과액을 지어내지 않고
            // 예산 상태만 말한다 — 물건값을 모르는데 "N원 모자라요"라고 하면 틀린 숫자가 된다.
            let price = EventPhrase.amount(in: text)
            let exceeds = price.map { $0 > model.weeklyBudget } ?? false
            let tight = exceeds || over > 0 || model.weeklyBudget == 0

            let verdict: String
            if let price, exceeds {
                verdict = "지금은 안 돼요. 이번 주에 더 쓸 수 있는 돈이 \(formatWon(model.weeklyBudget))인데, \(formatWon(price))을 쓰면 \(formatWon(price - model.weeklyBudget))을 넘겨요."
            } else if over > 0 {
                verdict = "지금은 안 돼요. 이미 잡힌 일정이 이번 달 남은 예산을 \(formatWon(over)) 넘어서 있어요."
            } else if model.weeklyBudget == 0 {
                verdict = "지금은 안 돼요. 이번 주에 더 쓸 수 있는 돈이 0원이에요."
            } else if let price {
                verdict = "\(formatWon(price))이면 이번 주 여유 \(formatWon(model.weeklyBudget)) 안에서 가능해요. 다만 \(b.payLabel) 카드 청구액도 같이 보고 정하는 게 좋아요."
            } else {
                verdict = "이번 주 여유 안에서는 가능해요. 다만 다음 달 카드 청구액도 같이 보고 정하는 게 좋아요."
            }

            return ChatMessage(
                role: .agent,
                conclusion: verdict,
                reason: tight
                    ? (upcomingEvents.isEmpty
                        ? "이번 주 예산이 이미 다 찼어요. 여기서 더 쓰면 \(b.payLabel) 카드 청구액 \(formatWon(b.dueNext))을 그대로 떠안게 돼요."
                        : "앞으로 \(upcomingSummary)이 잡혀 있어요. 이건 이미 약속한 돈이라, 새로 사는 건 이 약속들을 깨야 가능해요.")
                    : (upcomingEvents.isEmpty
                        ? "이번 주 남은 확정 일정은 없어요."
                        : "앞으로 \(upcomingSummary)이 잡혀 있어서 남은 예산 \(formatWon(model.remainingBudget))에서 \(formatWon(upcomingTotal))이 이미 예약된 상태예요."),
                impact: tight
                    ? "그래도 사려면 위 약속 중 하나를 다음 달로 옮겨야 해요. 적금 목표 확률은 지금 \(model.probability)%예요."
                    : "이번 주 추가 사용 가능액 \(formatWon(model.weeklyBudget)) · \(b.payLabel) 카드 청구액 \(formatWon(b.dueNext))에 얹혀요",
                basis: "7월 캘린더 · KB ALL 카드 이용내역 \(b.count)건 \(formatWon(b.usage)) · 할부 이월 \(formatWon(b.carryover))"
            )
        }

        // ①-b 연체·미납 — 유일하게 대안을 나중에 두는 자리다.
        //
        // 다른 소비는 선택이지만 연체는 손해가 확정이다. 연체이자가 붙고 신용점수가
        // 떨어지고 카드가 정지된다. 여기서 "대안을 먼저"를 지키면 연체가 선택지 중
        // 하나처럼 보인다. 그래서 안 된다고 먼저 말한다.
        // 이율·점수 같은 구체적 숫자는 앱이 모르므로 말하지 않는다.
        if ["연체", "미납", "안갚", "못갚", "밀려도", "밀리면", "리볼빙", "돌려막"].contains(where: { q.contains($0) }) {
            return ChatMessage(
                role: .agent,
                conclusion: "연체는 안 돼요. 이건 아껴 쓰는 것과 다른 문제예요.",
                reason: "하루만 밀려도 연체이자가 붙고, 기간이 길어지면 신용점수가 떨어져요. 신용점수는 나중에 전세대출이나 카드 발급 조건까지 따라와서, 지금 아낀 돈보다 훨씬 비싸게 돌아와요. 리볼빙이나 돌려막기도 결국 이자를 뒤로 미루는 거라 같은 자리예요.",
                impact: "\(b.payLabel) 카드 청구액이 \(formatWon(b.dueNext))이에요. 이건 먼저 막고, 부족한 만큼은 앞으로의 일정에서 빼는 쪽으로 볼게요.",
                basis: "KB ALL 카드 이용내역 \(b.count)건 \(formatWon(b.usage)) · 할부 이월 \(formatWon(b.carryover))"
            )
        }

        // ② 어디서 줄일까 — 보호 소비는 건드리지 않고 가장 큰 카테고리부터 제안한다.
        //
        // "줄" 한 글자로 잡으면 "추천해줄래"·"알려줄래"까지 걸려서 엉뚱한 답이 나간다.
        // 줄인다는 뜻으로 쓰인 형태만 받는다.
        if ["줄이", "줄일", "줄여", "아껴", "아낄", "절약", "어디서"].contains(where: { q.contains($0) }) {
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

        // 카드 추천 — 실제 상품을 이름으로 답한다. 순위는 RecoEngine 이 정한다.
        if q.contains("카드"),
           ["추천", "고르", "골라", "어떤", "뭐가좋", "만들", "발급"].contains(where: { q.contains($0) }) {
            let reco = RecoEngine.evalCards(model)
            guard let pick = reco.pick else {
                return ChatMessage(
                    role: .agent,
                    conclusion: "지금 소비로는 혜택이 남는 카드가 없어요.",
                    reason: "실적 조건을 채우려고 더 쓰는 건 권하지 않아요.",
                    actions: .openProducts
                )
            }
            let second = reco.alternative
            return ChatMessage(
                role: .agent,
                conclusion: "\(pick.product.name)이 가장 잘 맞아요. 연회비까지 빼면 월 \(formatWon(pick.netMonthly)) 남아요.",
                reason: pick.benefitLines.isEmpty
                    ? pick.fitCopy
                    : pick.benefitLines.prefix(2).map { "\($0.label) \(formatWon($0.amount))" }.joined(separator: " · ")
                      + " 기준이에요.",
                impact: second.map { "다음은 \($0.product.name) 월 \(formatWon($0.netMonthly))이에요" },
                basis: pick.unmet.isEmpty
                    ? "인정 실적 \(formatWon(reco.recognizedSpend)) 기준 · 조건을 모두 채운 계산이에요"
                    : "확인이 필요한 조건: \(pick.unmet.joined(separator: " · "))",
                actions: .openProducts
            )
        }

        // ⑤ 적금 — 여력이 없으면 없다고 말한다. 금융 앱이 무리한 저축을 권하면 안 된다.
        //
        // '만들다'가 함께 나올 때만 이 답을 낸다. 예전 조건은 || 가 먼저 묶여서
        // "적금" 한 단어만 있어도 걸렸고, 이자를 묻는 질문에도 개설 안내가 나갔다.
        if ["적금", "통장", "저축"].contains(where: { q.contains($0) }),
           ["만들", "가입", "시작", "하나더", "들까", "들래"].contains(where: { q.contains($0) }) {
            let remaining = model.remainingBudget
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
            let draft = EventPhrase.Draft(
                day: DemoClock.serial(month: 8, day: 2), title: "200일 데이트",
                category: "데이트", amount: 100_000, low: 70_000, high: 150_000,
                basis: "과거 기념일 지출과 식사·카페·이동 범위를 함께 봤어요.",
                amountWasSpoken: false
            )
            pending = draft
            return ChatMessage(
                role: .agent,
                conclusion: "8월 2일 200일 데이트 비용으로 100,000원을 8월 계획 예산에 예약할까요? 실제 출금은 없어요.",
                reason: "아직 금액이 없어서 식사·카페·이동을 포함한 예산으로 잡았어요.",
                impact: "7월 계산에는 넣지 않고, 8월 예산에서 따로 확보",
                basis: "8월 2일 캘린더의 ‘200일’·‘데이트’ 일정",
                preview: EventPreview(title: "200일 데이트", amount: 100_000, day: "8월 2일 일요일"),
                actions: .addEvent(draft)
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

        // 앱이 가진 데이터로 답이 안 되는 질문. 모른다고 말하되 그냥 끝내지 않고,
        // 원하면 검색해서 알아보겠다고 제안한다. 누르기 전에는 아무것도 나가지 않는다.
        return ChatMessage(
            role: .agent,
            conclusion: Self.unknownConclusion,
            reason: "저는 성제님의 일정과 소비만 보고 있어서, 그 밖의 건 알지 못해요. 원하시면 검색해서 알아볼게요. 그때는 이 질문 한 줄이 그대로 검색에 나가요.",
            impact: "현재 추가 사용 가능액 \(formatWon(model.weeklyBudget))",
            basis: "2026년 7월 캘린더 · 입력한 월수입과 저축 목표",
            actions: .searchWeb(text)
        )
    }

    // MARK: 대화로 일정 잡기

    /// 일정 이야기면 답을 만들고, 아니면 nil.
    ///
    /// 세 갈래다 — 새 일정 제안 / 제안 중인 금액 수정 / 넣어달라는 확정.
    private func eventTurn(_ text: String) -> ChatMessage? {
        let q = text.replacingOccurrences(of: " ", with: "")

        // 날짜와 할 일이 같이 있으면 새 제안으로 본다.
        if let draft = EventPhrase.parse(text) {
            pending = draft
            return proposal(for: draft)
        }

        // 할 일은 말했지만 날짜가 빠졌다면 LLM으로 원문을 보내지 않고 기기에서 되묻는다.
        // 고른 문구에는 활동 이름도 함께 넣어 다음 턴에서 바로 완성된 Draft가 된다.
        let eventIntent = ["잡", "추가", "등록", "가려고", "갈거", "갈까", "약속", "예정", "하려"]
            .contains { q.contains($0) }
        if EventPhrase.day(in: text) == nil, eventIntent,
           let title = EventPhrase.recognizedTitle(in: text) {
            return ChatMessage(
                role: .agent,
                conclusion: "\(title) 일정은 언제로 잡을까요?",
                reason: "날짜를 고르면 과거 소비 기록으로 금액을 먼저 예상하고, 추가 전 영향을 보여드릴게요.",
                actions: .choices(["내일 \(title)", "이번 주말 \(title)", "다음 주 토요일 \(title)"])
            )
        }
        guard var draft = pending else { return nil }

        // 제안이 떠 있는 상태에서 금액만 말하면 그 금액으로 다시 계산한다.
        if EventPhrase.day(in: text) == nil, let spoken = EventPhrase.amount(in: text) {
            draft.amount = spoken
            draft.low = spoken
            draft.high = spoken
            draft.basis = "말씀하신 금액으로 다시 계산했어요."
            draft.amountWasSpoken = true
            pending = draft
            return proposal(for: draft)
        }
        // "추가해줘" — 확정.
        if q.contains("추가") || q.contains("넣어") || q.contains("잡아줘") || q.contains("등록") {
            return confirm(draft)
        }
        return nil
    }

    /// 넣기 전 판단. 되는지 안 되는지와 그 영향까지 같이 보여준다.
    private func proposal(for d: EventPhrase.Draft) -> ChatMessage {
        let before = model.weeklyBudget(for: model.direction, on: d.day)
        let after = model.weeklyBudget(for: model.direction,
                                       extraCommitted: d.amount, on: d.day)
        let probBefore = model.probability(for: model.direction, on: d.day)
        let probAfter = model.probability(for: model.direction,
                                          extraCommitted: d.amount, on: d.day)
        let tight = after == 0 || (probBefore - probAfter) >= 10
        let label = DemoClock.dayLabel(of: d.day)
        let weekLabel = model.currentWeekRange.contains(d.day)
            ? "이번 주"
            : "\(DemoClock.shortLabel(of: d.day))이 든 주"

        return ChatMessage(
            role: .agent,
            conclusion: tight
                ? "\(label) \(d.title), 넣으면 이번 주가 빠듯해져요."
                : "\(label) \(d.title), 넣어도 괜찮아요.",
            reason: d.basis,
            impact: "\(weekLabel) 추가 사용 가능액 \(formatWon(before)) → \(formatWon(after)) · "
                  + "적금 목표 확률 \(probBefore)% → \(probAfter)%",
            basis: d.amountWasSpoken
                ? "말씀하신 금액 기준"
                : "\(d.category) 유형의 과거 금액 기준 · 금액이 다르면 말씀해 주세요",
            preview: EventPreview(title: d.title, amount: d.amount, day: label),
            actions: .addEvent(d)
        )
    }

    /// 계획과 기기 캘린더에 실제로 넣는다.
    private func confirm(_ d: EventPhrase.Draft) -> ChatMessage {
        // 시간을 안 말했으니 저녁 7시로 잡는다. 하루 화면에서 언제든 옮길 수 있다.
        let calendarID = calendar.save(title: d.title, day: d.day, startHour: 19, duration: 2)
        model.addEvent(title: d.title, day: d.day, amount: d.amount,
                       category: d.category, basis: d.basis, startHour: 19,
                       calendarEventID: calendarID)
        if pending == d { pending = nil }

        let label = DemoClock.dayLabel(of: d.day)
        let weekLabel = model.currentWeekRange.contains(d.day)
            ? "이번 주"
            : "\(DemoClock.shortLabel(of: d.day))이 든 주"
        return ChatMessage(
            role: .agent,
            conclusion: "\(label) \(d.title) \(formatWon(d.amount))을 계획에 넣었어요.",
            reason: calendarID != nil
                ? "기기 캘린더에도 저녁 7시로 적어뒀어요."
                : "캘린더 권한이 없어 앱 안에만 넣었어요.",
            impact: "\(weekLabel) 추가 사용 가능액 \(formatWon(model.weeklyBudget(for: model.direction, on: d.day)))",
            basis: "금액이나 시간은 하루 화면에서 바꿀 수 있어요."
        )
    }

    // MARK: 상품 추천 — 앱만 아는 것

    private static let wantsReco = ["추천", "고르", "골라", "어떤", "뭐가좋", "만들", "발급", "가입"]

    /// 카드·적금 추천이면 실제 상품으로 답하고, 아니면 nil.
    private func productReply(_ text: String) -> ChatMessage? {
        let q = text.replacingOccurrences(of: " ", with: "")
        guard Self.wantsReco.contains(where: { q.contains($0) }) else { return nil }
        if q.contains("카드") { return cardReco() }
        if q.contains("적금") || q.contains("저축") || q.contains("통장") { return savingsReco() }
        return nil
    }

    private func cardReco() -> ChatMessage {
        let reco = RecoEngine.evalCards(model)
        guard let pick = reco.pick else {
            return ChatMessage(role: .agent,
                               conclusion: "지금 소비로는 혜택이 남는 카드가 없어요.",
                               reason: "실적을 채우려고 더 쓰는 건 권하지 않아요.",
                               actions: .openProducts)
        }
        return ChatMessage(
            role: .agent,
            conclusion: "\(pick.product.name)이 가장 잘 맞아요. 연회비까지 빼면 월 \(formatWon(pick.netMonthly)) 남아요.",
            reason: pick.benefitLines.isEmpty ? pick.fitCopy
                : pick.benefitLines.prefix(2).map { "\($0.label) \(formatWon($0.amount))" }
                    .joined(separator: " · ") + " 기준이에요.",
            impact: reco.alternative.map { "다음은 \($0.product.name) 월 \(formatWon($0.netMonthly))이에요" },
            basis: pick.unmet.isEmpty
                ? "인정 실적 \(formatWon(reco.recognizedSpend)) 기준"
                : "확인이 필요한 조건: \(pick.unmet.joined(separator: " · "))",
            actions: .openProducts
        )
    }

    private func savingsReco() -> ChatMessage {
        // 판매중이고 조건이 맞는 것만 후보다. 신청기간이 끝난 상품을 권하면 안 된다.
        let candidates = RecoEngine.evalSavings(model)
            .filter { $0.verdict == .pick || $0.verdict == .buffer || $0.verdict == .alternative }
        guard let pick = candidates.first else {
            return ChatMessage(role: .agent,
                               conclusion: "지금 조건에 맞는 적금이 없어요.",
                               reason: "여력이 생기면 다시 봐드릴게요. 무리한 저축은 권하지 않아요.",
                               actions: .openProducts)
        }
        return ChatMessage(
            role: .agent,
            conclusion: "\(pick.product.name)을 추천해요. 연 \(pick.product.rateLabel) 상품이에요.",
            reason: pick.fitCopy,
            impact: pick.estInterest > 0
                ? "월 \(formatWon(pick.monthlyDeposit))씩 \(pick.months)개월이면 이자 \(formatWon(pick.estInterest)) 예상이에요"
                : nil,
            basis: pick.unmet.isEmpty
                ? "우대 조건을 모두 채운 기준이에요"
                : "확인이 필요한 조건: \(pick.unmet.joined(separator: " · "))",
            actions: .openProducts
        )
    }

    /// 인사면 답을 만들고 아니면 nil. 인사 분기가 agentReply 의 첫 갈래라 그대로 나온다.
    private func greetingReply(_ text: String) -> ChatMessage? {
        let q = text.replacingOccurrences(of: " ", with: "")
        guard Self.greetings.contains(where: { q.contains($0) }) else { return nil }
        return agentReply(to: text)
    }

    /// 어느 의도에도 안 걸렸을 때 쓰는 문장. 이 값으로 '앱이 모른다'를 판별한다.
    fileprivate static let unknownConclusion = "그 질문은 지금 소비 계획만으로는 정확히 답하기 어려워요."

    /// 인사로 받아들일 말들. 줄임말과 오타까지 넉넉히 잡는다.
    fileprivate static let greetings = [
        "안녕", "하이", "헬로", "할로", "ㅎㅇ", "반가", "방가", "hi", "hello", "hey", "여보세요",
    ]
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
