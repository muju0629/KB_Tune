//
//  AgentAction.swift
//  KB_Tune
//
//  대화에서 나온 '이렇게 하자'를 실제 계획 변경으로 옮긴다.
//
//  서버는 제안만 한다 — 사용자 캘린더가 서버에 없어서 실행할 수도 없다. 실행은 여기서
//  하고, 사용자가 버튼을 눌러야 일어난다. 모델이 혼자 일정을 지우는 일은 없다.
//
//  금액은 모델이 비워 보낼 수 있다(`amount == nil`). 그때는 기기 안의 공개 통계 표에서
//  채운다 — 모델의 어림보다 참가격·가계동향조사 값이 근거가 분명하기 때문이다.
//

import Foundation

/// 백엔드 AgentAction 과 같은 스키마.
struct AgentAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case addEvent = "add_event"
        case moveEvent = "move_event"
        case updateAmount = "update_amount"
        case deleteEvent = "delete_event"
    }

    let kind: Kind
    let day: Int
    let title: String
    let category: String?
    let amount: Int?
    let toDay: Int?
    let label: String

    var id: String { "\(kind.rawValue)-\(day)-\(title)-\(toDay ?? 0)" }

    private enum CodingKeys: String, CodingKey {
        case kind, day, title, category, amount, label
        case toDay = "to_day"
    }
}

/// 백엔드 AgentResult 와 같은 스키마.
struct AgentTurnResult: Codable {
    let reply: String
    let actions: [AgentAction]
    let searchedQuery: String?
    let sources: [String]
    let method: String          // llm | llm+web | template

    private enum CodingKeys: String, CodingKey {
        case reply, actions, sources, method
        case searchedQuery = "searched_query"
    }
}

// MARK: - 실행

enum AgentActionRunner {

    /// 실행 결과를 사용자에게 한 줄로 알려준다. 실패해도 이유를 말한다.
    struct Outcome {
        let ok: Bool
        let message: String
    }

    @MainActor
    static func run(_ action: AgentAction, on model: AppModel) -> Outcome {
        switch action.kind {
        case .addEvent:   return add(action, model)
        case .moveEvent:  return move(action, model)
        case .updateAmount: return updateAmount(action, model)
        case .deleteEvent: return delete(action, model)
        }
    }

    /// 모델이 금액을 안 줬으면 기기 안의 기준 금액 표에서 채운다.
    private static func resolvedAmount(_ action: AgentAction) -> (amount: Int, basis: String) {
        if let amount = action.amount, amount > 0 {
            return (amount, "대화에서 정한 금액이에요.")
        }
        let estimate = EventEstimator.estimate(action.title)
        return (estimate.amount, estimate.basis)
    }

    private static func add(_ action: AgentAction, _ model: AppModel) -> Outcome {
        guard model.day(number: action.day) != nil else {
            return Outcome(ok: false, message: "그 날짜는 지금 계획에 없어요.")
        }
        let (amount, basis) = resolvedAmount(action)
        let category = action.category ?? EventEstimator.estimate(action.title).category
        model.addEvent(title: action.title, day: action.day, amount: amount,
                       category: category, basis: basis)
        return Outcome(ok: true,
                       message: "\(dayLabel(action.day))에 ‘\(action.title)’ 넣었어요. \(formatWon(amount))으로 잡았어요.")
    }

    private static func move(_ action: AgentAction, _ model: AppModel) -> Outcome {
        guard let toDay = action.toDay else {
            return Outcome(ok: false, message: "어느 날로 옮길지 몰라서 그대로 뒀어요.")
        }
        guard let event = find(action.title, on: action.day, in: model) else {
            return Outcome(ok: false, message: "‘\(action.title)’를 그 날짜에서 못 찾았어요.")
        }
        guard model.day(number: toDay) != nil else {
            return Outcome(ok: false, message: "그 날짜는 지금 계획에 없어요.")
        }
        model.deleteEvent(event, on: action.day)
        model.addEvent(title: event.title, day: toDay, amount: event.amount,
                       category: event.category, basis: event.estimateBasis)
        return Outcome(ok: true,
                       message: "‘\(event.title)’를 \(dayLabel(toDay))로 옮겼어요.")
    }

    private static func updateAmount(_ action: AgentAction, _ model: AppModel) -> Outcome {
        guard let event = find(action.title, on: action.day, in: model) else {
            return Outcome(ok: false, message: "‘\(action.title)’를 그 날짜에서 못 찾았어요.")
        }
        let (amount, _) = resolvedAmount(action)
        model.updateEventAmount(event, on: action.day, amount: amount)
        return Outcome(ok: true,
                       message: "‘\(event.title)’ 금액을 \(formatWon(amount))으로 고쳤어요.")
    }

    private static func delete(_ action: AgentAction, _ model: AppModel) -> Outcome {
        guard let event = find(action.title, on: action.day, in: model) else {
            return Outcome(ok: false, message: "‘\(action.title)’를 그 날짜에서 못 찾았어요.")
        }
        model.deleteEvent(event, on: action.day)
        return Outcome(ok: true, message: "‘\(event.title)’를 지웠어요.")
    }

    /// 제목이 정확히 같지 않아도 찾는다 — 모델이 조사를 붙이거나 줄여 쓸 수 있다.
    private static func find(_ title: String, on day: Int, in model: AppModel) -> DayEvent? {
        guard let events = model.day(number: day)?.events else { return nil }
        let needle = title.replacingOccurrences(of: " ", with: "")
        if let exact = events.first(where: {
            $0.title.replacingOccurrences(of: " ", with: "") == needle
        }) { return exact }
        return events.first {
            let candidate = $0.title.replacingOccurrences(of: " ", with: "")
            return candidate.contains(needle) || needle.contains(candidate)
        }
    }

    private static func dayLabel(_ day: Int) -> String {
        "\(DemoClock.month(of: day))월 \(DemoClock.dayOfMonth(of: day))일"
    }
}
