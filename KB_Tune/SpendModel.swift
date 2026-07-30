//  SpendModel.swift
//  금액과 주기를 한 모델로 — 계층 marked renewal process.
//
//  (카테고리 × 사용자) 하나당 충분통계량 몇 개만 들고, 거기서 "언제"와 "얼마"가
//  같이 나온다. 켤레 사후분포라서 갱신이 닫힌 형태다 — 폰에서 덧셈 몇 번이면 끝이고
//  서버로 아무것도 보내지 않는다.
//
//      빈도  N(Δ) ~ Poisson(λΔ),      λ ~ Gamma(a, b)
//      금액  log x ~ Normal(μ, σ²),   μ ~ Normal(μ₀, τ²)
//      간격  T ~ Weibull(k, η),       η = 1/(λ·Γ(1+1/k))
//
//  파이썬 원본과 검증: tools/forecast_bench/mpp.py, 방법론은 results/METHOD.md.
//  수치가 갈리면 그쪽 자체검증(python mpp.py)을 기준으로 본다.

import Foundation

// MARK: - 인구 사전분포

/// 카테고리별 인구 사전분포. 공표 통계에서 만들어 읽기 전용으로 배포한다.
struct SpendPrior: Codable, Equatable {
    var a: Double            // λ 의 Gamma 사전 shape
    var b: Double            // λ 의 Gamma 사전 rate (일 단위)
    var mu0: Double          // log 건당금액의 사전 평균
    var tau2: Double         // 개인 간 분산
    var sigma2: Double       // 개인 내 분산
    var gapShape: Double     // 간격 분포 형태. 1 = 무작위, > 1 = 주기적

    /// 평균 간격(일)과 건당 금액(원)으로 만든다. strength 는 사전분포의 무게(일).
    init(meanGapDays: Double, meanAmount: Double, gapShape: Double = 1.0,
         sigma2: Double = 0.16, tau2: Double = 0.35, strength: Double = 30) {
        self.a = strength / max(meanGapDays, 0.01)
        self.b = strength
        self.mu0 = Foundation.log(max(meanAmount, 1))
        self.tau2 = tau2
        self.sigma2 = sigma2
        self.gapShape = gapShape
    }
}

// MARK: - 카테고리별 주기 사전분포

/// 카테고리별 평균 주기와 규칙성. 금액은 여기 두지 않는다 — `BaselinePrices` 와
/// 개인 이력이 이미 원천이라 중복되면 값이 갈린다.
///
/// **규칙성(gapShape)은 도메인 가정이다.** 공개 데이터에 카테고리별 발생 간격이
/// 존재하지 않는다(12개 zip 전수 조사). 측정 가능한 것은 AI Hub 업종 지속률 서열뿐이라
/// (납부 83.6% · 쇼핑 83.4% · 교통 70.4% · 교육 53.4% · 사교활동 48.2% · 의료 31.4%)
/// 그 순서를 따라 배치했다. 개인 간격이 5개 쌓이면 `estimateShape` 가 이 값을 대체한다.
/// 상세: tools/forecast_bench/results/METHOD.md §3.7, §7.4
enum SpendPriors {

