//
//  DesignSystem.swift
//  KB_Tune
//
//  디자인 토큰 · 공용 스타일. 기준: spending-agent-design-handoff/02_DESIGN_SYSTEM.md
//

import SwiftUI

/// KB Tune 색상 토큰
enum KB {
    static let yellow = Color(hex: 0xFFCC00)      // 주요 버튼 · 선택 · 핵심 일정
    static let yellowSoft = Color(hex: 0xFFF7CF)  // 선택 배경 · 약한 강조
    static let ink = Color(hex: 0x25241F)         // 제목 · 주요 숫자 · 아이콘
    static let canvas = Color(hex: 0xFBFAF7)      // 기본 화면 배경
    static let muted = Color(hex: 0x747168)       // 보조 설명 · 메타 정보
    static let line = Color(hex: 0xE6E2D8)        // 구분선 · 목록 경계
    static let green = Color(hex: 0x3F8A55)       // 목표 유지 · 긍정 결과
    static let greenSoft = Color(hex: 0xEEF5EC)   // 아이콘 배경 · 보호 상태
    static let caution = Color(hex: 0xB4540A)     // 차분한 주의(예산 초과 등) — 오류용 빨강 아님
    static let cautionSoft = Color(hex: 0xFBEEE2) // 주의 배경
    static let expenseRed = Color(hex: 0xD64545)  // 월간 캘린더 등 지출 금액 표기

    // 종이 위에 카드를 얇은 테두리 대신 '깊이'로 띄우는 그림자.
    static let cardShadow = Color(hex: 0x2A2822).opacity(0.07)

    // KB Pay 3.0의 라벨 뱃지 색. 카테고리를 색으로 먼저 알려주고 제목을 읽게 한다.
    static let violet = Color(hex: 0x7A5CF0)       // AI·개인화 (My혜택·KB금융그룹 계열)
    static let tangerine = Color(hex: 0xF07C1E)    // 추천·이벤트
    static let info = Color(hex: 0x2A72E5)         // 강조 수치 — KB Pay가 금액 하이라이트에 쓰는 파랑
}

// MARK: - 라벨 뱃지 (KB Pay 3.0 문법)

/// 카드 좌상단에 붙는 컬러 pill. "이게 어떤 종류의 정보인지"를 색으로 먼저 알린다.
struct LabelBadge: View {
    let text: String
    var color: Color = KB.violet
    var filled = true

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
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
            .font(.system(size: 10, weight: .heavy)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

extension View {
    /// 돈 숫자의 정체성 — 따뜻하고 정확한 라운드 숫자(자릿수 고정으로 흔들림 없음).
    /// 한글(원)은 시스템 서체로 자연히 폴백되고, 숫자만 부드러워진다.
    func money(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        font(.system(size: size, weight: weight, design: .rounded)).monospacedDigit()
    }

    /// 떠 있는 카드 표면 — 테두리 대신 부드러운 그림자로 종이 위에 띄운다.
    func elevatedCard(_ radius: CGFloat = 18, fill: Color = .white) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: KB.cardShadow, radius: 12, x: 0, y: 5)
    }

    /// 화면에 들어올 때 순서대로 떠오르는 카드. index가 클수록 조금씩 늦게 나타난다.
    /// 한꺼번에 나타나면 어디부터 읽어야 할지 알 수 없어서, 읽는 순서를 모션으로 안내한다.
    func appearStagger(_ index: Int, base: Double = 0.05) -> some View {
        modifier(StaggerAppear(index: index, base: base))
    }
}

/// 카드 등장 연출 — 살짝 아래에서 떠오르며 페이드인.
struct StaggerAppear: ViewModifier {
    let index: Int
    let base: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)
                    .delay(Double(index) * base)) { shown = true }
            }
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
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(KB.ink)
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
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(KB.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(KB.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 공용 소형 컴포넌트

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
