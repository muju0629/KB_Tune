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
    /// add_event 에만 있다. 나머지는 ref 로 기존 일정을 가리킨다.
    let title: String?
    /// 앱이 매긴 기존 일정 번호. 제목을 주고받지 않으려고 번호로 가리킨다.
    let ref: Int?
    let category: String?
    let amount: Int?
    let toDay: Int?
    let label: String

    var id: String { "\(kind.rawValue)-\(day)-\(ref ?? 0)-\(title ?? "")-\(toDay ?? 0)" }

    private enum CodingKeys: String, CodingKey {
        case kind, day, title, ref, category, amount, label
        case toDay = "to_day"
    }
}

/// 서버에 보내는 기존 일정 목록 한 줄. **제목이 없다** — 번호로 가리키면 되기 때문이다.
struct AgentEventRef: Codable {
    let ref: Int
    let day: Int
    let category: String
    let amount: Int
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

// MARK: - 번호 매기기

/// 서버에 넘길 일정 목록과, 번호로 되찾는 표를 함께 만든다.
///
/// 제목은 목록에 넣지 않는다. 옮기고 지우는 데 필요한 건 '어느 것'이라는 지목뿐이고,
/// 그건 번호로 충분하다. 제목으로 맞추던 방식은 서버의 비식별화가 '카페 약속'을
/// '[이름] 약속'으로 바꿔 놓으면 앱에서 못 찾는 문제도 있었다.
@MainActor
struct AgentEventIndex {
    private(set) var refs: [AgentEventRef] = []
    private var byRef: [Int: (day: Int, event: DayEvent)] = [:]

    init(model: AppModel, from today: Int = DemoClock.today, limit: Int = 30) {
        var next = 1
        for day in model.calendarDays where day.dayNumber >= today {
            for event in day.events where event.amount > 0 {
                guard next <= limit else { return }
                refs.append(AgentEventRef(ref: next, day: day.dayNumber,
                                          category: event.category, amount: event.amount))
                byRef[next] = (day.dayNumber, event)
                next += 1
            }
        }
    }

    func lookup(_ ref: Int?) -> (day: Int, event: DayEvent)? {
        guard let ref else { return nil }
        return byRef[ref]
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
    static func run(_ action: AgentAction, on model: AppModel,
                    index: AgentEventIndex) -> Outcome {
        switch action.kind {
        case .addEvent:     return add(action, model)
        case .moveEvent:    return move(action, model, index)
        case .updateAmount: return updateAmount(action, model, index)
        case .deleteEvent:  return delete(action, model, index)
        }
    }

    private static let notFound = Outcome(
        ok: false, message: "어느 일정인지 못 찾았어요. 주간 화면에서 직접 바꿔 주세요.")

    /// 모델이 금액을 안 줬으면 기기 안의 기준 금액 표에서 채운다.
    private static func resolvedAmount(_ action: AgentAction,
                                       title: String) -> (amount: Int, basis: String) {
        if let amount = action.amount, amount > 0 {
            return (amount, "대화에서 정한 금액이에요.")
        }
        let estimate = EventEstimator.estimate(title)
        return (estimate.amount, estimate.basis)
    }

    private static func add(_ action: AgentAction, _ model: AppModel) -> Outcome {
        guard let title = action.title, !title.isEmpty else {
            return Outcome(ok: false, message: "무슨 일정인지 몰라서 못 넣었어요.")
        }
        guard model.day(number: action.day) != nil else {
            return Outcome(ok: false, message: "그 날짜는 지금 계획에 없어요.")
        }
        let (amount, basis) = resolvedAmount(action, title: title)
        let category = action.category ?? EventEstimator.estimate(title).category
        model.addEvent(title: title, day: action.day, amount: amount,
                       category: category, basis: basis)
        return Outcome(ok: true,
                       message: "\(dayLabel(action.day))에 ‘\(title)’ 넣었어요. \(formatWon(amount))으로 잡았어요.")
    }

    private static func move(_ action: AgentAction, _ model: AppModel,
                             _ index: AgentEventIndex) -> Outcome {
        guard let toDay = action.toDay else {
            return Outcome(ok: false, message: "어느 날로 옮길지 몰라서 그대로 뒀어요.")
        }
        guard let found = index.lookup(action.ref) else { return notFound }
        guard model.day(number: toDay) != nil else {
            return Outcome(ok: false, message: "그 날짜는 지금 계획에 없어요.")
        }
        model.deleteEvent(found.event, on: found.day)
        model.addEvent(title: found.event.title, day: toDay, amount: found.event.amount,
                       category: found.event.category, basis: found.event.estimateBasis)
        return Outcome(ok: true,
                       message: "‘\(found.event.title)’를 \(dayLabel(toDay))로 옮겼어요.")
    }

    private static func updateAmount(_ action: AgentAction, _ model: AppModel,
                                     _ index: AgentEventIndex) -> Outcome {
        guard let found = index.lookup(action.ref) else { return notFound }
        // 여기서는 기준 금액으로 메우지 않는다. 사용자가 '얼마로 바꿔달라'고 한 건데
        // 앱이 딴 숫자를 넣으면 고친 게 아니라 덮어쓴 것이다.
        guard let amount = action.amount, amount > 0 else {
            return Outcome(ok: false, message: "얼마로 바꿀지 못 알아들어서 그대로 뒀어요.")
        }
        model.updateEventAmount(found.event, on: found.day, amount: amount)
        return Outcome(ok: true,
                       message: "‘\(found.event.title)’ 금액을 \(formatWon(amount))으로 고쳤어요.")
    }

    private static func delete(_ action: AgentAction, _ model: AppModel,
                               _ index: AgentEventIndex) -> Outcome {
        guard let found = index.lookup(action.ref) else { return notFound }
        model.deleteEvent(found.event, on: found.day)
        return Outcome(ok: true, message: "‘\(found.event.title)’를 지웠어요.")
    }

    private static func dayLabel(_ day: Int) -> String {
        "\(DemoClock.month(of: day))월 \(DemoClock.dayOfMonth(of: day))일"
    }
}
