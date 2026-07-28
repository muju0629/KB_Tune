//
//  DesignSystem.swift
//  KB_Tune
//
//  디자인 토큰 · 공용 스타일. 기준: spending-agent-design-handoff/02_DESIGN_SYSTEM.md
//

import SwiftUI
import UIKit

/// KB Tune 색상 토큰
///
/// 밝을 때와 어두울 때 두 값을 함께 들고 있다. 노랑만 양쪽이 같다 —
/// 브랜드 색이라 배경이 뒤집혀도 그대로 둔다. 나머지는 어두운 배경에서
/// 대비가 죽지 않도록 한 단계씩 밝힌 값을 쓴다.
enum KB {
    static let yellow = Color(hex: 0xFFCC00)                            // 주요 버튼 · 선택 · 핵심 일정
    static let yellowSoft = Color(light: 0xFFF7CF, dark: 0x453A12)      // 선택 배경 · 약한 강조
    static let ink = Color(light: 0x25241F, dark: 0xF2F0EA)             // 제목 · 주요 숫자 · 아이콘
    static let canvas = Color(light: 0xFBFAF7, dark: 0x161513)          // 기본 화면 배경
    static let surface = Color(light: 0xFFFFFF, dark: 0x222120)         // 배경 위에 떠 있는 카드 면
    static let muted = Color(light: 0x747168, dark: 0xA6A29A)           // 보조 설명 · 메타 정보
    static let line = Color(light: 0xE6E2D8, dark: 0x38352F)            // 구분선 · 목록 경계
    static let green = Color(light: 0x3F8A55, dark: 0x5FB878)           // 목표 유지 · 긍정 결과
    static let greenSoft = Color(light: 0xEEF5EC, dark: 0x1D2C21)       // 아이콘 배경 · 보호 상태
    static let caution = Color(light: 0xB4540A, dark: 0xE08A46)         // 차분한 주의(예산 초과 등) — 오류용 빨강 아님
    static let cautionSoft = Color(light: 0xFBEEE2, dark: 0x3A2716)     // 주의 배경
    static let expenseRed = Color(light: 0xD64545, dark: 0xF07A7A)      // 월간 캘린더 등 지출 금액 표기

    // 노랑 위에 얹는 글자·아이콘. 노랑은 어두울 때도 그대로 밝아서,
    // 여기에 ink를 쓰면 다크에서 글자가 같이 밝아져 대비가 사라진다. 항상 어둡게 고정한다.
    static let onYellow = Color(hex: 0x25241F)

    // 토스트처럼 배경과 글자를 통째로 뒤집는 자리. ink를 배경으로 쓰면
    // 어두울 때 ink가 밝아지면서 흰 글자가 사라지므로 따로 둔다.
    static let inverseSurface = Color(light: 0x25241F, dark: 0xEDEAE3)
    static let onInverse = Color(light: 0xFBFAF7, dark: 0x1A1917)

    // 종이 위에 카드를 얇은 테두리 대신 '깊이'로 띄우는 그림자.
    // 어두울 때는 같은 세기로는 안 보여서 더 짙게 깐다.
    static let cardShadow = Color(lightColor: UIColor(hex: 0x2A2822).withAlphaComponent(0.07),
                                  darkColor: UIColor.black.withAlphaComponent(0.45))

    // KB Pay 3.0의 라벨 뱃지 색. 카테고리를 색으로 먼저 알려주고 제목을 읽게 한다.
    static let violet = Color(light: 0x7A5CF0, dark: 0x9E86FF)      // AI·개인화 (My혜택·KB금융그룹 계열)
    static let tangerine = Color(light: 0xF07C1E, dark: 0xFF9A45)   // 추천·이벤트
    static let info = Color(light: 0x2A72E5, dark: 0x6FA8FF)        // 강조 수치 — KB Pay가 금액 하이라이트에 쓰는 파랑
}

// MARK: - 라벨 뱃지 (KB Pay 3.0 문법)

/// 카드 좌상단에 붙는 컬러 pill. "이게 어떤 종류의 정보인지"를 색으로 먼저 알린다.
struct LabelBadge: View {
    let text: String
    var color: Color = KB.violet
    var filled = true

