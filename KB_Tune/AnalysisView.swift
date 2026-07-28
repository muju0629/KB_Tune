//
//  AnalysisView.swift
//  KB_Tune
//
//  7월 캘린더 예상 지출 + 선택적으로 올린 결제 캡처 분석.
//  상품 추천은 이 화면 '맨 아래'에서만 낮은 강조로 진입(제품 원칙 4).
//

import SwiftUI
import PhotosUI
import UIKit

/// 지출 묶음 한 줄 — 이미 쓴 돈(spent)과 앞으로 예상되는 돈(upcoming)을 함께 담는다.
private struct SpendBucket: Identifiable {
    let name: String
    let symbol: String
    var spent = 0
    var upcoming = 0
    var detail: String? = nil   // 구독료처럼 안에 뭐가 들었는지 한 줄 설명
    var id: String { name }
    var total: Int { spent + upcoming }
}

struct AnalysisView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = ImageStore()

    @State private var picks: [PhotosPickerItem] = []
    @State private var isImporting = false

    // 앞으로 예상되는(아직 안 쓴) 지출 색 — 짙은 회색
    private let upcomingTint = KB.ink.opacity(0.62)

    // 캡처 → 거래 추출 상태
    @State private var isExtracting = false
    @State private var extracted: ExtractResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                title
                uploadSection
                if !store.shots.isEmpty { extractSection }
                breakdownSection
                insight
                productEntry
            }
            .padding(20)
        }
        .background(KB.canvas)
    }

    /// 좌우로 넘기는 페이지형 탭 안에서는 NavigationStack을 두지 않는다.
    /// 페이지를 넘기는 도중 내비게이션 바가 다시 배치되면서 UIKit이 스스로 죽는 일이 있다.
    /// 여기서 필요한 건 제목 한 줄뿐이라 그냥 텍스트로 그린다.
    private var title: some View {
        Text("소비 분석")
            .font(.kb(17, .semibold))
            .foregroundStyle(KB.ink)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    // MARK: 업로드

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("소비 데이터 올리기").font(.kb(16, .semibold)).foregroundStyle(KB.ink)
                Text("결제 캡처가 있으면 일정의 예상 금액과 비교할 수 있어요. 이미지는 기기에만 보관돼요.")
                    .font(.kb(12.5)).foregroundStyle(KB.muted).lineSpacing(2)
            }

            PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .images) {
                HStack(spacing: 8) {
                    if isImporting { ProgressView().tint(KB.ink) }
                    else { Image(systemName: "photo.badge.plus").font(.system(size: 16, weight: .medium)) }
                    Text(isImporting ? "불러오는 중…" : "캡처 이미지 올리기")
                        .font(.kb(14, .semibold))
                }
                .foregroundStyle(KB.ink)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(KB.yellowSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.yellow, lineWidth: 1))
            }
            .onChange(of: picks) { _, items in importPicks(items) }

            if store.shots.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray").foregroundStyle(KB.muted)
                    Text("아직 올린 캡처가 없어요.").font(.kb(12.5)).foregroundStyle(KB.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
                .background(KB.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.shots) { shot in thumbnail(shot) }
                    }
                }
                Text("저장된 캡처 \(store.shots.count)장 · 최근 \(ImageStore.maxShots)장까지 보관")
                    .font(.kb(11.5)).foregroundStyle(KB.muted)
            }
        }
    }

    private func thumbnail(_ shot: UploadedShot) -> some View {
        Image(uiImage: shot.image)
            .resizable().scaledToFill()
            .frame(width: 84, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(KB.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button { store.delete(shot) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.kb(18))
                        .foregroundStyle(.white, KB.ink.opacity(0.6))
                }
                .padding(4)
            }
    }

    private func importPicks(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    images.append(img)
                }
            }
            store.add(images)
            picks = []
            isImporting = false
        }
    }

    // MARK: 캡처 → 거래 추출 (온디바이스 OCR + 구조화)

    private var extractSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                runExtraction()
            } label: {
                HStack(spacing: 8) {
                    if isExtracting { ProgressView().tint(KB.ink) }
                    else { Image(systemName: "doc.text.viewfinder").font(.system(size: 16, weight: .medium)) }
                    Text(isExtracting ? "캡처를 읽는 중…" : "캡처에서 거래 읽기")
                        .font(.kb(14, .semibold))
                }
                .foregroundStyle(KB.onYellow)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(KB.yellow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isExtracting)

            if let result = extracted {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("읽어낸 거래 \(result.transactions.count)건")
                            .font(.kb(13, .semibold)).foregroundStyle(KB.ink)
                        Spacer()
                        Text(sourceLabel(result.method))
                            .font(.kb(10.5, .medium)).foregroundStyle(KB.muted)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(KB.line.opacity(0.45), in: Capsule())
                    }

                    ForEach(Array(result.transactions.enumerated()), id: \.offset) { _, tx in
                        HStack(spacing: 10) {
                            IconBadge(systemName: symbol(for: tx.category),
                                      background: tx.category == "기타" ? KB.line.opacity(0.4) : KB.greenSoft,
                                      size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tx.merchant).font(.kb(13.5, .medium))
                                    .foregroundStyle(KB.ink).lineLimit(1)
                                Text(tx.category).font(.kb(11.5)).foregroundStyle(KB.muted)
                            }
                            Spacer()
                            Text(formatWon(tx.amount)).font(.kb(13.5, .semibold))
                                .foregroundStyle(KB.ink)
                        }
                        .padding(.vertical, 2)
                    }

                    if !result.transactions.isEmpty {
                        Divider().overlay(KB.line)
                        HStack {
                            Text("합계").font(.kb(13, .medium)).foregroundStyle(KB.muted)
                            Spacer()
                            Text(formatWon(result.total)).font(.kb(15, .bold))
                                .foregroundStyle(KB.ink)
                        }
                    }

                    ForEach(result.warnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(KB.muted)
                            Text(w).font(.kb(11.5)).foregroundStyle(KB.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KB.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
                .transition(.opacity)
            }
        }
    }

    private func sourceLabel(_ method: String) -> String {
        switch method {
        case "on-device": "기기에서 처리"
        case "ocr-rule": "기기 OCR + 서버 구조화"
        case "llm-vision": "이미지 분석"
        default: method
        }
    }

    private func symbol(for category: String) -> String {
        switch category {
        case "카페": "cup.and.saucer"
        case "외식": "fork.knife"
        case "배달": "bag"
        case "술·모임": "wineglass"
        case "쇼핑": "handbag"
        case "교통": "bus"
        case "구독": "play.rectangle"
        case "여가", "문화": "film"
        case "출근": "briefcase"
        case "데이트": "heart"
        case "가족": "house"
        case "경조사": "gift"
        case "자기관리", "건강": "cross.case"
        default: "questionmark.circle"
        }
    }

    /// 온디바이스 Vision OCR → 온디바이스 규칙 파서
    ///
    /// 한 번 읽은 캡처는 결과를 캐시해 두고 다시 읽지 않는다. 예전에는 누를 때마다
    /// 저장된 전체를 다시 OCR해서, 캡처가 쌓일수록 느려지고 서버로 보내는 글자 수도 함께 늘었다.
    private func runExtraction() {
        isExtracting = true
        let shots = store.shots
        Task {
            var texts: [String] = []
            for shot in shots {
                if let cached = store.cachedText(for: shot.id) {
                    texts.append(cached)
                    continue
                }
                let image = shot.image
                let text = await Task.detached { OCRService.recognize(image) }.value
                store.cacheText(text, for: shot.id)
                texts.append(text)
            }
            // 원본 이미지뿐 아니라 OCR 원문도 외부로 보내지 않는다. 보관 상한(20장) 안에서
            // 글자가 유난히 많은 캡처가 섞여도 메모리 사용이 튀지 않게 최근 것 위주로 자른다.
            let text = String(texts.joined(separator: "\n").suffix(19_000))
            let result = LocalExtractor.parse(text)
            withAnimation(.snappy(duration: 0.25)) {
                extracted = result
                isExtracting = false
            }
        }
    }

    // MARK: 7월 지출 — 필수/기타로 묶고, 이미 쓴 돈과 앞으로 예상되는 돈을 색으로 나눈다

    /// 성제 페르소나의 7월 실제 지출을 손으로 정리한 데모 값.
    /// spent = 이미 쓴 돈(노랑), upcoming = 앞으로 예상되는 돈(짙은 회색).
    private var essentialBuckets: [SpendBucket] {
        [
            SpendBucket(name: "식비", symbol: "fork.knife", spent: 250_000, upcoming: 100_000),
            SpendBucket(name: "교통", symbol: "bus", spent: 150_000),
            SpendBucket(name: "유류비", symbol: "fuelpump", spent: 80_000),
            SpendBucket(name: "통신비", symbol: "antenna.radiowaves.left.and.right", spent: 75_000),
            SpendBucket(name: "구독료", symbol: "play.rectangle", spent: 92_000,
                        detail: "유튜브·클로드·코덱스·iCloud 2TB·쿠팡"),
            SpendBucket(name: "보험료", symbol: "checkmark.shield", spent: 30_000),
            SpendBucket(name: "병원", symbol: "cross.case", spent: 150_000),
        ]
    }

    private var discretionaryBuckets: [SpendBucket] {
        [
            SpendBucket(name: "데이트", symbol: "heart", spent: 130_000, upcoming: 70_000),
            SpendBucket(name: "쇼핑", symbol: "handbag", spent: 180_000),
            SpendBucket(name: "친목", symbol: "person.2", spent: 165_000),
            SpendBucket(name: "경조사", symbol: "rosette", spent: 70_000),
            SpendBucket(name: "문화", symbol: "film", spent: 60_000),
        ]
    }

    private var breakdownSection: some View {
        let essential = essentialBuckets.filter { $0.total > 0 }
        let discretionary = discretionaryBuckets.filter { $0.total > 0 }
        let maxTotal = max((essential + discretionary).map(\.total).max() ?? 1, 1)
        let grandTotal = (essential + discretionary).reduce(0) { $0 + $1.total }
        let upcomingTotal = (essential + discretionary).reduce(0) { $0 + $1.upcoming }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("7월 지출").font(.kb(16, .semibold)).foregroundStyle(KB.ink)
                Spacer()
                Text("합계 약 \(formatWon(grandTotal))").font(.kb(12.5)).foregroundStyle(KB.muted)
            }

            HStack(spacing: 14) {
                legendDot(KB.yellow, "지출 완료")
                legendDot(upcomingTint, "예상")
                Spacer()
            }

            groupCard("필수 지출", items: essential, maxTotal: maxTotal)
            groupCard("기타 지출", items: discretionary, maxTotal: maxTotal)

            Text(upcomingTotal > 0
                 ? "짙은 회색이 앞으로 나갈 것으로 보이는 \(formatWon(upcomingTotal))이에요."
                 : "이번 달 예상 지출을 필수와 기타로 나눠 봤어요.")
                .font(.kb(11.5)).foregroundStyle(KB.muted)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.kb(11.5)).foregroundStyle(KB.muted)
        }
    }

    private func groupCard(_ title: String, items: [SpendBucket], maxTotal: Int) -> some View {
        let total = items.reduce(0) { $0 + $1.total }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.kb(14, .bold)).foregroundStyle(KB.ink)
                Spacer()
                Text(formatWon(total)).font(.kb(13, .semibold)).foregroundStyle(KB.muted)
            }
            ForEach(items) { item in bucketRow(item, maxTotal: maxTotal) }
        }
        .padding(16)
        .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func bucketRow(_ item: SpendBucket, maxTotal: Int) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: item.symbol, background: KB.greenSoft, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name).font(.kb(14, .medium)).foregroundStyle(KB.ink)
                    Spacer()
                    if item.upcoming > 0 {
                        Text("예상 +\(formatWon(item.upcoming))")
                            .font(.kb(10.5, .medium)).foregroundStyle(upcomingTint)
                    }
                    Text(formatWon(item.total)).font(.kb(13, .semibold)).foregroundStyle(KB.ink)
                }
                if let detail = item.detail {
                    Text(detail).font(.kb(10.5)).foregroundStyle(KB.muted)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                GeometryReader { geo in
                    let scale = geo.size.width / CGFloat(maxTotal)
                    ZStack(alignment: .leading) {
                        Capsule().fill(KB.line.opacity(0.4)).frame(height: 6)
                        HStack(spacing: 0) {
                            Rectangle().fill(KB.yellow).frame(width: max(0, CGFloat(item.spent) * scale))
                            Rectangle().fill(upcomingTint).frame(width: max(0, CGFloat(item.upcoming) * scale))
                        }
                        .frame(height: 6)
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                }
                .frame(height: 6)
            }
        }
    }

    private var insight: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(KB.yellow).frame(width: 40, height: 40)
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(KB.onYellow)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("이번 달은 식비와 병원비가 크게 나갔어요.").font(.kb(14, .semibold)).foregroundStyle(KB.ink)
                Text("식비·교통·통신·병원처럼 꼭 나가는 돈은 필수 지출로 묶었어요. 짙은 회색은 아직 안 썼지만 앞으로 나갈 것으로 보이는 지출이라, 어디서 더 쓰게 될지 미리 볼 수 있어요.")
                    .font(.kb(13)).foregroundStyle(KB.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    // MARK: 상품 진입 (맨 아래 · 낮은 강조)

    private var productEntry: some View {
        VStack(spacing: 8) {
            Button { model.selectedTab = .products } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15))
                    Text("확인한 지출로 카드·적금 비교하기").font(.kb(14, .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13))
                }
                .foregroundStyle(KB.ink)
                .padding(16)
                .background(KB.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("캘린더 예상액은 카드 전월실적과 다를 수 있어요.")
                .font(.kb(11.5)).foregroundStyle(KB.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 4)
    }
}

#Preview {
    AnalysisView().environmentObject(AppModel())
}
