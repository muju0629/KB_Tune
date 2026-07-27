//
//  OCRService.swift
//  KB_Tune
//
//  AI 기능 ② 앱 절반 — 캡처 이미지에서 텍스트 인식(온디바이스).
//  Apple Vision 프레임워크: 무료·오프라인·서버 불필요. 한국어 인식 지원.
//  인식된 텍스트는 백엔드 /api/extract 가 거래로 구조화하고,
//  백엔드가 없으면 아래 LocalExtractor 가 같은 규칙으로 대신 파싱한다.
//

import Foundation
import UIKit
import Vision

// MARK: - 추출 결과 모델 (백엔드 응답과 동일 스키마)

struct ExtractedTx: Codable {
    let merchant: String
    let amount: Int
    let category: String
    let confidence: Double
}

struct ExtractResponse: Codable {
    let transactions: [ExtractedTx]
    let total: Int
    let method: String          // ocr-rule | llm-vision | on-device
    let warnings: [String]
}

// MARK: - 온디바이스 OCR

enum OCRService {

    /// 이미지 → 텍스트(줄 단위). 백그라운드에서 호출할 것.
    nonisolated static func recognize(_ image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false          // 가맹점명·숫자를 원문 그대로
        request.recognitionLanguages = ["ko-KR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return "" }

        return reconstructRows(request.results ?? [])
    }

    /// 거래 화면은 "가맹점 …… 금액"이 좌우로 떨어져 있어 **별개 observation**으로 잡힌다.
    /// Y좌표가 겹치는 것들을 한 행으로 묶고 좌→우로 이어붙여 원래 줄을 복원한다.
    /// (이 처리가 없으면 가맹점 줄과 금액 줄이 분리돼 파서가 아무것도 못 뽑는다)
    nonisolated static func reconstructRows(_ observations: [VNRecognizedTextObservation]) -> String {
        // Vision 좌표는 좌하단 원점 → midY 내림차순이 화면 위→아래 순서
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var rows: [[VNRecognizedTextObservation]] = []
        for o in sorted {
            if let ref = rows.last?.first {
                let tolerance = max(ref.boundingBox.height, o.boundingBox.height) * 0.6
                if abs(ref.boundingBox.midY - o.boundingBox.midY) <= tolerance {
                    rows[rows.count - 1].append(o)
                    continue
                }
            }
            rows.append([o])
        }

        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

// MARK: - 로컬 파서 (백엔드 없을 때 폴백 · 백엔드와 동일 규칙)

enum LocalExtractor {

    private static let noise = ["잔액", "합계", "총액", "누적", "포인트", "적립", "한도", "이월", "출금가능"]

    private static let rules: [(String, [String])] = [
        ("카페", ["스타벅스", "스벅", "투썸", "이디야", "메가", "빽다방", "할리스", "커피", "카페", "컴포즈"]),
        ("배달", ["배달의민족", "배민", "요기요", "쿠팡이츠", "배달"]),
        ("술·모임", ["포차", "이자카야", "호프", "술집", "주점", "맥주", "소주", "펍"]),
        ("외식", ["김밥", "한솥", "맘스터치", "본죽", "식당", "치킨", "피자", "버거", "맥도날드", "분식", "국밥", "떡볶이"]),
        ("쇼핑", ["올리브영", "다이소", "무신사", "쿠팡", "지마켓", "백화점", "이마트", "홈플러스", "GS25", "CU", "세븐일레븐", "편의점", "마트"]),
        ("교통", ["티머니", "택시", "카카오T", "지하철", "버스", "코레일", "주유"]),
        ("구독", ["넷플릭스", "유튜브", "스포티파이", "왓챠", "티빙", "웨이브", "멤버십"]),
        ("여가", ["CGV", "메가박스", "롯데시네마", "영화", "PC방", "노래방", "볼링"]),
    ]

    static func category(for merchant: String) -> (String, Double) {
        let name = merchant.replacingOccurrences(of: " ", with: "").lowercased()
        for (cat, keys) in rules {
            for k in keys where name.contains(k.replacingOccurrences(of: " ", with: "").lowercased()) {
                return (cat, 0.95)
            }
        }
        return ("기타", 0.35)
    }

    private static let amountRegex = try! NSRegularExpression(
        pattern: "([0-9]{1,3}(?:,[0-9]{3})+|[0-9]{4,7})")

    static func parse(_ text: String) -> ExtractResponse {
        var txs: [ExtractedTx] = []

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !noise.contains(where: { line.contains($0) }) else { continue }

            let ns = line as NSString
            guard let m = amountRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            else { continue }

            let amountStr = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            guard let amount = Int(amountStr), amount >= 500, amount <= 3_000_000 else { continue }

            // 금액·기호·숫자를 지운 나머지를 가맹점명으로
            var merchant = ns.replacingCharacters(in: m.range, with: " ")
            merchant = merchant.replacingOccurrences(of: "[0-9:./\\-–—|()\\[\\]원₩,]",
                                                    with: " ", options: .regularExpression)
            merchant = merchant.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard merchant.count >= 2 else { continue }

            let (cat, conf) = category(for: merchant)
            txs.append(ExtractedTx(merchant: String(merchant.prefix(30)),
                                   amount: amount, category: cat, confidence: conf))
        }

        return ExtractResponse(
            transactions: txs,
            total: txs.reduce(0) { $0 + $1.amount },
            method: "on-device",
            warnings: txs.isEmpty ? ["금액으로 인식되는 줄을 찾지 못했어요. 캡처 범위를 확인해 주세요."] : []
        )
    }
}
