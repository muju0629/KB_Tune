//
//  AgentService.swift
//  KB_Tune
//
//  백엔드(FastAPI) 연동. /api/chat 스트리밍 · /api/coach.
//  백엔드가 없거나 실패하면 false를 반환해 호출부가 로컬(BudgetEngine)으로 폴백한다.
//  → 서버·키가 없어도 앱이 항상 동작(심사자 실행 보장).
//

import Foundation
import Combine
import NaturalLanguage

/// AI 기능을 쓸지에 대한 단 하나의 동의.
///
/// 예전에는 스위치가 넷이었다(클라우드 AI·대화로 일정 바꾸기·웹 검색·금액 검색).
/// 나가는 것이 각각 달라 나눴는데, 쓰는 사람은 뭘 켜야 뭐가 되는지 알 수 없었다.
/// 무엇을 지킬지는 사용자가 고를 일이 아니라 코드가 지킬 일이다.
///
/// **켜면 AI 가 다 한다** — 묻고 답하기, 일정 추가·수정·삭제, 기준 금액 조회, 웹 검색.
/// **켜도 개인정보는 안 나간다** — 이건 스위치가 아니라 규칙이고, 코드가 강제한다.
///
///   · 이름·연락처·주소·계좌·저장된 일정 제목 → `OutboundPrivacy.sanitize()` 가 기기에서 가림
///   · 검색 엔진에는 코드가 만든 문장만 → 서버의 `searchguard` 가 검사
///   · 모델 제공자는 학습에 쓰지 않고 30일 뒤 지움
///
/// 끄면 기기 안의 예산·패턴 엔진만 쓴다. 앱은 그래도 다 돌아간다.
///
/// **여기에는 읽기만 있다.** 켜고 끄는 것은 `ConsentStore.set(.overseas,)` 뿐이다 —
/// 이 값은 국외 이전 동의(제28조의8)와 같은 뜻이라, 여기서 따로 쓰면 동의 기록과
/// 실제 전송이 어긋난다. 실제로 그런 적이 있다: 설정에서 철회해도 대화 화면의
/// 동의 시트가 이 값만 되켜서, 기록은 '철회'인데 전송은 이어졌다. 동의 시각도
/// 안 남아 입증이 안 됐다. 진입점을 하나로 묶어 구조적으로 막는다.
nonisolated enum AIConsent {
    // 예전 키를 그대로 쓴다 — 이미 켜 둔 사람이 다시 켜지 않아도 되게.
    static let key = "usesCloudAIAnalysis"

    static var asked: Bool { UserDefaults.standard.object(forKey: key) != nil }
    static var granted: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// 백엔드 SearchCostResult 와 같은 스키마.
struct SearchCostResult: Codable {
    let amount: Int?
    let low: Int?
    let high: Int?
    let basis: String
    let sources: [String]
    let method: String      // web | unavailable
}

/// 서버에 보낼 수 있는 짧은 대화 문맥. 화면 모델이나 실행 버튼은 포함하지 않는다.
struct AgentChatTurn {
    let role: String       // user | assistant
    let content: String
}

/// 네트워크 요청이 만들어지기 직전에 적용하는 개인정보 경계.
///
/// 화면에서 실수로 원문을 넘겨도 이 층에서 사용자의 실명과 구조화 개인정보를 지운다.
/// 일정 제목 원문은 허용하지 않고 카테고리 별칭으로만 바꾼다. 서버의 프롬프트 규칙이나
/// 불완전한 이름 인식에 의존하지 않고 기기에서 먼저 제거한다.
enum OutboundPrivacy {
    static func sanitize(_ source: String, model: AppModel? = nil) -> String {
        var text = source

        if let name = model?.userName.trimmingCharacters(in: .whitespacesAndNewlines),
           name.count >= 2 {
            text = text.replacingOccurrences(of: name, with: "사용자")
        }

        if let model {
            let events = model.calendarDays.flatMap(\.events)
                .filter { !$0.title.isEmpty }
                .sorted { $0.title.count > $1.title.count }
            for event in events {
                let category = safeCategory(event.category)
                text = text.replacingOccurrences(of: event.title,
                                                  with: "[\(category) 일정]")
            }
        }

        text = redactPersonalNames(in: text)

        // 긴 숫자열은 카드·계좌·주민번호일 가능성이 높다. 금액의 쉼표 표기는 남긴다.
        let patterns: [(String, String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[이메일]"),
            (#"(?<!\d)01[016789][ -]?\d{3,4}[ -]?\d{4}(?!\d)"#, "[전화번호]"),
            (#"(?<!\d)\d{6}[ -]?[1-8]\d{6}(?!\d)"#, "[식별번호]"),
            (#"(?<!\d)\d{12,19}(?!\d)"#, "[금융번호]"),
            (#"(?<!\d)(?:\d{4}[- ]){3}\d{4}(?!\d)"#, "[금융번호]"),
            (#"(?<!\d)\d{2,6}-\d{2,6}-\d{2,6}(?!\d)"#, "[금융번호]"),
            (#"(?<![A-Z0-9])[A-Z]{1,2}\d{7,8}(?![A-Z0-9])"#, "[여권번호]"),
            (#"(?:주소(?:는|가|:)?|사는\s*곳(?:은|:)?|거주지(?:는|:)?)[^,.\n]{2,60}"#, "주소 [주소]"),
            (#"(?:제|내|저의)\s*이름(?:은|이)?\s*[가-힣]{2,4}"#, "제 이름은 [사용자]"),
            (#"[가-힣]{2,4}(?:님|씨)(?=[은는이가을를과와,\s])"#, "[사람]"),
            (#"(?<![가-힣])([가-힣]{2,4})\s+(결혼식|생일|돌잔치|장례식|약속|만남)"#, "[사람] $2"),
            (#"(?<![가-힣])([가-힣]{2,4})(와|과|이랑|랑)\s*(?=(?:카페|약속|만나|밥|술|여행|데이트|결혼))"#, "[사람]$2 ")
        ]
        for (pattern, replacement) in patterns {
            text = replacing(pattern, in: text, with: replacement,
                             options: [.caseInsensitive])
        }

        // API 입력 상한보다 여유 있게 작게 유지한다. 잘린 사실은 문맥에 영향을 덜 주도록
        // 문장 끝에서 자르고, 원문은 로그에도 남기지 않는다.
        return String(text.prefix(1_200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 외부 모델에는 자유문장 원문 대신 기기에서 판별한 금융 의도만 보낸다.
    /// 정규식이나 NER가 놓친 제3자 이름이 있어도 원문 자체가 네트워크 본문에 없게 하는
    /// 구조적 방어다. 구매 판단에 필요한 사용자가 말한 금액만 안전한 숫자로 덧붙인다.
    static func financialIntent(_ source: String) -> String {
        let safe = sanitize(source)
        let compact = safe.replacingOccurrences(of: " ", with: "").lowercased()
        let intent: String
        if ["카드값", "청구", "할부", "결제일"].contains(where: compact.contains) {
            intent = "카드 청구액·결제일·할부 부담에 관해 질문했습니다."
        } else if ["적금", "저축", "통장"].contains(where: compact.contains) {
            intent = "저축 목표와 무리 없는 추가 적금에 관해 질문했습니다."
        } else if ["패턴", "소비습관", "분석", "반복"].contains(where: compact.contains) {
            intent = "과거 소비 패턴과 다음 소비 예측을 질문했습니다."
        } else if ["줄이", "줄일", "줄여", "아껴", "절약", "어디서"].contains(where: compact.contains) {
            intent = "지켜야 할 소비를 제외하고 어디서 줄일지 질문했습니다."
        } else if ["다음달", "미래", "예측"].contains(where: compact.contains) {
            intent = "다음 달 소비와 목표 달성 가능성을 질문했습니다."
        } else if ["사도", "살까", "구매", "지를", "써도"].contains(where: compact.contains) {
            intent = "새 지출을 해도 현재 계획을 지킬 수 있는지 질문했습니다."
        } else if ["이번주", "얼마", "가능액", "예산"].contains(where: compact.contains) {
            intent = "이번 주 추가 사용 가능액과 계산 근거를 질문했습니다."
        } else {
            intent = "개인 소비 계획에 관한 조언을 요청했습니다. 원문의 인명·장소·일정 제목은 생략했습니다."
        }
        guard let amount = EventPhrase.amount(in: safe), amount > 0 else { return intent }
        return intent + " 사용자가 말한 검토 금액은 \(amount)원입니다."
    }

    private static func safeCategory(_ category: String) -> String {
        let allowed = category.filter { $0.isLetter || $0 == "·" || $0 == " " }
        return allowed.isEmpty ? "개인" : String(allowed.prefix(12))
    }

    /// NaturalLanguage의 인명 태깅은 기기 안에서 실행된다. 연락처 형식이 아니어도
    /// 문장 속 사람 이름을 찾아 네트워크 요청 전에 별칭으로 바꾼다.
    private static func redactPersonalNames(in source: String) -> String {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = source
        let full = source.startIndex..<source.endIndex
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(in: full, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { ranges.append(range) }
            return true
        }
        var result = source
        for range in ranges.reversed() { result.replaceSubrange(range, with: "[사람]") }
        return result
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String,
                                  options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: replacement
        )
    }
}

@MainActor
final class AgentService: ObservableObject {

    /// 서버 주소는 소스에 박지 않고 Info.plist(빌드 설정에서 주입)에서 읽는다.
    /// 값이 없으면 로컬 개발 서버 — 받아서 바로 실행할 수 있어야 하므로.
    static let baseURL: URL = {
        let local = URL(string: "http://localhost:8000")!
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "KBTuneAPIBaseURL") as? String,
              !raw.isEmpty, let url = URL(string: raw) else { return local }
        // 평문 HTTP는 루프백에만 허용. 원격 주소를 http로 적어두면 이름·월소득·카드 청구액이
        // 그대로 흐르므로, 잘못 설정된 채 배포되는 걸 코드에서 막는다.
        let host = url.host ?? ""
        if url.scheme == "https" || host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return url
        }
        assertionFailure("KBTuneAPIBaseURL 은 https 여야 합니다: \(raw)")
        return local   // 릴리스에서는 로컬로 떨어져 백엔드 미도달 → 앱 내장 엔진으로 폴백된다.
    }()

    /// 백엔드 인증 키. 없으면 헤더를 안 붙인다(무인증 서버와 그대로 호환).
    /// 앱 바이너리에서 추출될 수 있으므로 '신원 증명'이 아니라 남용 차단용 문턱이다.
    private static var apiKey: String? {
        let v = Bundle.main.object(forInfoDictionaryKey: "KBTuneAPIKey") as? String
        return (v?.isEmpty == false) ? v : nil
    }

    /// 공통 요청 조립 — 인증 헤더를 한 곳에서만 붙이도록.
    private static func request(_ path: String, timeout: TimeInterval,
                                body: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        if let key = apiKey { req.setValue(key, forHTTPHeaderField: "X-API-Key") }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// 429(속도 제한)는 서버가 살아 있다는 뜻이다 — 미도달로 표시하지 않고 이번 요청만 포기한다.
    private func accept(_ resp: URLResponse?) -> Bool {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        backendReachable = (code == 200 || code == 429)
        return code == 200
    }

    @Published var backendReachable: Bool? = nil   // nil=미확인

    /// 백엔드에 LLM 키가 물려 있는지. false면 백엔드도 템플릿으로 답하는데,
    /// 그 템플릿보다 앱이 가진 컨텍스트(카드 청구·일정·카테고리)가 훨씬 풍부하다.
    /// 그래서 키가 없을 땐 앱 답변을 쓰고, 키가 붙으면 그때 백엔드에 넘긴다.
    @Published var llmEnabled = false
    /// true면 백엔드가 OpenAI·Claude처럼 기기 밖의 모델 제공자를 호출한다.
    @Published private(set) var externalLLM = false

    /// 모델이 서버 안에 있더라도 백엔드 자체가 원격이면 재무 집계값은 기기를 떠난다.
    /// 동의 화면은 '외부 모델인가'가 아니라 실제 데이터 경계를 기준으로 띄운다.
    var requiresOffDeviceConsent: Bool {
        llmEnabled && (externalLLM || !Self.isLoopbackBackend)
    }

    /// 웹 검색 — 질문 원문을 그대로 백엔드에 넘긴다.
    ///
    /// 다른 요청과 달리 `OutboundPrivacy.sanitize`를 태우지 않는다. "이태원 맛집"에서
    /// 장소를 지우면 검색할 게 남지 않기 때문이다. 대신 나가는 것을 질문 한 줄로 묶고,
    /// 예산·일정·이름은 이 경로에 아예 싣지 않는다. 사용자가 버튼을 눌렀을 때만 호출된다.
    @MainActor
    func search(_ query: String) async -> ChatMessage? {
        guard AIConsent.granted else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 검색은 모델이 웹을 읽고 문장까지 만들어 오므로 다른 호출보다 오래 걸린다.
        let req = Self.request("api/search", timeout: 45, body: ["query": String(trimmed.prefix(200))])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard accept(resp),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = json["answer"] as? String, !answer.isEmpty
            else { return nil }
            let sources = (json["sources"] as? [String]) ?? []
            return ChatMessage(
                role: .agent,
                conclusion: answer,
                reason: nil,
                impact: nil,
                basis: sources.isEmpty ? "웹 검색 결과" : "웹 검색 · " + sources.prefix(3).joined(separator: " · ")
            )
        } catch {
            return nil
        }
    }

    private var lastPingAttempt: Date?
    private static let pingCooldown: TimeInterval = 60

    /// 헬스체크(짧은 타임아웃).
    func ping(force: Bool = false) async {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-offline") {
            backendReachable = false
            llmEnabled = false
            externalLLM = false
            return
        }
        // LLM이 없는 정상 백엔드에는 같은 질문마다 다시 확인할 이유가 없다.
        if !force, backendReachable == true, !llmEnabled { return }
        if !force, let lastPingAttempt,
           Date().timeIntervalSince(lastPingAttempt) < Self.pingCooldown { return }
        lastPingAttempt = Date()

        // 백엔드가 꺼진 데모에서도 질문 하나가 오래 멈추지 않게 짧게 확인하고,
        // 실패 뒤에는 1분 동안 로컬 답변을 즉시 쓴다.
        let req = Self.request("api/health", timeout: 3)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard accept(resp) else {
                print("[KBTune] ping 실패 · HTTP \(code) · \(Self.baseURL.absoluteString)")
                llmEnabled = false
                return
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            llmEnabled = (json?["llm_enabled"] as? Bool) ?? false
            // 구버전 서버는 이 필드가 없다. 그 경우 보수적으로 외부 모델로 본다.
            externalLLM = (json?["external_llm"] as? Bool) ?? llmEnabled
            print("[KBTune] ping 성공 · llm_enabled=\(llmEnabled)")
        } catch {
            print("[KBTune] ping 예외 · \(Self.baseURL.absoluteString) · \(error)")
            backendReachable = false
            llmEnabled = false
            externalLLM = false
        }
    }

    /// 공개 통계 기준 금액 표를 통째로 받아온다.
    ///
    /// 이 경로로 나가는 게 없다 — 본문 없는 GET 이고, 받아오는 값도 참가격·가계동향조사
    /// 같은 공표 통계뿐이다. 일정 제목을 서버에 물어보는 대신 표를 받아 기기 안에서
    /// 조회하려고 이렇게 만들었다. 실패하면 nil — 앱에 넣어 둔 사본을 계속 쓴다.
    static func fetchBaseline() async -> BaselinePrices.Table? {
        let req = request("api/baseline", timeout: 5)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(BaselinePrices.Table.self, from: data)
    }

    /// 웹 검색으로 금액 찾기. 동의를 안 켰으면 부르지 않는다(호출부가 확인).
    ///
    /// 보내는 건 `SearchQuery.make()` 가 코드에 있는 말로만 조립한 검색어 하나뿐이다.
    /// 일정 제목·이름·금액은 이 요청에 실릴 칸이 아예 없다.
    static func searchCost(query: String) async -> SearchCostResult? {
        let req = request("api/search/cost", timeout: 20, body: ["query": query])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(SearchCostResult.self, from: data),
              r.amount != nil else { return nil }
        return r
    }

    /// 대화 한 턴 — 답변과 '실행할 동작'을 함께 받는다.
    ///
    /// 보내는 문장은 `sanitize()` 를 거친다. 이름·연락처·이미 저장된 일정 제목은 기기에서
    /// 가려지고, 방금 새로 말한 일정 이름만 남는다. 그게 나가야 모델이 "제주도 여행
    /// 넣어줘"를 알아듣는다. 동의를 안 켰으면 호출부가 이 함수를 부르지 않는다.
    ///
    /// 검색은 서버가 알아서 하지 않는다 — `maySearch` 가 참일 때만 도구를 쥐여 주고,
    /// 그마저도 서버의 검증기가 검색어를 검사한 뒤에야 실제로 나간다.
    func agentTurn(_ message: String, model: AppModel, maySearch: Bool,
                   events: [AgentEventRef] = [],
                   history: [AgentChatTurn] = []) async -> AgentTurnResult? {
        // 계획 숫자는 대화 경로가 쓰는 것과 **같은 함수**로 만든다. 여기서 따로 만들면
        // 화면에 293,410원이 떠 있는데 대화가 204,000원이라고 답하는 일이 생긴다.
        // 실제로 그렇게 어긋났었다 — 서버가 요청에 프로필이 없으면 데모 페르소나로 계산한다.
        guard var body = Self.makeChatRequestBody(message: message, history: history,
                                                  model: model) else { return nil }
        // 위 함수는 message 를 금융 의도 라벨로 줄여 놓는다(/api/chat 의 경계). 에이전트는
        // "제주도 여행 넣어줘"를 알아들어야 하므로 문장을 되살린다 — 대신 sanitize 는 거친다.
        // 이 한 줄이 이 기능과 /api/chat 의 프라이버시 등급을 가르는 지점이다.
        body["message"] = OutboundPrivacy.sanitize(message, model: model)
        body["history"] = history.suffix(6).map {
            ["role": $0.role == "assistant" ? "assistant" : "user",
             "content": OutboundPrivacy.sanitize($0.content, model: model)]
        }
        body["today"] = DemoClock.today
        body["may_search"] = maySearch
        // 제목은 안 싣는다 — 번호·날짜·유형·금액이면 모델이 지목할 수 있다.
        body["events"] = events.map {
            ["ref": $0.ref, "day": $0.day, "category": $0.category, "amount": $0.amount]
        }
        let req = Self.request("api/agent", timeout: 45, body: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            backendReachable = false
            return nil
        }
        guard accept(resp) else { return nil }
        return try? JSONDecoder().decode(AgentTurnResult.self, from: data)
    }

    /// 스트리밍 대화. 토큰이 올 때마다 onToken(델타) 호출.
    /// 반환: true=백엔드 응답 성공, false=실패(호출부가 로컬 폴백).
    func chatStream(_ message: String, history: [AgentChatTurn] = [], model: AppModel,
                    onToken: @escaping (String) -> Void) async -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-offline") {
            backendReachable = false
            return false
        }
        // CardAdvisor처럼 헬스체크 없이 바로 들어오는 호출도 있다. 데이터가 담긴 요청을
        // 만들기 전에 모델 위치를 먼저 확인한다.
        if backendReachable == nil { await ping() }
        guard llmEnabled else { return false }
        guard !externalLLM || AIConsent.granted else { return false }
        guard Self.isLoopbackBackend || AIConsent.granted else { return false }
        guard let body = Self.makeChatRequestBody(message: message, history: history, model: model)
        else { return false }
        let req = Self.request("api/chat", timeout: 12, body: body)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard accept(resp) else {
                print("[KBTune] chat 실패 · HTTP \(code)")
                return false
            }
            var buffer = Data()
            var shownCount = 0
            for try await b in bytes {
                buffer.append(b)
                // 버퍼 전체를 디코드해 멀티바이트(한글) 경계 안전하게 델타 추출
                if let full = String(data: buffer, encoding: .utf8), full.count > shownCount {
                    let delta = String(full.dropFirst(shownCount))
                    shownCount = full.count
                    onToken(delta)
                }
            }
            return shownCount > 0
        } catch {
            print("[KBTune] chat 예외 · \(error)")
            backendReachable = false
            return false
        }
    }

    /// 실제 `/api/chat` 요청이 사용하는 본문 조립 함수.
    /// 단위 테스트가 네트워크 직전의 최종 JSON을 검사할 수 있도록 한곳에 둔다.
    static func makeChatRequestBody(message: String, history: [AgentChatTurn] = [],
                                    model: AppModel) -> [String: Any]? {
        let fixedCosts: [[String: Any]] = [
            ["name": "고정비", "amount": BudgetEngine.fixed],
        ]
        // 이름·나이는 보내지 않는다. 백엔드 엔진도 프롬프트도 쓰지 않아서,
        // 보내봐야 쓰이지도 않는 개인정보가 네트워크와 LLM 제공자 쪽으로 흐를 뿐이다.
        let profile: [String: Any] = [
            "monthly_income": model.monthlyIncome,
            "savings_goal": model.savingsGoal,
            "fixed_costs": fixedCosts,
            "direction": model.direction.rawValue,
            "protected_categories": Array(model.protectedTags).sorted(),
        ]
        // 카드 청구와 앞으로의 일정은 월 예산 계산에 안 들어가지만 조언에는 결정적이다.
        // "이번 주 예산은 남지만 다음 달 카드값이 이미 이만큼"을 말하려면 이 값들이 필요하다.
        let b = model.billing
        let card: [String: Any] = [
            "due_next": b.dueNext, "usage": b.usage, "carryover": b.carryover,
            "pay_label": b.payLabel, "next_pay_label": b.nextPayLabel,
            "days_until_pay": b.daysUntilPay, "days_until_close": b.daysUntilClose,
            "close_label": b.closeLabel,
        ]
        // 일정 제목은 동의 선택지 자체를 두지 않고 항상 뺀다. 제목에는 자유형 실명·병원·종교처럼
        // 정규식으로 완전하게 찾을 수 없는 민감정보가 섞이므로 날짜·유형·금액만 전달한다.
        // 서버가 일정 개수를 200개로 제한한다(요청 하나로 프롬프트를 무한정 키우지 못하게).
        // 넘치면 요청 전체가 거절되므로 여기서 잘라 보낸다 — 한 달치라 실제로 닿을 일은 없다.
        let allUpcoming: [[String: Any]] = model.calendarDays
            .filter { $0.dayNumber >= model.todayDayNumber }
            .flatMap { day in
                day.events.filter { $0.amount > 0 }.map { ev -> [String: Any] in
                    ["day": day.dayNumber,
                     "amount": ev.amount,
                     "category": OutboundPrivacy.sanitize(ev.category, model: model)]
                }
            }
        let upcoming = Array(allUpcoming.prefix(200))

        // 이미 쓴 지출. "이번 달 카페에 얼마 썼어?" 같은 질문은 이게 없으면 답이 안 나온다.
        // 제목은 여기서도 뺀다 — 지난 소비라고 민감도가 낮아지지 않는다.
        // 200개를 넘으면 최근 것부터 남긴다(오래된 지출일수록 지금 판단에 덜 쓰인다).
        let allPast: [[String: Any]] = model.calendarDays
            .filter { $0.dayNumber < model.todayDayNumber }
            .flatMap { day in
                day.events.filter { $0.amount > 0 }.map { ev -> [String: Any] in
                    ["day": day.dayNumber,
                     "amount": ev.amount,
                     "category": OutboundPrivacy.sanitize(ev.category, model: model)]
                }
            }
        let past = Array(allPast.suffix(200))

        // 화면에 띄운 숫자를 그대로 넘긴다. 백엔드가 다시 계산하면 시드 차이·할부 반영 여부로
        // 값이 어긋나, 화면엔 70,000원인데 챗봇은 다른 금액을 말하는 상황이 생긴다.
        let appNumbers: [String: Any] = [
            "weekly_available": model.weeklyBudget,
            "probability": model.probability,
            "remaining_budget": model.remainingBudget,
            "spent_to_date": model.spentToDate,
            "installment_carryover": BudgetEngine.installmentCarryover,
            "month_end_remaining": model.monthEndRemainingLow,
        ]

        // 질문 원문은 어느 백엔드에도 보내지 않는다. 기기에서 금융 의도로 바꿔 보내면
        // NER가 모르는 이름·주소가 있어도 네트워크 경계 밖으로 나갈 수 없다.
        let safeMessage = OutboundPrivacy.financialIntent(message)
        guard !safeMessage.isEmpty else { return nil }
        let safeHistory: [[String: String]] = history.suffix(6).compactMap { turn in
            let role = turn.role == "assistant" ? "assistant" : "user"
            let content = turn.role == "assistant"
                ? OutboundPrivacy.sanitize(turn.content, model: model)
                : OutboundPrivacy.financialIntent(turn.content)
            return content.isEmpty ? nil : ["role": role, "content": content]
        }

        return [
            "message": safeMessage,
            "history": safeHistory,
            "profile": profile,
            "today": DemoClock.today,
            "card": card,
            "upcoming": upcoming,
            "past": past,
            "app_numbers": appNumbers,
        ]
    }

    static var isLoopbackBackend: Bool {
        let host = baseURL.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
