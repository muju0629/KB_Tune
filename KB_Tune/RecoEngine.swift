//
//  RecoEngine.swift
//  KB_Tune
//
//  결정론적 추천 엔진 — 기준서 6장 「KB Tune 추천 엔진 적용 규칙」.
//  LLM은 계산하지 않는다: 하드필터(연령·판매상태·일정) → 실적 인정 예상액 → 규칙별 예상 혜택
//  → 연회비 차감 순혜택 → 배제 사유 명시. 실적을 채우기 위한 추가 소비는 제안하지 않는다.
//

import Foundation

// MARK: - 카드 평가

struct CardEval: Identifiable {
    let product: CardProduct
    var packName: String? = nil
    var benefitLines: [(label: String, amount: Int)] = []
    var estMonthly: Int = 0        // 예상 할인 합(월)
    var netMonthly: Int = 0        // − 연회비/12
    var unmet: [String] = []       // 가입 전 확인이 필요한 조건(충족분은 화면에서 칩 ✓로 표시)
    var excludeReason: String? = nil
    var fitCopy: String = ""
    var id: String { product.id }
    var excluded: Bool { excludeReason != nil }
}

struct CardReco {
    let ranked: [CardEval]         // 순혜택 내림차순(배제 제외)
    let excluded: [CardEval]
    let recognizedSpend: Int
    var pick: CardEval? { ranked.first }
    var alternative: CardEval? { ranked.dropFirst().first }
    var others: [CardEval] { Array(ranked.dropFirst(2)) }
}

// MARK: - 적금 평가

enum SavingsVerdict {
    case buffer        // 비상금 버퍼로 추천
    case pick          // 목표 저축 추천
    case alternative   // 단기 대안
    case statusBlocked // 신청기간 종료 등 — '가입 가능'으로 표시 금지
    case conditional   // 자격·의사 확인 필요
    case excluded      // 조건 미충족
}

struct SavingsEval: Identifiable {
    let product: SavingsProduct
    let verdict: SavingsVerdict
    let fitCopy: String
    var monthlyDeposit: Int = 0    // 시뮬레이션 월 납입액(0 = 미적용)
    var months: Int = 0
    var estInterest: Int = 0       // 예상 세전 이자(만기)
    var maxInterest: Int = 0       // 모든 우대 충족 상한
    var unmet: [String] = []
    var id: String { product.id }
}

// MARK: - 엔진

enum RecoEngine {

    /// 현재는 7월 캘린더 예상액이다. 실제 카드 전월실적과는 구분해 표시한다.
    static func recognizedSpend(_ m: AppModel) -> Int { m.spendMonthly }

    // MARK: 카드