    /// (평균 주기(일), 규칙성, 금액 변동).
    ///
    /// - `shape` 규칙성. 1 = 무작위(경과일이 정보를 주지 않음), > 1 = 주기적.
    /// - `sigma2` **같은 사람이 같은 카테고리에서 쓰는 금액의 로그분산.**
    ///   카테고리마다 크게 다르다 — 미용실은 값이 거의 고정이고 쇼핑은 아니다.
    ///   이걸 상수로 두면(카드 거래 일반값 0.16) 고정가 서비스의 구간이 터진다.
    ///   와드(미용실, 42,000/38,000원)에서 80% 구간이 24,694~64,651원까지 벌어졌다.
    static func cadence(for category: String)
        -> (gapDays: Double, shape: Double, sigma2: Double) {
        switch category {
        case "구독":            return (30,  4.0, 0.01)  // 결제일·금액 모두 고정
        case "자기관리":        return (42,  3.0, 0.02)  // 미용실·병원 — 시술이 정해져 있다
        case "교통":            return (2,   2.4, 0.05)
        case "생활":            return (10,  2.4, 0.06)  // 장보기 — 장바구니가 비슷하다
        case "출근":            return (1.4, 3.0, 0.08)
        case "데이트":          return (14,  2.0, 0.12)
        case "가족":            return (21,  1.6, 0.16)
        case "모임":            return (14,  1.4, 0.18)  // 인원·2차 여부로 흔들린다
        case "문화", "여가":    return (21,  1.2, 0.20)
        case "외식":            return (5,   1.0, 0.20)
        case "업무·학업":       return (7,   1.2, 0.20)
        case "카페", "배달":    return (3,   1.0, 0.25)  // 아메리카노 vs 디저트세트
        case "경조사":          return (60,  1.0, 0.30)  // 3만·5만·10만 단계
        case "쇼핑":            return (12,  1.1, 0.45)  // 변동이 가장 크다
        default:                return (14,  1.0, 0.16)  // AI Hub 카드 거래 일반값
        }
    }

    /// 카테고리 사전분포. 금액은 호출부가 이력·baseline 에서 넘긴다.
    static func prior(for category: String, meanAmount: Double) -> SpendPrior {
        let c = cadence(for: category)
        return SpendPrior(meanGapDays: c.gapDays, meanAmount: meanAmount,
                          gapShape: c.shape, sigma2: c.sigma2)
    }
}

// MARK: - 개인 상태 (폰에만 저장)

/// 충분통계량. 관측 하나당 덧셈 몇 번. 원자료를 보관하지 않는다.
///
/// 그냥 누적하면 습관이 바뀌어도 사후분포가 안 움직인다 — 관측 100건 뒤의 새 관측
/// 하나는 가중치 1% 다. 그래서 갱신 전에 decay 를 곱한다.
struct SpendCounters: Codable, Equatable {
    var nTx: Double = 0          // 누적 건수 (감쇠하므로 실수)
    var days: Double = 0         // 관측 기간(일)
    var sumLog: Double = 0       // Σ log(건당금액)
    var sumLog2: Double = 0      // Σ log(건당금액)²  — 개인 내 분산 추정용
    var nAmt: Double = 0         // 금액 관측 수
    var lastGap: Double = 0      // 마지막 발생 이후 경과일
    var nGap: Double = 0         // 관측된 간격 수      ┐ 개인 규칙성 추정용
    var sumGap: Double = 0       // Σ 간격              │
    var sumGap2: Double = 0      // Σ 간격²             ┘

    /// - Parameter gaps: **실제로 관측된** 발생 간격(일). 규칙성 추정에만 쓴다.
    ///   집계 건수에서 만들어내면 안 된다 — 기간/건수로 균등 분할하면 분산이
    ///   인위적으로 줄어 shape 가 부풀려지고 종료 판정이 오작동한다.
    mutating func update(count: Double, totalAmount: Double, days: Double,
                         decay: Double = 1, gaps: [Double] = []) {
        if decay < 1 {
            nTx *= decay; self.days *= decay; sumLog *= decay
            sumLog2 *= decay; nAmt *= decay
            nGap *= decay; sumGap *= decay; sumGap2 *= decay
        }
        nTx += count
        self.days += days
        for g in gaps where g > 0 {
            nGap += 1
            sumGap += g
            sumGap2 += g * g
        }
        if count > 0 && totalAmount > 0 {
            let lg = Foundation.log(totalAmount / count)
            sumLog += lg * count
            sumLog2 += lg * lg * count
            nAmt += count
            lastGap = 0
        } else {
            lastGap += days
        }
    }
}

// MARK: - 사후분포

enum SpendModel {

    /// 일당 발생률의 사후 평균. Gamma-Poisson 켤레.
    static func rate(_ c: SpendCounters, _ p: SpendPrior) -> Double {
        (p.a + c.nTx) / (p.b + c.days)
    }

