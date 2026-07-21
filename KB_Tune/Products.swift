//
//  Products.swift
//  KB_Tune
//
//  KB 금융상품 카탈로그 — 「KB Tune 금융상품 추천 케이스 기준서 v2 (2026.07.21)」 기준.
//  예·적금 6종 + 신용카드 5종 + 체크카드 5종.
//  ⚠️ 금리·혜택·판매 상태는 검증일(2026.07.21) 기준. 화면에는 공식 링크 + 검증일 + 면책 문구를 반드시 노출.
//

import Foundation

let productVerifiedAt = "2026.07.21"

let productDisclaimer =
    "본 추천은 회원님의 최근 3개월 소비 데이터 기준의 참고 정보예요. 금리·혜택·판매 상태는 변동될 수 있으니 가입 전 공식 안내에서 꼭 확인해 주세요."

// MARK: - 카드

enum CardKind {
    case credit, debit
    var label: String { self == .credit ? "신용카드" : "체크카드" }
}

/// 혜택 규칙: 소비 카테고리(AppModel.spendProfile 이름)에 매핑해 결정론적으로 계산
struct BenefitRule {
    let label: String
    let categories: [String]  // 빈 배열 = 회원 소비 데이터에 해당 없음(라벨만 표시)
    var rate: Double = 0
    var fixed: Int = 0        // 정액 할인(해당 소비가 있을 때)
    var cap: Int = 0          // 월 한도(0 = 없음)
    var minSpend: Int = 0     // 이 규칙만의 전월실적 구간
    var isBase: Bool = false  // 전 카테고리 기본할인 여부(추천 사유 문구에서 제외)
}

struct BenefitPack {
    let name: String?         // 선택팩 이름(단일 구성이면 nil)
    let rules: [BenefitRule]
}

struct CardProduct: Identifiable {
    let id: String
    let kind: CardKind
    let name: String
    let short: String           // 기준서의 카드 정체성 한 줄
    let annualFee: Int          // 일반 연회비(0 = 없음)
    let feeNote: String
    let spendRequirement: Int   // 주 실적 구간(0 = 전월실적 없음)
    let spendNote: String
    var ageRange: ClosedRange<Int>? = nil
    var needsTravel: Bool = false
    let capNote: String         // 최대 한도 요약(최대치 ≠ 예상치 구분 표기용)
    let packs: [BenefitPack]
    let appCopy: String         // 기준서 '앱 노출 문구'
    let cautions: [String]
    let imageURL: String
    let url: String
}

private let allCategories = ["외식", "술·모임", "쇼핑", "카페", "교통", "배달", "구독"]

enum CardCatalog {

    static let all: [CardProduct] = credit + debit

    // MARK: 신용카드 5종