    var body: some View {
        Text(text)
            .font(.kb(11, .bold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(filled ? color : color.opacity(0.12), in: Capsule())
    }
}

/// D-3 · D-DAY 처럼 남은 날을 세는 뱃지. 결제일·마감일이 임박할수록 색이 올라간다.
struct DDayBadge: View {
    let days: Int

    private var label: String { days == 0 ? "D-DAY" : (days > 0 ? "D-\(days)" : "D+\(-days)") }
    private var tint: Color { days <= 0 ? KB.caution : (days <= 3 ? KB.tangerine : KB.muted) }

    var body: some View {
        Text(label)
            .font(.kb(10, .heavy)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

extension Font {
    /// KB금융그룹 서체(KBFG Text).
    ///
    /// 라이트·미디엄 두 벌만 있어서 굵기를 그 둘로 접는다 —
    /// medium 이상은 전부 Medium, 그 아래는 Light.
    /// 크기는 fixedSize로 넘긴다. 기존 화면이 .system(size:)로 짜여 있어
    /// 본문 크기 설정에 따라 커지지 않는데, 여기서만 커지면 레이아웃이 어긋난다.
    static func kb(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(Self.kbFaceName(for: weight), fixedSize: size)
    }

    private static func kbFaceName(for weight: Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "KBFGText-Medium"
        default: "KBFGText-Light"
        }
    }
}

extension View {
    /// 돈 숫자 — 자릿수를 고정해 값이 바뀔 때 좌우로 흔들리지 않게 한다.
    func money(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        font(.kb(size, weight)).monospacedDigit()
    }

    /// 떠 있는 카드 표면 — 테두리 대신 부드러운 그림자로 종이 위에 띄운다.
    func elevatedCard(_ radius: CGFloat = 18, fill: Color = KB.surface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: KB.cardShadow, radius: 12, x: 0, y: 5)
    }

}

/// 금액이 마지막 구간만 조용히 올라와 자리를 잡는 연출.
///
/// 0부터 굴리면 큰 숫자에서 자릿수가 전부 요동쳐 시끄럽다. 여기선 목표값의 대부분을
/// 이미 표시해 둔 채 남은 몇 %만 움직여서, 눈에 띄지 않게 "방금 계산된 값"이라는
/// 느낌만 남긴다. 굴리는 일은 numericText 전환에 맡기고 직접 프레임을 돌리지 않는다.
struct CountUpWon: View {
    let value: Int
    var size: CGFloat = 30
    var weight: Font.Weight = .bold
    var tint: Color = KB.ink
    /// 시작 지점 — 목표값의 몇 %에서 출발할지. 1에 가까울수록 조용하다.
    var from: Double = 0.94

    @State private var shown: Int?

    var body: some View {
        Text(formatWon(shown ?? value))
            .money(size, weight: weight)
            .foregroundStyle(tint)
            .contentTransition(.numericText())
            .onAppear { settle() }
            .onChange(of: value) { _, _ in settle() }
    }

    private func settle() {
        shown = Int(Double(value) * from)
        withAnimation(.easeOut(duration: 0.55)) { shown = value }
    }
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// 밝을 때와 어두울 때 값을 따로 주는 색. 시스템 설정이 바뀌면 알아서 따라간다.
    init(light: UInt, dark: UInt) {
        self.init(lightColor: UIColor(hex: light), darkColor: UIColor(hex: dark))
    }

    init(lightColor: UIColor, darkColor: UIColor) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }
}

extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 86000 -> "86,000"
func decimalString(_ value: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "ko_KR")
    return f.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// 86000 -> "86,000원"
func formatWon(_ value: Int) -> String {
    decimalString(value) + "원"
}

/// 110000, 160000 -> "110,000~160,000원" — 문장 안에서 쓰는 범위(단위는 뒤에 한 번만).
/// 표·요약 줄은 양쪽에 단위를 붙이는 WeeklyPlanView.formatRange 를 쓴다.
func formatWonRange(_ low: Int, _ high: Int) -> String {
    low == high ? formatWon(low) : decimalString(low) + "~" + formatWon(high)
}

// MARK: - 버튼 스타일

/// 기본 CTA: KB Yellow, 높이 ~52
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kb(16, .semibold))
            .foregroundStyle(KB.onYellow)
            // 라벨이 제목과 금액처럼 좌우로 벌어지는 경우 글자가 둥근 모서리에 닿는다.
            // 가운데 정렬 라벨에는 영향이 없으므로 스타일에서 한 번에 띄운다.
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(KB.yellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: KB.yellow.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 10, x: 0, y: 5)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 보조 CTA: 흰색 + 얇은 회색 테두리
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kb(16, .medium))
            .foregroundStyle(KB.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(KB.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(KB.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 공용 소형 컴포넌트

/// 폭이 모자라면 다음 줄로 넘기는 가로 배치.
/// 페이지형 탭 안에서는 가로 ScrollView가 탭 전환 제스처와 부딪히므로,
/// 넘길 게 있으면 스크롤 대신 줄을 바꾼다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 아이콘 원형 배경 (이벤트 노드 · 상품 행)
struct IconBadge: View {
    let systemName: String
    var background: Color = KB.yellowSoft
    var foreground: Color = KB.ink
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .light))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: Circle())
    }
}