    /// 추정 평균 간격(일).
    static func gapDays(_ c: SpendCounters, _ p: SpendPrior) -> Double {
        1 / max(rate(c, p), 1e-9)
    }

    /// 개인 내 분산 추정에 쓰는 가상 관측 수. 이만큼은 인구값을 믿는다.
    static let sigma2Pseudo = 3.0

    /// 개인 내 분산을 관측에서 추정하고 인구값으로 shrink 한다.
    ///
    /// 인구값을 그대로 쓰면 안정적인 반복 일정에 과대하다 — 카드 거래 일반의 분산을
    /// "와드 42,000/38,000원" 같은 패턴에 적용하면 구간이 지나치게 벌어진다.
    /// 반대로 관측만 쓰면 2건에서 분산이 0 에 가까워져 구간이 붕괴한다. 그래서 섞는다.
    static func effectiveSigma2(_ c: SpendCounters, _ p: SpendPrior) -> Double {
        guard c.nAmt >= 2 else { return p.sigma2 }
        let mean = c.sumLog / c.nAmt
        var obs = max(c.sumLog2 / c.nAmt - mean * mean, 0)
        obs *= c.nAmt / max(c.nAmt - 1, 1)          // 표본분산 보정
        let w = c.nAmt / (c.nAmt + sigma2Pseudo)
        return w * obs + (1 - w) * p.sigma2
    }

    /// log 건당금액의 사후 (평균, 표준편차). Normal-Normal 켤레.
    ///
    /// 분산이 두 항이다 — 모수 불확실성은 관측이 쌓이면 줄지만 개인 내 변동은 남는다.
    /// 그래서 구간이 무한히 좁아지지 않는다. 같은 사람도 매번 같은 금액을 쓰지 않는다.
    static func logAmount(_ c: SpendCounters, _ p: SpendPrior) -> (mu: Double, sd: Double) {
        guard c.nAmt > 0 else { return (p.mu0, (p.tau2 + p.sigma2).squareRoot()) }
        let s2 = effectiveSigma2(c, p)
        let prec0 = 1 / p.tau2
        let prec = c.nAmt / s2
        let mu = (p.mu0 * prec0 + c.sumLog / s2) / (prec0 + prec)
        let variance = 1 / (prec0 + prec) + s2
        return (mu, variance.squareRoot())
    }

    // MARK: 고정 지출 판정

    /// 같은 금액 반복률이 이 이상이면 고정 지출로 본다.
    static let fixedRepeatRate = 0.6

    /// 관측 금액이 고정 지출인가. 표본이 2건 미만이면 nil — 한 건으로는 알 수 없다.
    ///
    /// 판정은 **같은 금액 반복률**로 한다. 로그분산이 아니다 —
    /// 42,000/38,000 은 분산이 작아도 고정이 아니고, 3,900 이 세 번이면 고정이다.
    /// 반복률이 그 차이를 바로 잡는다.
    ///
    /// 카테고리 라벨로는 가를 수 없어서 관측에서 판정한다 — "자기관리" 안에
    /// 미용실(고정가)과 병원(변동)이 같이 있다. 경기 카드소비 데이터 실측에서
    /// 일반병원의 건당금액 로그분산이 1.774 로 소매/유통 상위권이었다.
    static func isFixedAmount(of amounts: [Int]) -> Bool? {
        guard amounts.count >= 2 else { return nil }
        // 천원 단위로 뭉쳐서 센다. 39,900 과 40,000 을 다른 값으로 보면 안 된다.
        var counts: [Int: Int] = [:]
        for a in amounts { counts[Int((Double(a) / 1_000).rounded()), default: 0] += 1 }
        let top = counts.values.max() ?? 0
        return Double(top) / Double(amounts.count) >= fixedRepeatRate
    }

    /// 예상 금액과 80% 구간. 앱이 화면에 그대로 쓰는 값.
    static func amount(_ c: SpendCounters, _ p: SpendPrior)
        -> (median: Double, low: Double, high: Double) {
        let (mu, sd) = logAmount(c, p)
        let z = 1.2816     // 80% 구간
        return (exp(mu), exp(mu - z * sd), exp(mu + z * sd))
    }

