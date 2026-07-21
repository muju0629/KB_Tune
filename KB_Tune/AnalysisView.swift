//
//  AnalysisView.swift
//  KB_Tune
//
//  소비 분석. 토스·카드앱 캡처 업로드(저장) + 최근 3개월 소비 분석.
//  상품 추천은 이 화면 '맨 아래'에서만 낮은 강조로 진입(제품 원칙 4).
//

import SwiftUI
import PhotosUI
import UIKit

struct AnalysisView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = ImageStore()

    @StateObject private var agent = AgentService()
    @State private var picks: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var showProducts = false

    // 캡처 → 거래 추출 상태
    @State private var isExtracting = false
    @State private var extracted: ExtractResponse?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    uploadSection
                    if !store.shots.isEmpty { extractSection }
                    breakdownSection
                    insight
                    productEntry
                }
                .padding(20)
            }
            .background(KB.canvas)
            .navigationTitle("소비 분석")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showProducts) { ProductsSheet().environmentObject(model) }
    }

    // MARK: 업로드

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("소비 데이터 올리기").font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.ink)
                Text("토스·카드앱에서 캡처한 소비 내역을 올리면 저장하고 분석에 활용해요. 이미지는 기기에만 보관돼요.")
                    .font(.system(size: 12.5)).foregroundStyle(KB.muted).lineSpacing(2)
            }

            PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .images) {
                HStack(spacing: 8) {
                    if isImporting { ProgressView().tint(KB.ink) }
                    else { Image(systemName: "photo.badge.plus").font(.system(size: 16, weight: .medium)) }
                    Text(isImporting ? "불러오는 중…" : "캡처 이미지 올리기")
                        .font(.system(size: 14, weight: .semibold))
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
                    Text("아직 올린 캡처가 없어요.").font(.system(size: 12.5)).foregroundStyle(KB.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
                .background(KB.line.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.shots) { shot in thumbnail(shot) }
                    }
                }
                Text("저장된 캡처 \(store.shots.count)장").font(.system(size: 11.5)).foregroundStyle(KB.muted)
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
                        .font(.system(size: 18))
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
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(KB.ink)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(KB.yellow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isExtracting)

            if let result = extracted {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("읽어낸 거래 \(result.transactions.count)건")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                        Spacer()
                        Text(sourceLabel(result.method))
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(KB.muted)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(KB.line.opacity(0.45), in: Capsule())
                    }

                    ForEach(Array(result.transactions.enumerated()), id: \.offset) { _, tx in
                        HStack(spacing: 10) {
                            IconBadge(systemName: symbol(for: tx.category),
                                      background: tx.category == "기타" ? KB.line.opacity(0.4) : KB.greenSoft,
                                      size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tx.merchant).font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(KB.ink).lineLimit(1)
                                Text(tx.category).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                            }
                            Spacer()
                            Text(formatWon(tx.amount)).font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(KB.ink)
                        }
                        .padding(.vertical, 2)
                    }

                    if !result.transactions.isEmpty {
                        Divider().overlay(KB.line)
                        HStack {
                            Text("합계").font(.system(size: 13, weight: .medium)).foregroundStyle(KB.muted)
                            Spacer()
                            Text(formatWon(result.total)).font(.system(size: 15, weight: .bold))
                                .foregroundStyle(KB.ink)
                        }
                    }

                    ForEach(result.warnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(KB.muted)
                            Text(w).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
                .transition(.opacity)
            }
        }
    }

    private func sourceLabel(_ method: String) -> String {
        switch method {
        case "on-device": "기기에서 처리"
        case "ocr-rule": "기기 OCR + 서버 구조화"
        case "llm-vision": "AI 비전 분석"
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
        case "여가": "film"
        default: "questionmark.circle"
        }
    }

    /// 온디바이스 Vision OCR → 백엔드 구조화(실패 시 로컬 파서)
    private func runExtraction() {
        isExtracting = true
        let images = store.shots.map(\.image)
        Task {
            let text = await Task.detached { OCRService.recognizeAll(images) }.value
            var result = await agent.extract(text: text)
            if result == nil { result = LocalExtractor.parse(text) }   // 백엔드 없어도 동작
            withAnimation(.snappy(duration: 0.25)) {
                extracted = result
                isExtracting = false
            }
        }
    }

    // MARK: 소비 분석

    private var breakdownSection: some View {
        let sorted = model.spendProfile.sorted { $0.total3m > $1.total3m }
        let maxTotal = sorted.first?.total3m ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("최근 3개월 소비").font(.system(size: 16, weight: .semibold)).foregroundStyle(KB.ink)
                Spacer()
                Text("월 평균 \(formatWon(model.spendMonthly))").font(.system(size: 12.5)).foregroundStyle(KB.muted)
            }

            VStack(spacing: 12) {
                ForEach(sorted) { cat in
                    HStack(spacing: 12) {
                        IconBadge(systemName: cat.symbol, background: KB.greenSoft, size: 38)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(cat.name).font(.system(size: 14, weight: .medium)).foregroundStyle(KB.ink)
                                Spacer()
                                Text(formatWon(cat.total3m)).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(KB.line.opacity(0.5)).frame(height: 6)
                                    Capsule().fill(KB.yellow)
                                        .frame(width: geo.size.width * CGFloat(cat.total3m) / CGFloat(maxTotal), height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
            .padding(16)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
        }
    }

    private var insight: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(KB.yellow).frame(width: 40, height: 40)
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(KB.ink)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("외식·모임 지출이 가장 커요.").font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                Text("지키고 싶은 소비라 유지하되, 카드 혜택으로 그 지출의 일부를 돌려받을 수 있어요.")
                    .font(.system(size: 13)).foregroundStyle(KB.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    // MARK: 상품 진입 (맨 아래 · 낮은 강조)

    private var productEntry: some View {
        VStack(spacing: 8) {
            Button { showProducts = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15))
                    Text("이 소비에 맞는 카드·적금 알아보기").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13))
                }
                .foregroundStyle(KB.ink)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("계획을 세운 뒤 참고하는 선택 항목이에요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 4)
    }
}

#Preview {
    AnalysisView().environmentObject(AppModel())
}
