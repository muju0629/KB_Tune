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

/// 캘린더 일정 제목을 LLM 제공자에게 넘길지에 대한 사용자 동의.
///
/// 제목에는 "정형외과 진료", "성당 모임" 같은 값이 들어갈 수 있다 —
/// 건강·종교·관계는 금액보다 민감하고, 한번 외부로 나가면 회수할 수 없다.
/// 그래서 기본은 '안 보냄'이고, 명시적으로 동의할 때만 넘긴다.
/// 동의하지 않아도 일정 유형과 금액은 넘어가므로 조언 자체는 계속 동작한다.
enum EventTitleConsent {
    private static let key = "sharesEventTitlesWithLLM"

    /// 물어본 적이 있는지. false는 '거절'이 아니라 '아직 안 물어봄'이다.
    static var asked: Bool { UserDefaults.standard.object(forKey: key) != nil }
    static var granted: Bool { UserDefaults.standard.bool(forKey: key) }

    static func set(_ value: Bool) { UserDefaults.standard.set(value, forKey: key) }
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

    /// 헬스체크(짧은 타임아웃).
    func ping() async {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-offline") {
            backendReachable = false
            llmEnabled = false
            return
        }
        let req = Self.request("api/health", timeout: 2.5)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard accept(resp) else { llmEnabled = false; return }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            llmEnabled = (json?["llm_enabled"] as? Bool) ?? false
        } catch {
            backendReachable = false
            llmEnabled = false
        }
    }

    /// 일정 제목 → 예상 지출 추정 (POST /api/estimate).
    /// 실패하면 nil → 호출부가 EventEstimator(로컬)로 폴백.
    func estimate(title: String) async -> EstimateResponse? {
        let req = Self.request("api/estimate", timeout: 10, body: ["title": title])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard accept(resp) else { return nil }
            return try JSONDecoder().decode(EstimateResponse.self, from: data)
        } catch {
            backendReachable = false
            return nil
        }
    }

    /// OCR 텍스트 → 거래 구조화 (POST /api/extract).
    /// 백엔드가 없거나 실패하면 nil → 호출부가 LocalExtractor 로 폴백.
    func extract(text: String) async -> ExtractResponse? {
        let req = Self.request("api/extract", timeout: 15, body: ["text": text])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard accept(resp) else { return nil }
            return try JSONDecoder().decode(ExtractResponse.self, from: data)
        } catch {
            backendReachable = false
            return nil
        }
    }

    /// 스트리밍 대화. 토큰이 올 때마다 onToken(델타) 호출.
    /// 반환: true=백엔드 응답 성공, false=실패(호출부가 로컬 폴백).
    func chatStream(_ message: String, model: AppModel,
                    onToken: @escaping (String) -> Void) async -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-offline") {
            backendReachable = false
            return false
        }
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
        // 동의가 없으면 일정 제목을 빼고 유형·금액만 넘긴다. 서버는 제목 없이도 답을 만든다.
        // 서버가 일정 개수를 200개로 제한한다(요청 하나로 프롬프트를 무한정 키우지 못하게).
        // 넘치면 요청 전체가 거절되므로 여기서 잘라 보낸다 — 한 달치라 실제로 닿을 일은 없다.
        let shareTitles = EventTitleConsent.granted
        let allUpcoming: [[String: Any]] = model.calendarDays
            .filter { $0.dayNumber >= model.todayDayNumber }
            .flatMap { day in
                day.events.filter { $0.amount > 0 }.map { ev -> [String: Any] in
                    var e: [String: Any] = ["day": day.dayNumber,
                                            "amount": ev.amount, "category": ev.category]
                    if shareTitles { e["title"] = ev.title }
                    return e
                }
            }
        let upcoming = Array(allUpcoming.prefix(200))

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

        let body: [String: Any] = [
            "message": message,
            "profile": profile,
            "today": DemoClock.today,
            "card": card,
            "upcoming": upcoming,
            "app_numbers": appNumbers,
        ]
        let req = Self.request("api/chat", timeout: 12, body: body)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard accept(resp) else { return false }
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
            backendReachable = false
            return false
        }
    }
}