    // MARK: 발생 확률

    /// 평균 간격을 1/λ 로 유지하는 Weibull scale.
    ///
    /// k/λ 처럼 두면 형태를 바꿀 때 평균 빈도까지 따라 움직인다 — 규칙성과 빈도는
    /// 직교해야 한다. 미용실을 "더 주기적"으로 만들었다고 방문 횟수가 변하면 안 된다.
    private static func weibullScale(_ lambda: Double, _ k: Double) -> Double {
        1 / (max(lambda, 1e-12) * tgamma(1 + 1 / k))
    }

    private static func survival(_ gap: Double, _ lambda: Double, _ k: Double) -> Double {
        let g = max(gap, 0)
        if k == 1 { return exp(-lambda * g) }
        return exp(-pow(g / weibullScale(lambda, k), k))
    }

    /// 향후 `days` 일 내 발생 확률. 추천 임계값을 여기 건다.
    ///
    /// k = 1 이면 무기억이라 경과일이 소거된다 — 카페는 어제 갔든 두 달 전이든 같다.
    /// k > 1 이면 경과일이 길수록 확률이 오른다. "보통 12일마다인데 오늘 14일째" 다.
    static func probability(_ c: SpendCounters, _ p: SpendPrior,
                            within days: Double) -> Double {
        let lambda = rate(c, p)
        let k = p.gapShape
        if k == 1 { return 1 - exp(-lambda * days) }
        let now = survival(c.lastGap, lambda, k)
        guard now > 0 else { return 1 }
        return 1 - survival(c.lastGap + days, lambda, k) / now
    }

    // MARK: 종료 판정

    /// 종료 판정을 걸 수 있는 최소 규칙성. 이 아래는 판정하지 않는다.
    ///
    /// 무기억 분포에서는 긴 공백이 종료의 증거가 못 된다 — 지수분포는 원래 긴 간격을
    /// 자연스럽게 낳는다. 카페(3일 주기)를 한 주 안 갔을 때 계산하면 37% 가 나오는데
    /// 그건 습관이 끝난 게 아니라 그냥 한 주다. 그 상태로 "이제 안 가시나요?" 를
    /// 띄우면 오작동으로 보인다.
    static let minShapeForEnding = 1.3
    static let minEventsForEnding = 3.0

    /// 규칙적인 카테고리가 "때를 넘겼는가". 예산에서 자동으로 빼는 데 쓰면 안 된다 —
    /// 사용자에게 물어보는 트리거다. 한 주 안 갔다고 술값을 빼면 다음 주에 초과한다.
    static func probabilityEnded(_ c: SpendCounters, _ p: SpendPrior,
                                 priorEnd: Double = 0.05) -> Double {
        guard c.nTx > 0, p.gapShape >= minShapeForEnding,
              c.nAmt >= minEventsForEnding else { return 0 }
        let s = survival(c.lastGap, rate(c, p), p.gapShape)
        let denom = priorEnd + (1 - priorEnd) * s
        return denom > 0 ? priorEnd / denom : 1
    }

    // MARK: 개인 규칙성 학습

