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

@MainActor
final class AgentService: ObservableObject {

    /// 로컬 개발: http://localhost:8000 · 데모 배포: Render의 https URL로 교체.
    static var baseURL = URL(string: "http://localhost:8000")!

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
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/health"))
        req.timeoutInterval = 2.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            backendReachable = (resp as? HTTPURLResponse)?.statusCode == 200
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
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/estimate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                backendReachable = false
                return nil
            }
            backendReachable = true
            return try JSONDecoder().decode(EstimateResponse.self, from: data)
        } catch {
            backendReachable = false
            return nil
        }
    }

    /// OCR 텍스트 → 거래 구조화 (POST /api/extract).
    /// 백엔드가 없거나 실패하면 nil → 호출부가 LocalExtractor 로 폴백.
    func extract(text: String) async -> ExtractResponse? {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/extract"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                backendReachable = false
                return nil
            }
            backendReachable = true
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
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let fixedCosts: [[String: Any]] = [
            ["name": "고정비", "amount": BudgetEngine.fixed],
        ]
        var profile: [String: Any] = [
            "name": model.userName,
            "monthly_income": model.monthlyIncome,
            "savings_goal": model.savingsGoal,
            "fixed_costs": fixedCosts,
            "direction": model.direction.rawValue,
            "protected_categories": Array(model.protectedTags).sorted(),
        ]
        if let age = model.userAge {
            profile["age"] = age
        }
        // 카드 청구와 앞으로의 일정은 월 예산 계산에 안 들어가지만 조언에는 결정적이다.
        // "이번 주 예산은 남지만 다음 달 카드값이 이미 이만큼"을 말하려면 이 값들이 필요하다.
        let b = model.billing
        let card: [String: Any] = [
            "due_next": b.dueNext, "usage": b.usage, "carryover": b.carryover,
            "pay_label": b.payLabel, "next_pay_label": b.nextPayLabel,
            "days_until_pay": b.daysUntilPay, "days_until_close": b.daysUntilClose,
            "close_label": b.closeLabel,
        ]
        let upcoming: [[String: Any]] = model.calendarDays
            .filter { $0.dayNumber >= model.todayDayNumber }
            .flatMap { day in
                day.events.filter { $0.amount > 0 }.map { ev in
                    ["day": day.dayNumber, "title": ev.title,
                     "amount": ev.amount, "category": ev.category] as [String: Any]
                }
            }

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
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                backendReachable = false
                return false
            }
            backendReachable = true
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
