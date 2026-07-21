// 합성 거래내역 캡처를 만들어 Vision OCR + 파서를 검증한다 (macOS CLI)
import AppKit
import Vision

// 1) 토스/카드앱 거래내역 비슷한 이미지를 렌더
let lines = [
    "7월 거래내역",
    "스타벅스 강남R점              -5,600원",
    "배달의민족                   -18,900원",
    "잔액                       1,204,300원",
    "CU 성수점                    -3,200원",
    "포차한잔                    -32,000원",
    "넷플릭스                    -15,000원",
]

let W = 900, H = 60 * lines.count + 60
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
let font = NSFont(name: "AppleSDGothicNeo-Medium", size: 30) ?? NSFont.systemFont(ofSize: 30)
for (i, line) in lines.enumerated() {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    NSAttributedString(string: line, attributes: attrs)
        .draw(at: NSPoint(x: 40, y: CGFloat(H - 70 - i * 60)))
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cg = rep.cgImage else { fatalError("render failed") }

// 2) 앱과 동일한 설정으로 Vision OCR
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
req.recognitionLanguages = ["ko-KR", "en-US"]
try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])

// 같은 행(가맹점 | 금액)을 Y좌표로 묶어 한 줄로 복원 — 앱과 동일 로직
let sortedObs = (req.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
var rows: [[VNRecognizedTextObservation]] = []
for o in sortedObs {
    if let ref = rows.last?.first {
        let tol = max(ref.boundingBox.height, o.boundingBox.height) * 0.6
        if abs(ref.boundingBox.midY - o.boundingBox.midY) <= tol {
            rows[rows.count - 1].append(o); continue
        }
    }
    rows.append([o])
}
let observed = rows.map { row in
    row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "  ")
}

print("=== Vision OCR 인식 결과(행 복원 후) ===")
observed.forEach { print("  \($0)") }

// 3) 앱과 동일한 파서 규칙
let noise = ["잔액", "합계", "총액", "누적", "포인트", "적립", "한도"]
let rules: [(String, [String])] = [
    ("카페", ["스타벅스", "투썸", "이디야", "메가", "커피", "카페"]),
    ("배달", ["배달의민족", "배민", "요기요", "쿠팡이츠", "배달"]),
    ("술·모임", ["포차", "이자카야", "호프", "술집", "주점"]),
    ("쇼핑", ["GS25", "CU", "세븐일레븐", "편의점", "올리브영", "마트"]),
    ("구독", ["넷플릭스", "유튜브", "티빙", "웨이브"]),
]
let re = try! NSRegularExpression(pattern: "([0-9]{1,3}(?:,[0-9]{3})+|[0-9]{4,7})")

print("\n=== 파서 추출 결과 ===")
var total = 0
for line in observed {
    if noise.contains(where: { line.contains($0) }) { continue }
    let ns = line as NSString
    guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
    let amt = Int(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")) ?? 0
    guard amt >= 500, amt <= 3_000_000 else { continue }
    var merchant = ns.replacingCharacters(in: m.range, with: " ")
    merchant = merchant.replacingOccurrences(of: "[0-9:./\\-–—|()\\[\\]원₩,]", with: " ", options: .regularExpression)
    merchant = merchant.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    guard merchant.count >= 2 else { continue }
    let name = merchant.replacingOccurrences(of: " ", with: "")
    var cat = "기타"
    outer: for (c, keys) in rules {
        for k in keys where name.localizedCaseInsensitiveContains(k) { cat = c; break outer }
    }
    total += amt
    print(String(format: "  %-18@ %8d원  [%@]", merchant as NSString, amt, cat))
}
print("  합계: \(total)원")
