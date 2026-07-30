//
//  TuneAudit.swift
//  KB_Tune
//
//  점수 판단과 사용자 승인·거절을 기기 안에 남기는 최소 감사 로그.
//

import Foundation

struct TuneAuditEntry: Codable, Equatable, Identifiable {
    enum Event: String, Codable {
        case alertAcknowledged, adjustmentApproved, adjustmentRejected
    }

    var id = UUID()
    let timestamp: Date
    let event: Event
    let fingerprint: String?
    let candidateID: String?
    let label: String
    let scoreBefore: Int
    let scoreAfter: Int?
    let reasonCodes: [String]
    let evidenceIDs: [String]
    var modelVersion: String? = nil
    var featureVersion: String? = nil
}