    static let credit: [CardProduct] = [
        CardProduct(
            id: "all-card", kind: .credit, name: "ALL 카드",
            short: "실적 부담이 낮은 기본형 신용카드",
            annualFee: 20_000, feeNote: "일반 2만원 · 모바일단독 1.4만원",
            spendRequirement: 0, spendNote: "국내 1%는 전월실적 없음",
            capNote: "국내 1%는 한도 없음 · 부가혜택은 통합 월 3천원",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "국내 결제 1% 할인 (실적·한도 없음)", categories: allCategories, rate: 0.01, isBase: true),
                BenefitRule(label: "멤버십 50%·OTT 10%·통신 5% (통합 월 3천원)", categories: ["구독"], rate: 0.10, cap: 3_000, minSpend: 400_000),
            ])],
            appCopy: "실적을 억지로 채우지 않아도 국내 결제 1%를 단순하게 받을 수 있어요.",
            cautions: [
                "멤버십·OTT·통신 부가혜택은 전월 40만원 충족이 필요해요.",
                "해외 2%는 VISA만 적용되고 국제브랜드 수수료는 별도예요.",
                "할인받은 자동납부 매출 등 일부는 전월 실적에서 제외돼요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09922_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=09922"
        ),
        CardProduct(
            id: "my-wesh", kind: .credit, name: "My WE:SH 카드",
            short: "식비·모임·통신·OTT 생활형",
            annualFee: 15_000, feeNote: "일반 1.5만원 · 모바일단독 9천원",
            spendRequirement: 400_000, spendNote: "전월실적 40만원 이상",
            capNote: "영역별 월 5천원~1만원 한도",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "음식점·GS25·CU 10% (월 5천원)", categories: ["외식"], rate: 0.10, cap: 5_000),
                BenefitRule(label: "KB Pay 10% (월 5천원)", categories: ["쇼핑"], rate: 0.10, cap: 5_000),
                BenefitRule(label: "통신 10%·OTT 30% (통합 월 5천원)", categories: ["구독"], rate: 0.30, cap: 5_000),
                BenefitRule(label: "선택팩 — 배달·커피 5% 등 (월 5천원)", categories: ["배달", "카페"], rate: 0.05, cap: 5_000),
            ])],
            appCopy: "식비·편의점·통신·OTT가 고르게 보여 생활 혜택을 묶어 받는 편이 유리해요.",
            cautions: [
                "할인받은 이용 건 전체가 다음 달 전월 실적에서 제외돼요.",
                "OTT는 공식 홈페이지 정기결제, 통신은 지정 통신사 자동납부만 인정돼요.",
                "3개 선택팩 중 하나만 선택할 수 있고 변경은 다음 달부터 적용돼요.",
                "표시 할인율보다 월 한도가 작아 예상 순혜택 계산이 필요해요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09123_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=09923"
        ),
        CardProduct(
            id: "wesh-daily", kind: .credit, name: "WE:SH Daily 카드",
            short: "한 개 소비영역 집중형",
            annualFee: 15_000, feeNote: "일반 1.5만원 · 모바일단독 9천원",
            spendRequirement: 400_000, spendNote: "선택 할인은 40만·80만원 구간",
            capNote: "선택 할인 통합 월 7천원(40만)·1.2만원(80만)",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "선택 영역 10% (KB Pay, 통합 월 7천원)", categories: ["카페"], rate: 0.10, cap: 7_000),
                BenefitRule(label: "국내 기본 0.5% (실적·한도 없음)", categories: allCategories, rate: 0.005, isBase: true),
            ])],
            appCopy: "가장 많이 쓰는 한 영역을 골라 KB Pay 10% 혜택에 집중하는 편이 좋아요.",
            cautions: [
                "선택 할인은 KB Pay 결제에만 적용되고 영역 변경은 다음 달부터예요.",
                "선택 할인받은 매출 전체가 전월 실적에서 제외돼요.",
                "데일리 스탬프는 KB Pay 앱을 월 20일 이상 이용해야 해요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09570_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=09570"
        ),
        CardProduct(
            id: "wesh-travel", kind: .credit, name: "WE:SH Travel",
            short: "해외여행·해외결제 신용카드",
            annualFee: 25_000, feeNote: "일반 2.5만원 · 모바일단독 1.9만원",
            spendRequirement: 300_000, spendNote: "국내 혜택은 30만원부터",
            needsTravel: true,
            capNote: "국내 일상 월 1~3만원 · 항공 월 2만원",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "해외 수수료 총 1.25% 면제 (실적 없음)", categories: []),
                BenefitRule(label: "환율우대 100% (USD)", categories: []),
                BenefitRule(label: "공항 라운지 연 2회 (Mastercard·전월 30만원)", categories: []),
            ])],
            appCopy: "예정된 해외결제와 라운지 이용을 합치면 연회비보다 절감액이 커질 가능성이 있어요.",
            cautions: [
                "해외 핵심혜택과 라운지는 Mastercard 국내외겸용 발급이 필요해요.",
                "해외 이용액은 국내 전월 실적에 포함되지 않아요.",
                "국내 할인받은 매출은 대부분 전월 실적에서 제외돼요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09561_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=09561"
        ),
        CardProduct(
            id: "tocktock", kind: .credit, name: "청춘대로 톡톡카드",
            short: "커피·간편결제·교통 특화 대안",
            annualFee: 10_000, feeNote: "K-World 1만원 · 모바일 4천원",
            spendRequirement: 300_000, spendNote: "전월실적 30만원 이상",
            capNote: "스타벅스 월 1만원 · 나머지 영역 월 5천원",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "스타벅스 50% (월 1만원)", categories: ["카페"], rate: 0.50, cap: 10_000),
                BenefitRule(label: "버거·패스트푸드 20% (월 5천원)", categories: ["외식"], rate: 0.20, cap: 5_000),
                BenefitRule(label: "간편결제 10% (월 5천원)", categories: ["쇼핑"], rate: 0.10, cap: 5_000),
                BenefitRule(label: "교통·통신 10% (통합 월 5천원)", categories: ["교통"], rate: 0.10, cap: 5_000),
            ])],
            appCopy: "스타벅스와 간편결제를 반복해서 써서 작은 월 한도를 빠르게 채울 수 있어요.",
            cautions: [
                "높은 표시 할인율과 달리 월 한도가 작아요.",
                "할인받은 매출 전체가 전월 실적에서 제외돼요.",
                "My WE:SH와 중복성이 커서 함께 쓰기보다 비교 후 선택해요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09174_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=09174"
        ),
    ]

    // MARK: 체크카드 5종

    static let debit: [CardProduct] = [
        CardProduct(
            id: "youth-club", kind: .debit, name: "Youth Club 체크카드",
            short: "18~29세 선택형 체크카드",
            annualFee: 0, feeNote: "연회비 없음",
            spendRequirement: 200_000, spendNote: "전월실적 20만원 이상",
            ageRange: 18...29,
            capNote: "팩 영역별 월 2천~5천원 한도",
            packs: [
                BenefitPack(name: "A팩 (OTT·앱·여가)", rules: [
                    BenefitRule(label: "OTT 50% (월 5천원)", categories: ["구독"], rate: 0.50, cap: 5_000),
                    BenefitRule(label: "앱스토어 30% (월 5천원)", categories: [], rate: 0.30, cap: 5_000),
                    BenefitRule(label: "여가·이동 20% (영역별 월 2천원)", categories: [], rate: 0.20, cap: 2_000),
                ]),
                BenefitPack(name: "B팩 (멤버십·통신·배달)", rules: [
                    BenefitRule(label: "멤버십 50% (월 5천원)", categories: [], rate: 0.50, cap: 5_000),
                    BenefitRule(label: "통신 자동납부 30% (월 5천원)", categories: [], rate: 0.30, cap: 5_000),
                    BenefitRule(label: "배달 20% (월 2천원)", categories: ["배달"], rate: 0.20, cap: 2_000),
                    BenefitRule(label: "패션·뷰티 20% (월 2천원)", categories: ["쇼핑"], rate: 0.20, cap: 2_000),
                ]),
            ],
            appCopy: "신용카드 없이도 지금 소비에 맞는 A·B팩 하나를 골라 지출을 통제할 수 있어요.",
            cautions: [
                "A팩과 B팩은 동시에 적용되지 않고 변경은 다음 달부터예요.",
                "후불교통·등록금·상품권 등은 실적에서 제외돼요.",
                "OTT·배달·통신은 지정 결제경로·자동납부 조건을 확인해요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/04124_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=04124"
        ),
        CardProduct(
            id: "nori2", kind: .debit, name: "노리2 체크카드(KB Pay)",
            short: "대학생·사회초년생 일상형",
            annualFee: 0, feeNote: "연회비 없음",
            spendRequirement: 200_000, spendNote: "전월실적 20만원 이상 (커피는 실적 없음)",
            capNote: "통합한도 월 2만원 (20만원 구간)",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "커피 10% — 스타벅스·커피빈 (월 3천원, 실적 없음)", categories: ["카페"], rate: 0.10, cap: 3_000),
                BenefitRule(label: "앱·문화 10% — 구글플레이·앱스토어", categories: ["구독"], rate: 0.10),
                BenefitRule(label: "뷰티·편의점 5% — 올리브영·GS25·CU", categories: ["쇼핑"], rate: 0.05),
                BenefitRule(label: "구독·배달 정액 할인 (조건별 월 1~2회)", categories: ["배달"], fixed: 1_000),
                BenefitRule(label: "KB Pay 추가 2% (월 5천원)", categories: allCategories, rate: 0.02, cap: 5_000, minSpend: 300_000, isBase: true),
            ])],
            appCopy: "커피부터 앱·편의점·배달까지 일상 소비를 체크카드 한 장으로 묶기 좋아요.",
            cautions: [
                "커피 외 일상 혜택은 전월 20만원, KB Pay 추가는 30만원이 필요해요.",
                "KB Pay 추가할인은 통합한도에서 함께 차감돼요.",
                "후불교통·등록금·상품권·포인트리 충전 등은 실적에서 제외돼요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/07964_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=07964"
        ),
        CardProduct(
            id: "kpass", kind: .debit, name: "K-패스체크카드",
            short: "통학·출퇴근 대중교통형",
            annualFee: 0, feeNote: "연회비 없음",
            spendRequirement: 200_000, spendNote: "전월실적 20만원 이상",
            capNote: "카드 적립 합계 월 최대 1만점",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "버스·지하철 10% 포인트리 (월 2천점)", categories: ["교통"], rate: 0.10, cap: 2_000),
                BenefitRule(label: "생활영역 1% — 커피·편의점 등 (월 4천점)", categories: ["카페"], rate: 0.01, cap: 4_000),
                BenefitRule(label: "KB Pay 결제 시 생활 +1% (월 4천점)", categories: ["카페"], rate: 0.01, cap: 4_000),
            ])],
            appCopy: "버스·지하철 이용이 반복돼 카드 적립과 K-패스 환급을 함께 비교할 가치가 있어요.",
            cautions: [
                "정부 K-패스 환급은 앱 회원가입·카드 등록이 필요하고, 카드 적립과는 별도예요.",
                "택시·시외버스·고속버스·공항버스는 적립에서 제외돼요.",
                "후불교통요금 자체는 전월 실적에서 제외돼요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09322_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?mainCC=a&cooperationcode=09322"
        ),
        CardProduct(
            id: "travelers", kind: .debit, name: "트래블러스 체크카드",
            short: "해외여행·철도 체크카드",
            annualFee: 0, feeNote: "연회비 없음",
            spendRequirement: 200_000, spendNote: "해외 수수료 면제는 실적 없음",
            needsTravel: true,
            capNote: "해외 가맹점 10%는 월 1만원",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "해외 수수료 1.25% 면제 (실적 없음)", categories: []),
                BenefitRule(label: "해외 ATM 수수료 면제 (월 10회)", categories: []),
                BenefitRule(label: "해외 가맹점 10% (월 1만원·전월 20만원)", categories: []),
            ])],
            appCopy: "해외에서 쓸 돈만 외화로 준비해 신용카드 없이 수수료 부담을 줄일 수 있어요.",
            cautions: [
                "해외 결제는 외화머니 또는 지정 외화통장 잔액이 있어야 해요.",
                "현지 ATM 운영사 수수료(surcharge)는 면제되지 않을 수 있어요.",
                "DCC 해외원화결제는 이용할 수 없어요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/09562_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?cooperationcode=09562&mainCC=a"
        ),
        CardProduct(
            id: "checkcheck", kind: .debit, name: "첵첵 체크카드",
            short: "건당 기준 충족형 생활 체크카드",
            annualFee: 0, feeNote: "연회비 없음",
            spendRequirement: 300_000, spendNote: "전월실적 30만·60만원 구간",
            capNote: "통합한도 월 1만원(30만)·2만원(60만)",
            packs: [BenefitPack(name: nil, rules: [
                BenefitRule(label: "지정처 1만원 이상 결제 시 건당 1천원 — CU·스타벅스·CGV", categories: ["카페"], fixed: 1_000),
                BenefitRule(label: "2만원 이상 결제 시 건당 1천원 — 간편결제·올리브영·서점", categories: ["쇼핑"], fixed: 1_000),
                BenefitRule(label: "버스·지하철 월 2천원 한도", categories: ["교통"], fixed: 1_000),
            ])],
            appCopy: "자주 가는 지정 매장에서 건당 기준을 넘는 결제가 반복돼 정액 할인을 받기 좋아요.",
            cautions: [
                "지정 가맹점과 건당 최소 결제금액(1·2·3만원)을 모두 충족해야 해요.",
                "'2~4천원 할인'은 건당이 아니라 영역별 월 한도예요.",
                "소액 결제가 많으면 실효 혜택이 낮아요.",
            ],
            imageURL: "https://img1.kbcard.com/ST/img/cxc/kbcard/upload/img/product/01914_img.png",
            url: "https://card.kbcard.com/CRD/DVIEW/HCAMCXPRICAC0076?cooperationcode=01914&mainCC=a"
        ),
    ]
}