    static func evalCards(_ m: AppModel) -> CardReco {
        let recognized = recognizedSpend(m)
        let schedule = Dictionary(uniqueKeysWithValues: m.spendProfile.map { ($0.name, $0.monthly) })
        // 상품 규칙의 기존 카테고리명에 7월 일정비를 대응한다.
        let byName: [String: Int] = [
            "외식": (schedule["모임·식사"] ?? 0) + (schedule["데이트·가족"] ?? 0),
            "술·모임": schedule["모임·식사"] ?? 0,
            "쇼핑": (schedule["경조사·쇼핑"] ?? 0) + (schedule["건강·관리"] ?? 0),
            "카페": schedule["학업·연구"] ?? 0,
            "교통": schedule["출근 점심·교통"] ?? 0,
            "배달": 0,
            "구독": 0,
        ]

        var ranked: [CardEval] = []
        var excluded: [CardEval] = []

        for card in CardCatalog.all {
            var e = CardEval(product: card)

            // 하드필터 1: 연령
            if let range = card.ageRange, let age = m.userAge, !range.contains(age) {
                e.excludeReason = "만 \(range.lowerBound)~\(range.upperBound)세 전용 카드예요."
                excluded.append(e); continue
            }
            // 하드필터 2: 해외 일정
            if card.needsTravel {
                e.excludeReason = "예정된 해외여행·출장 일정이 없어요. 일정이 잡히면 다시 비교해요."
                excluded.append(e); continue
            }
            // 하드필터 3: 전월실적
            if card.spendRequirement > recognized {
                let gap = card.spendRequirement - recognized
                e.excludeReason = "실적 인정 예상액 \(formatWon(recognized))이 기준 \(formatWon(card.spendRequirement))에 \(formatWon(gap)) 못 미쳐요. 실적을 채우기 위한 추가 소비는 권하지 않아요."
                excluded.append(e); continue
            }

            // 팩별 예상 혜택 계산 → 최고 팩 채택
            var bestLines: [(label: String, amount: Int)] = []
            var bestSum = -1
            var bestPack: String? = nil
            var unmet: [String] = []
            if let range = card.ageRange, m.userAge == nil {
                unmet.append("신청 전 만 \(range.lowerBound)~\(range.upperBound)세 조건을 확인해 주세요.")
            }

            for pack in card.packs {
                var lines: [(label: String, amount: Int)] = []
                var sum = 0
                for rule in pack.rules {
                    if rule.minSpend > 0 && rule.minSpend > recognized {
                        unmet.append("\(rule.label) — 전월 \(formatWon(rule.minSpend)) 필요 (현재 예상 \(formatWon(recognized)))")
                        continue
                    }
                    let catSpend = rule.categories.reduce(0) { $0 + (byName[$1] ?? 0) }
                    var amount = 0
                    if rule.fixed > 0 {
                        amount = catSpend > 0 ? rule.fixed : 0
                    } else if rule.rate > 0 {
                        amount = Int(Double(catSpend) * rule.rate)
                        if rule.cap > 0 { amount = min(amount, rule.cap) }
                    }
                    amount = (amount / 100) * 100
                    lines.append((rule.label, amount))
                    sum += amount
                }
                if sum > bestSum {
                    bestSum = sum; bestLines = lines; bestPack = pack.name
                }
            }

            e.packName = bestPack
            e.benefitLines = bestLines
            e.estMonthly = max(bestSum, 0)
            e.netMonthly = e.estMonthly - card.annualFee / 12
            e.unmet = unmet
            e.unmet.append("혜택 계산은 7월 캘린더 예상액 기준이며 실제 전월실적은 카드 내역에서 확인해야 해요.")

            if card.kind == .credit {
                e.unmet.append("신용카드 발급은 KB국민카드 심사 기준이 적용돼요 — 발급 가능을 단정하지 않아요.")
            }

            // 개인화 문구: 실제 혜택을 만든 영역 할인의 카테고리만(전 카테고리 기본할인 제외).
            // 금액은 화면에서 순혜택 숫자로 이미 보여주므로 문구에서 반복하지 않는다.
            let focused = Set(card.packs.flatMap(\.rules).filter { !$0.isBase }.flatMap(\.categories))
            let tops = byName
                .filter { focused.contains($0.key) && $0.value > 0 }
                .sorted { $0.value > $1.value }
                .prefix(3)
            if tops.isEmpty {
                e.fitCopy = card.appCopy
            } else {
                let detail = tops.map { "\($0.key) 월 \(formatWon($0.value))" }.joined(separator: " · ")
                e.fitCopy = "7월 일정의 \(detail) 예상액에 혜택을 적용한 결과예요."
            }

            ranked.append(e)
        }

        ranked.sort { $0.netMonthly > $1.netMonthly }
        return CardReco(ranked: ranked, excluded: excluded, recognizedSpend: recognized)
    }

    // MARK: 적금·통장

    /// 만기 세전 이자(적립식): 월 납입 × 연이율 × Σ잔여개월/12
    static func savingsInterest(monthly: Int, months: Int, ratePct: Double) -> Int {
        let sum = Double(monthly) * ratePct / 100 / 12 * Double(months * (months + 1)) / 2
        return Int((sum / 10).rounded()) * 10
    }

