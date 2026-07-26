//
//  CardAdvisor.swift
//  KB_Tune
//
//  "왜 이 카드인가"를 사람 말로 설명하는 층.
//
//  RecoEngine은 이미 근거를 다 만든다(어느 카테고리에서 얼마, 못 채운 조건, 제외 사유).
//  문제는 그게 표로만 나열돼서, 사용자가 "그래서 나한테 왜 좋은데?"를 스스로 조립해야 했다는 것.
//  이 파일이 그 조립을 대신한다.
//
//  백엔드 에이전트가 붙어 있으면 자연어 요약을 받고, 없으면 같은 근거로 로컬 문장을 만든다.
//  데모 중 백엔드가 꺼져 있어도 화면이 비면 안 되므로 로컬 경로가 기본값이고,
//  에이전트 응답은 그 위에 덮어쓴다.
//

import SwiftUI
import Combine

@MainActor
final class CardAdvisor: ObservableObject {

    enum Source { case local, agent }

    @Published private(set) var summary = ""
    @Published private(set) var source: Source = .local
    @Published private(set) var isStreaming = false

    private let agent = AgentService()
    private var explainedCardID: String?

    /// 카드 하나에 대한 설명을 만든다. 같은 카드면 다시 부르지 않는다.
    func explain(_ eval: CardEval, reco: CardReco, model: AppModel) async {
        guard explainedCardID != eval.id else { return }
        explainedCardID = eval.id

        // 1) 로컬 요약을 먼저 채운다 — 네트워크를 기다리는 동안에도 빈 화면이 없다.
        summary = Self.localSummary(eval, reco: reco, model: model)
        source = .local

        // 2) 에이전트가 살아 있으면 자연어 요약으로 교체한다.
        isStreaming = true
        defer { isStreaming = false }

        var streamed = ""
        let ok = await agent.chatStream(Self.prompt(eval, reco: reco, model: model), model: model) { delta in
            streamed += delta
        }
        if ok, streamed.count > 20 {
            summary = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
            source = .agent
        }
    }

    func reset() { explainedCardID = nil }

    // MARK: 에이전트 프롬프트

    /// 결정론 엔진이 계산한 근거만 넘긴다. 금액을 새로 지어내지 않게 하는 게 핵심이다.
    private static func prompt(_ e: CardEval, reco: CardReco, model: AppModel) -> String {
        let benefits = e.benefitLines
            .filter { $0.amount > 0 }
            .map { "\($0.label) 월 \($0.amount)원" }
            .joined(separator: ", ")
        let spend = model.spendProfile
            .sorted { $0.monthly > $1.monthly }
            .prefix(3)
            .map { "\($0.name) 월 \($0.monthly)원" }
            .joined(separator: ", ")

        return """
        아래는 결정론 엔진이 계산한 카드 추천 근거야. 이걸 바탕으로 \(model.userName)님에게 \
        "왜 이 카드인지"를 2~3문장으로 설명해줘.

        카드: \(e.product.name) (\(e.product.kind.label))
        연회비: 월 환산 \(e.product.annualFee / 12)원
        예상 혜택: 월 \(e.estMonthly)원 → 연회비 빼면 월 \(e.netMonthly)원
        혜택이 나온 곳: \(benefits.isEmpty ? "없음" : benefits)
        전월실적 기준: \(e.product.spendRequirement)원 / 이 사람 예상 실적: \(reco.recognizedSpend)원
        이 사람의 7월 주요 소비: \(spend)
        아직 못 채운 조건: \(e.unmet.isEmpty ? "없음" : e.unmet.joined(separator: " / "))

        규칙:
        - 위에 없는 금액이나 혜택을 지어내지 마.
        - 실적을 채우려고 더 쓰라고 권하지 마.
        - 해요체로, 군더더기 없이.
        - 이 사람의 실제 소비 카테고리를 근거로 들어.
        """
    }

    // MARK: 로컬 요약 (백엔드 없이도 같은 근거로 설명)

    /// 혜택 라벨은 "뷰티·편의점 5% — 올리브영·GS25·CU"처럼 길다.
    /// 문장 안에서는 앞쪽 카테고리만 써야 읽힌다. 상세 조건은 아래 순혜택 표가 그대로 보여준다.
    private static func shortLabel(_ label: String) -> String {
        let head = label.split(separator: "—").first.map(String.init) ?? label
        return head
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func localSummary(_ e: CardEval, reco: CardReco, model: AppModel) -> String {
        let name = model.userName
        var parts: [String] = []

        // 혜택이 어느 소비에서 나왔는지 — 금액이 큰 순으로 최대 2개
        let top = e.benefitLines.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount }.prefix(2)
        if let first = top.first {
            let where_ = top.map { shortLabel($0.label) }.joined(separator: "·")
            parts.append("\(name)님의 7월 소비에 이 카드를 대보면 \(where_)에서 혜택이 붙어요. "
                         + "가장 큰 건 \(shortLabel(first.label)) 월 \(formatWon(first.amount))이에요.")
        } else {
            parts.append("\(name)님의 7월 소비 구성에는 이 카드가 크게 걸리는 항목이 없어요.")
        }

        // 순혜택 — 연회비를 빼고 남는 돈
        if e.product.annualFee > 0 {
            parts.append("연회비 월 \(formatWon(e.product.annualFee / 12))를 빼면 월 \(formatWon(e.netMonthly))이 남아요.")
        } else {
            parts.append("연회비가 없어서 월 \(formatWon(e.netMonthly))이 그대로 남아요.")
        }

        // 실적 조건 — 이미 넘겼는지가 사용자가 제일 궁금한 지점
        if e.product.spendRequirement == 0 {
            parts.append("전월실적 조건이 없어서 조건을 맞추려 애쓸 필요가 없어요.")
        } else if reco.recognizedSpend >= e.product.spendRequirement {
            parts.append("전월실적 \(formatWon(e.product.spendRequirement)) 기준은 지금 소비(\(formatWon(reco.recognizedSpend)))로 이미 넘겨요.")
        }

        return parts.joined(separator: " ")
    }
}