    /// 간격의 변동계수에서 Weibull 형태를 역산한다.
    ///
    /// CV 가 shape 만의 함수라서 개인 간격 몇 개만 있으면 "이 사람에게 이 카테고리가
    /// 얼마나 규칙적인가"가 나온다. 서버 전송이 필요 없다 — 합 세 개로 계산된다.
    /// 표본이 적으면 사전분포와 섞는다.
    static func estimateShape(_ c: SpendCounters, _ p: SpendPrior,
                              minGaps: Double = 5) -> Double {
        guard c.nGap >= minGaps else { return p.gapShape }
        let mean = c.sumGap / c.nGap
        let variance = max(c.sumGap2 / c.nGap - mean * mean, 0)
        guard mean > 0, variance > 0 else { return p.gapShape }
        let cv = variance.squareRoot() / mean

        // CV(k) 는 k 에 대해 단조감소. 이분법으로 역산한다.
        var lo = 0.5, hi = 6.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if cvOf(shape: mid) > cv { lo = mid } else { hi = mid }
        }
        let k = (lo + hi) / 2
        let w = c.nGap / (c.nGap + 5)
        return w * k + (1 - w) * p.gapShape
    }

    private static func cvOf(shape k: Double) -> Double {
        let g1 = tgamma(1 + 1 / k)
        return (tgamma(1 + 2 / k) / (g1 * g1) - 1).squareRoot()
    }

    /// 개인 규칙성을 반영한 사전분포. 인구 가정으로 시작해 개인값으로 넘어간다.
    static func learned(_ c: SpendCounters, _ p: SpendPrior) -> SpendPrior {
        var out = p
        out.gapShape = estimateShape(c, p)
        return out
    }

    // MARK: 기간 총액 분포 — σ 하드코딩의 대체

    /// 기간 총액 표본. 건수와 건당금액을 각각 뽑아 합친다.
    ///
    /// λ 를 점추정으로 쓰면 Poisson 분산 = 평균이라 과산포를 못 잡는다. 사후 Gamma 에서
    /// 매번 뽑으면 예측분포가 음이항이 되어 산포가 맞는다.
    static func sampleTotal(_ c: SpendCounters, _ p: SpendPrior, days: Double,
                            draws: Int = 400, seed: UInt64 = 42) -> [Double] {
        var rng = SplitMix64(seed: seed)
        let (mu, sd) = logAmount(c, p)
        let shape = p.a + c.nTx
        let scale = 1 / (p.b + c.days)
        return (0..<draws).map { _ in
            let lambda = rng.gamma(shape: shape, scale: scale)
            let n = rng.poisson(lambda * days)
            var total = 0.0
            for _ in 0..<n { total += exp(mu + sd * rng.normal()) }
            return total
        }
    }
}

// MARK: - 이중 추정기

/// 습관 변화를 따라가는 이중 추정기.
///
/// decay 하나로는 적응 속도와 안정성을 동시에 얻을 수 없다 — 파이썬 자체검증에서
/// 단일 감쇠가 금주 감지에 24주를 요구했다. 빠르게 잊으면 잡음에 흔들리고 느리게
/// 잊으면 변화를 놓친다. 그래서 둘을 같이 든다.
///
/// 느린 쪽이 평소 예측(안정), 빠른 쪽이 변화 감지(민감). 배수 이상 벌어지면 습관이
/// 바뀐 것으로 보고 느린 쪽을 빠른 쪽으로 재설정한다.
struct SpendTracker: Codable, Equatable {
    var slow = SpendCounters()
    var fast = SpendCounters()
    var decaySlow = 0.95
    var decayFast = 0.60
    var divergeRatio = 2.5
    var switches = 0
    var ended = false

    /// 기억 길이를 그 카테고리의 주기 단위로 맞춘다. slow 에만 적용한다 —
    /// fast 까지 늘리면 감지가 함께 느려진다(검증에서 6주 → 15주 악화).
    private func memoryScale(_ p: SpendPrior) -> Double {
        let gap = 1 / max(p.a / p.b, 1e-9)
        return min(7 / max(gap, 7), 1)
    }

    mutating func update(count: Double, totalAmount: Double, days: Double,
                         prior p: SpendPrior, gaps: [Double] = [],
                         endThreshold: Double = 0.9) {
        // 종료 확정 뒤에도 빈 주를 누적하면 추정 주기가 무한히 늘어난다. 동결한다.
        if ended && count == 0 { return }
        if count > 0 { ended = false }

        let s = memoryScale(p)
        slow.update(count: count, totalAmount: totalAmount, days: days,
                    decay: pow(decaySlow, s), gaps: gaps)
        fast.update(count: count, totalAmount: totalAmount, days: days,
                    decay: decayFast, gaps: gaps)

        if diverged {
            slow = fast
            switches += 1
        }
        if quitSignal(p) >= endThreshold { ended = true }
    }