    static func evalSavings(_ m: AppModel) -> [SavingsEval] {
        let free = m.monthlyIncome - m.spendMonthly    // 월 여유자금
        let goal = m.savingsGoal

        return SavingsCatalog.all.map { p in
            switch p.id {
            case "monimo":
                var e = SavingsEval(
                    product: p, verdict: .buffer,
                    fitCopy: "당장 꺼내 쓸 수 있어야 하는 비상금은 적금에 묶지 않는 게 원칙이에요. 200만원까지 우대가 적용되고 즉시 인출돼요.")
                e.monthlyDeposit = 1_000_000   // 기준 예시 잔액
                e.estInterest = Int(Double(e.monthlyDeposit) * p.maxRate / 100 / 12 / 100) * 100  // 월 이자(최고금리 기준)
                e.maxInterest = e.estInterest
                e.unmet = ["최고 연 4.0%는 최초 가입 + 모니모 앱 이용 + 자동이체·동의 조건 충족 시예요."]
                return e

            case "my-made":
                var e = SavingsEval(
                    product: p, verdict: .pick,
                    fitCopy: "월 수입 \(formatWon(m.monthlyIncome))에서 7월 일정 예상액 \(formatWon(m.spendMonthly))을 빼면 고정비 차감 전 \(formatWon(free))이 남아요. 월 \(formatWon(goal)) 자동저축 전 고정비를 한 번 더 확인해 주세요.")
                e.monthlyDeposit = goal
                e.months = 12
                e.estInterest = savingsInterest(monthly: goal, months: 12, ratePct: p.expectedRate)
                e.maxInterest = savingsInterest(monthly: goal, months: 12, ratePct: p.maxRate)
                e.unmet = ["우대 최고 0.6%p는 자동이체·KB카드 결제계좌 등 선택 조건을 실제로 충족해야 해요."]
                return e

            case "star-special":
                var e = SavingsEval(
                    product: p, verdict: .alternative,
                    fitCopy: "여행·행사처럼 날짜가 정해진 목표가 생기면 1~6개월로 짧게 모으는 쪽이 맞아요. 월 30만원까지 넣을 수 있어요.")
                e.monthlyDeposit = min(goal, 300_000)
                e.months = 6
                e.estInterest = savingsInterest(monthly: e.monthlyDeposit, months: 6, ratePct: p.expectedRate)
                e.maxInterest = savingsInterest(monthly: e.monthlyDeposit, months: 6, ratePct: p.maxRate)
                e.unmet = ["최고 연 6.0%는 목표달성·별 모으기·추천번호까지 모든 우대 충족 시예요."]
                return e

            case "youth-future":
                var e = SavingsEval(
                    product: p, verdict: .statusBlocked,
                    fitCopy: "나이를 입력하지 않아 연령 요건을 아직 확인하지 못했어요. 신청기간이 열리면 연령·소득·가구 요건부터 확인해 주세요.")
                e.unmet = ["만 19~34세 여부 확인", p.statusNote ?? "신청 상태 확인 필요"]
                return e

            case "dream":
                var e = SavingsEval(
                    product: p, verdict: .conditional,
                    fitCopy: "실제 주택청약 의사가 있고 2년 이상 유지할 수 있을 때만 맞는 상품이에요. 금리보다 청약 자격부터 확인해 주세요.")
                e.unmet = ["무주택 여부 확인", "실제 청약 의사 확인", "예금자보호 대상이 아닌 점 이해"]
                return e

            case "star-deposit":
                return SavingsEval(
                    product: p, verdict: .excluded,
                    fitCopy: "비상금·예정지출을 뺀 여유 목돈 100만원 이상이 확인되지 않아요. 목돈이 모이면 다시 추천할게요.")

            default:
                return SavingsEval(product: p, verdict: .excluded, fitCopy: p.appCopy)
            }
        }
    }
}
