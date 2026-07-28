//
//  SafariSheet.swift
//  KB_Tune
//
//  KB 공식 상품 페이지를 앱 안에서 연다.
//
//  Link 로 열면 Safari 로 튕겨 나가서, 돌아오려면 앱을 다시 찾아 들어와야 한다.
//  시연 중에 흐름이 끊기는 자리다. 시스템 브라우저를 시트로 띄우면 '완료'로 바로 돌아온다.
//  주소창이 그대로 보이므로 어디로 가는지 감추지도 않는다.
//

import SafariServices
import SwiftUI

/// sheet(item:) 은 Identifiable 을 요구하는데 URL 은 아니다. 얇게 감싸서 넘긴다.
struct WebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(KB.ink)
        vc.preferredBarTintColor = UIColor(KB.canvas)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
