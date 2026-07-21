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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
                try? data.write(to: url)
            }
        }
        load()
    }

    func delete(_ shot: UploadedShot) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(shot.id + ".jpg"))
        load()
    }
}