// MARK: - 예금·적금

/// 기간은 termLabel이 따로 표시하므로 역할 이름에는 넣지 않는다(중복 방지).
enum SavingsRole: String {
    case buffer = "비상금·현금 버퍼"
    case short = "단기 목표"
    case general = "일반 목표"
    case lump = "목돈 운용"
    case policy = "청년 정책형"
    case housing = "청약·주거 목표"
}

struct RateLine {
    let area: String
    let value: String
    let condition: String
}

struct SavingsProduct: Identifiable {
    let id: String
    let name: String
    let role: SavingsRole
    let symbol: String
    let termLabel: String
    let payLabel: String
    let rateLabel: String       // 화면 표기용(세전)
    let expectedRate: Double    // 회원 기준 현실 예상 금리(연 %)
    let maxRate: Double         // 모든 우대 충족 상한(연 %)
    var statusNote: String? = nil  // nil = 판매중
    let appCopy: String
    let benefits: [RateLine]
    let cautions: [String]
    let url: String
}

enum SavingsCatalog {

    static let all: [SavingsProduct] = [
        SavingsProduct(
            id: "monimo", name: "모니모 KB 매일이자 통장",
            role: .buffer, symbol: "bolt.circle",
            termLabel: "입출금 자유", payLabel: "200만원 이하 우대",
            rateLabel: "기본 연 0.1% · 최고 연 4.0% (200만원 이하·세전)",
            expectedRate: 4.0, maxRate: 4.0,
            appCopy: "갑작스러운 지출에 대비할 돈은 묶지 않고, 200만원까지 현금 버퍼로 따로 관리해요.",
            benefits: [
                RateLine(area: "특별우대", value: "연 2.9%p", condition: "최초 가입 + 모니모 앱 서비스 이용"),
                RateLine(area: "자동이체", value: "최고 연 0.6%p", condition: "제휴 자동이체 건당 0.2%p"),
                RateLine(area: "마케팅 동의", value: "연 0.4%p", condition: "KB·모니모 동의 조건 충족"),
            ],
            cautions: [
                "최고금리는 매일 최종잔액 중 200만원 이하에만 적용돼요.",
                "해지 후 재가입하면 우대금리를 받을 수 없어요.",
                "입출금 통장이라 목표 납입을 강제하지 않아요 — 자동저축 규칙을 따로 잡아요.",
            ],
            url: "https://obank.kbstar.com/quics?cc=b061496%3Ab061645&isNew=Y&page=C016613&prcode=DP01001594"
        ),
        SavingsProduct(
            id: "star-special", name: "KB 특★한 적금",
            role: .short, symbol: "star.circle",
            termLabel: "1~6개월", payLabel: "월 1천원~30만원",
            rateLabel: "연 2.00~6.00% (세전)",
            expectedRate: 3.0, maxRate: 6.0,
            appCopy: "가까운 일정에 필요한 돈이라 1~6개월 목표로 짧게 모으는 방식이 잘 맞아요.",
            benefits: [
                RateLine(area: "목표달성", value: "최고 연 1.0%p", condition: "설정한 목표금액 달성"),
                RateLine(area: "별 모으기", value: "최고 연 1.0%p", condition: "전용화면에서 10·20개 달성"),
                RateLine(area: "함께해요", value: "최고 연 2.0%p", condition: "추천번호 조건 충족"),
            ],
            cautions: [
                "만기일 변경은 1회만 가능하고 취소할 수 없어요.",
                "최고금리는 앱 행동 + 추천번호까지 모든 우대 충족이 필요해요.",
                "만기 전 해지하면 낮은 중도해지이율이 적용돼요.",
            ],
            url: "https://obank.kbstar.com/quics?cc=b061496%3Ab061645&isNew=Y&page=C016613&prcode=DP01001566"
        ),
        SavingsProduct(
            id: "my-made", name: "KB내맘대로적금",
            role: .general, symbol: "slider.horizontal.3",
            termLabel: "6~36개월", payLabel: "자유식 월 1만~300만원",
            rateLabel: "최고 연 3.50~3.55% (세전)",
            expectedRate: 3.0, maxRate: 3.55,
            appCopy: "월급날 자동저축과 실제로 지킬 수 있는 우대조건만 골라 목표에 맞춰 모아요.",
            benefits: [
                RateLine(area: "우대 선택", value: "최고 연 0.6%p", condition: "9개 항목 중 6개 선택, 충족 항목당 0.1%p"),
                RateLine(area: "거래 항목", value: "급여·카드·자동이체", condition: "KB국민카드 결제계좌, 자동저축 등"),
                RateLine(area: "관계 항목", value: "첫 거래·장기거래", condition: "청약 보유, 소중한 날 등 선택"),
            ],
            cautions: [
                "선택한 우대조건은 급여·KB카드·자동이체 등 실제 거래로 충족해야 해요.",
                "중도해지하면 우대금리가 적용되지 않아요.",
                "기간·적립방식에 따라 기본·최고금리가 달라져요.",
            ],
            url: "https://obank.kbstar.com/quics?cc=b061496%3Ab061645&page=C016613&%EB%B8%8C%EB%9E%9C%EB%93%9C%EC%83%81%ED%92%88%EC%BD%94%EB%93%9C=DP01000821"
        ),
        SavingsProduct(
            id: "star-deposit", name: "KB Star 정기예금",
            role: .lump, symbol: "banknote",
            termLabel: "1~36개월", payLabel: "100만원 이상 · 추가입금 불가",
            rateLabel: "연 2.40~2.90% (세전)",
            expectedRate: 2.9, maxRate: 2.9,
            appCopy: "당분간 쓰지 않을 목돈은 생활비와 분리해 정해진 기간 동안 굴려요.",
            benefits: [
                RateLine(area: "최고 구간", value: "연 2.90%", condition: "12개월 이상 24개월 미만"),
                RateLine(area: "분할인출", value: "최대 3회", condition: "가입 1개월 후, 잔액 100만원 이상 유지"),
                RateLine(area: "만기관리", value: "자동해지·재예치", condition: "신규 시 선택"),
            ],
            cautions: [
                "목표일 전에 쓸 가능성이 높은 자금에는 맞지 않아요.",
                "중도해지 시 계약이율보다 낮은 이율이 적용돼요.",
            ],
            url: "https://obank.kbstar.com/quics?cc=b061496%3Ab061645&isNew=Y&page=C016613&prcode=DP01000938"
        ),
        SavingsProduct(
            id: "youth-future", name: "KB청년미래적금",
            role: .policy, symbol: "sparkles",
            termLabel: "36개월", payLabel: "월 1천원~50만원 (연 600만원)",
            rateLabel: "기본 연 5.0% · 최고 연 8.0% (세전) + 정부기여금 별도",
            expectedRate: 5.0, maxRate: 8.0,
            statusNote: "2026.07.21 기준 신규 자격신청 종료 — 사전 승인자만 7/27~8/7 계좌 개설 가능",
            appCopy: "자격과 가입기간을 확인했어요. 3년 유지가 가능할 때 정부기여금까지 함께 비교해요.",
            benefits: [
                RateLine(area: "급여이체", value: "연 1.0%p", condition: "지정 기간 중 급여 입금 월수"),
                RateLine(area: "출금실적", value: "연 0.8%p", condition: "공과금·Liiv M·KB카드 출금 중 하나"),
                RateLine(area: "정부기여금", value: "6~12% 매칭", condition: "금리와 별개 혜택 — 합산 표기 금지"),
            ],
            cautions: [
                "만 19~34세 + 소득·가구소득·금융소득 요건의 자격조회가 필요해요.",
                "전 금융기관 1인 1계좌이고 청년희망적금·도약계좌 보유 제한이 있어요.",
                "일반 중도해지는 정부기여금·비과세를 받을 수 없어요.",
            ],
            url: "https://obank.kbstar.com/quics?cc=b061496%3Ab061645&isNew=Y&page=C016613&prcode=DP01001656"
        ),
        SavingsProduct(
            id: "dream", name: "청년 주택드림 청약통장",
            role: .housing, symbol: "house",
            termLabel: "장기 (가입 ~2028.12.31)", payLabel: "회차당 2만~100만원",
            rateLabel: "24개월 기준 연 3.1~4.5% (정부고시 변동)",
            expectedRate: 3.1, maxRate: 4.5,
            appCopy: "집 마련이 실제 목표라면 단기 금리보다 청약 자격과 장기 납입을 먼저 준비해요.",
            benefits: [
                RateLine(area: "청년 우대", value: "최고 연 4.5%", condition: "2년 이상·무주택, 원금 5천만원 한도"),
                RateLine(area: "비과세", value: "별도 요건", condition: "이자소득 500만원, 연 납입 600만원 한도"),
                RateLine(area: "일부인출", value: "1회", condition: "청약 당첨 후 계약금 목적"),
            ],
            cautions: [
                "예금자보호법 대상이 아니에요 — 주택도시기금 재원으로 정부가 관리해요.",
                "전 금융기관 청약상품 합산 1인 1계좌예요.",
                "가입 2년 미만 일반해지 시 청년 우대이율을 못 받을 수 있어요.",
            ],
            url: "https://obank.kbstar.com/quics?cc=b061496%3Ab061645&isNew=N&page=C016613&prcode=DP01000935"
        ),
    ]
}
