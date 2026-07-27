//
//  ImageStore.swift
//  KB_Tune
//
//  업로드한 소비 캡처(토스·카드앱 등) 이미지를 기기에 저장/로드.
//  Documents/uploads 에 JPEG로 저장 → 앱을 다시 열어도 유지됨.
//
//  보관 정책: 최근 maxShots 장만 남기고, 캡처마다 OCR 결과를 옆에 캐시해 둔다.
//  캡처는 금융 정보라 무한정 들고 있을 이유가 없고, 텍스트를 한 번 뽑고 나면
//  원본의 쓸모는 "다시 보기" 정도로 줄어든다. 캐시가 있으면 추출할 때마다
//  전체를 다시 읽지 않아도 되므로, 장수가 늘어도 추출 시간이 늘지 않는다.
//

import SwiftUI
import UIKit
import Combine

struct UploadedShot: Identifiable {
    let id: String      // 파일명(확장자 제외)
    let image: UIImage
}

@MainActor
final class ImageStore: ObservableObject {
    @Published private(set) var shots: [UploadedShot] = []

    /// 보관 상한. 20장이면 서버 추출의 글자 수 상한(20,000자)에도 여유 있게 들어간다
    /// — 캡처 한 장의 OCR 결과가 보통 500~800자다.
    static let maxShots = 20

    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("uploads", isDirectory: true)
        // 카드앱·토스 캡처는 금융 정보다. 기본 보호등급(첫 잠금해제 후 접근 가능)으로는
        // 기기가 잠긴 상태에서도 읽히므로, 잠금 중엔 복호화 자체가 안 되는 등급으로 올린다.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        // iCloud·iTunes 백업에서 제외 — 기기 밖으로 나갈 이유가 없는 데이터다.
        var res = URLResourceValues()
        res.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(res)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        shots = files
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } // 파일명 = 타임스탬프 → 시간순
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
                return UploadedShot(id: url.deletingPathExtension().lastPathComponent, image: img)
            }
    }

    func add(_ images: [UIImage]) {
        let base = Int(Date().timeIntervalSince1970 * 1000)
        for (i, img) in images.enumerated() {
            let name = "\(base + i)-\(UUID().uuidString.prefix(4)).jpg"
            let url = dir.appendingPathComponent(name)
            if let data = img.jpegData(compressionQuality: 0.8) {
                // 폴더 등급을 물려받지만, 파일마다 명시해 두면 폴더가 바뀌어도 안 흔들린다.
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
        load()
        prune()
    }

    func delete(_ shot: UploadedShot) {
        remove(id: shot.id)
        load()
    }

    // MARK: OCR 결과 캐시

    private func textURL(_ id: String) -> URL { dir.appendingPathComponent(id + ".txt") }

    /// 이미 읽어둔 OCR 결과. 없으면 nil — 호출부가 그때만 OCR을 돌린다.
    func cachedText(for id: String) -> String? {
        try? String(contentsOf: textURL(id), encoding: .utf8)
    }

    /// OCR 결과를 캡처 옆에 남긴다. 원문 텍스트에도 결제 내역이 들어 있어
    /// 이미지와 같은 보호등급을 건다.
    func cacheText(_ text: String, for id: String) {
        try? Data(text.utf8).write(to: textURL(id), options: [.atomic, .completeFileProtection])
    }

    // MARK: 보관 정책

    /// 상한을 넘은 오래된 캡처를 지운다. 파일명이 타임스탬프라 이름순 = 시간순이다.
    private func prune() {
        guard shots.count > Self.maxShots else { return }
        for shot in shots.prefix(shots.count - Self.maxShots) { remove(id: shot.id) }
        load()
    }

    /// 캡처와 그 OCR 캐시를 함께 지운다 — 텍스트만 남으면 지운 게 아니다.
    private func remove(id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".jpg"))
        try? FileManager.default.removeItem(at: textURL(id))
    }
}
