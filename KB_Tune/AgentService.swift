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

    /// 헬스체크(짧은 타임아웃).
    func ping() async {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-offline") {
            backendReachable = false
            return
        }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/health"))
        req.timeoutInterval = 2.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            backendReachable = (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            backendReachable = false
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
        let body: [String: Any] = [
            "message": message,
            "profile": profile,
            "today": 22,
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
