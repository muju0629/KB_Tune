//
//  ImageStore.swift
//  KB_Tune
//
//  업로드한 소비 캡처(토스·카드앱 등) 이미지를 기기에 저장/로드.
//  Documents/uploads 에 JPEG로 저장 → 앱을 다시 열어도 유지됨.
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
    }

    func delete(_ shot: UploadedShot) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(shot.id + ".jpg"))
        load()
    }
}