    /// 변화 판정은 사전분포를 섞지 않은 **원시 관측률**로 한다. 사후분포로 비교하면
    /// 사전분포 무게가 창이 짧은 fast 를 강하게 끌어당겨, 습관이 불변인 정상 상태에서도
    /// 두 추정이 배수로 벌어진다 — 판정이 편향을 재게 된다.
    private var diverged: Bool {
        guard min(fast.days, slow.days) >= 14 else { return false }
        let rf = (fast.nTx + 0.5) / fast.days
        let rs = (slow.nTx + 0.5) / slow.days
        return max(rf, rs) / max(min(rf, rs), 1e-9) > divergeRatio
    }

    /// 빈도가 급감했는가. **불규칙 카테고리의 "그만뒀다"는 이 신호로 잡는다.**
    func dropped(_ p: SpendPrior, ratio: Double = 2.0) -> Bool {
        guard fast.days >= 14, slow.nAmt >= SpendModel.minEventsForEnding else { return false }
        let rf = (fast.nTx + 0.5) / fast.days
        let rs = (slow.nTx + 0.5) / slow.days
        return rs / max(rf, 1e-9) > ratio
    }

    /// "그만둔 것 같다"의 통합 신호. 카테고리 성질에 따라 경로가 갈린다.
    ///
    ///   규칙적(shape ≥ 1.3) → 경과일 기반   probabilityEnded
    ///   불규칙(shape < 1.3) → 빈도 급감     dropped
    func quitSignal(_ p: SpendPrior) -> Double {
        let learned = SpendModel.learned(slow, p)
        if learned.gapShape >= SpendModel.minShapeForEnding {
            return SpendModel.probabilityEnded(slow, learned)
        }
        return dropped(learned) ? 1 : 0
    }

    /// 늘어나는 방향인가. 늘어난 건 바로 반영해도 안전하다 —
    /// 예산 앱에서 과소 배정은 초과 지출을 부르고 과대 배정은 기회손실에 그친다.
    func rising(_ p: SpendPrior) -> Bool {
        SpendModel.rate(fast, p) > SpendModel.rate(slow, p)
    }
}

// MARK: - 결정론적 난수 (재현 가능해야 평가할 수 있다)

/// 시드 고정 PRNG. Foundation 의 난수는 재현이 안 돼서 직접 둔다.
struct SplitMix64 {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// 표준정규. Box-Muller, 한 쌍을 만들어 하나는 보관한다.
    mutating func normal() -> Double {
        if let s = spare { spare = nil; return s }
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        let r = (-2 * Foundation.log(u1)).squareRoot()
        let theta = 2 * Double.pi * u2
        spare = r * sin(theta)
        return r * cos(theta)
    }

    /// Gamma(shape, scale). Marsaglia-Tsang.
    mutating func gamma(shape: Double, scale: Double) -> Double {
        guard shape > 0 else { return 0 }
        if shape < 1 {
            // Johnk 보정: Gamma(a) = Gamma(a+1) · U^(1/a)
            let g = gamma(shape: shape + 1, scale: 1)
            return g * pow(max(uniform(), 1e-12), 1 / shape) * scale
        }
        let d = shape - 1.0 / 3.0
        let c = 1 / (9 * d).squareRoot()
        while true {
            let x = normal()
            let v = 1 + c * x
            if v <= 0 { continue }
            let v3 = v * v * v
            let u = uniform()
            if u < 1 - 0.0331 * x * x * x * x { return d * v3 * scale }
            if Foundation.log(max(u, 1e-12)) < 0.5 * x * x + d * (1 - v3 + Foundation.log(v3)) {
                return d * v3 * scale
            }
        }
    }

    /// Poisson(mean). 평균이 크면 정규 근사로 넘긴다 (Knuth 곱셈이 불안정해진다).
    mutating func poisson(_ mean: Double) -> Int {
        guard mean > 0 else { return 0 }
        if mean > 30 {
            return max(0, Int((mean + mean.squareRoot() * normal()).rounded()))
        }
        let limit = exp(-mean)
        var k = 0
        var product = uniform()
        while product > limit {
            k += 1
            product *= uniform()
            if k > 1000 { break }
        }
        return k
    }
}
