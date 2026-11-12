import Foundation

/// Persisted before/after each submission boundary. No request bodies, tokens or
/// user-authored metadata belong in this journal.
enum ReleaseSubmissionPhase: String, Codable, Sendable {
    case settingReleaseMode, checkingExisting, creatingSubmission, submissionCreated
    case addingVersion, versionAdded, verifyingContent, submitting, acknowledged
}

struct ReleaseSubmissionProgress: Codable, Equatable, Sendable {
    let phase: ReleaseSubmissionPhase
    var submissionID: String? = nil
    var submissionItemID: String? = nil
    enum CodingKeys: String, CodingKey { case phase, submissionID = "submissionId", submissionItemID = "submissionItemId" }
}

struct ReleaseAppleError: Codable, Equatable, Sendable {
    let httpStatus: Int
    let codes: [String]
    let pointers: [String]

    static func sanitized(status: Int, body: Data) -> ReleaseAppleError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let errors = (object?["errors"] as? [[String: Any]]) ?? []
        // Apple detail/title can quote app metadata or demo credentials. Retain
        // only its machine codes and field pointers, never those free-text values.
        func machine(_ value: String?, allowed: String, limit: Int) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= limit,
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: allowed).contains($0) }) else { return nil }
            return value
        }
        let codes = Set(errors.prefix(20).compactMap {
            machine($0["code"] as? String, allowed: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-", limit: 160)
        }).sorted()
        let pointers = Set(errors.prefix(20).compactMap { error -> String? in
            let pointer = (error["source"] as? [String: Any])?["pointer"] as? String
            guard pointer?.hasPrefix("/") == true else { return nil }
            return machine(pointer, allowed: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_~.-", limit: 200)
        }).sorted()
        return .init(httpStatus: status, codes: codes, pointers: pointers)
    }
}

struct ReleaseSubmissionDiagnostic: Codable, Equatable, Sendable {
    let phase: ReleaseSubmissionPhase?
    let category: String
    var apple: ReleaseAppleError? = nil

    static func make(_ error: Error, phase: ReleaseSubmissionPhase?) -> Self {
        if let apiError = error as? ReleaseWorkflowAPIError {
            switch apiError {
            case .appleResponse(let value):
                return .init(phase: phase, category: (400..<500).contains(value.httpStatus) ? "apple_request_rejected" : "apple_response_unverified", apple: value)
            case .httpStatus(let status):
                return .init(phase: phase, category: (400..<500).contains(status) ? "apple_request_rejected" : "apple_response_unverified",
                             apple: .init(httpStatus: status, codes: [], pointers: []))
            case .invalidResponse: return .init(phase: phase, category: "apple_response_invalid")
            case .validationUnavailable: return .init(phase: phase, category: "validation_unavailable")
            }
        }
        if let workflow = error as? ReleaseWorkflowError {
            switch workflow {
            case .contentChanged: return .init(phase: phase, category: "prepared_content_changed")
            case .identityChanged, .accountChanged, .invalidTarget: return .init(phase: phase, category: "target_changed")
            case .uncertainOutcome: return .init(phase: phase, category: "submission_conflict")
            case .storage: return .init(phase: phase, category: "journal_unavailable")
            default: break
            }
        }
        return .init(phase: phase, category: "request_outcome_unknown")
    }

    var message: String {
        let step = phase?.rawValue ?? "unbekannt"
        let response = apple.map { " HTTP \($0.httpStatus)" + ($0.codes.isEmpty ? "" : " (\($0.codes.joined(separator: ", ")))") } ?? ""
        return "Release-Schritt \(step): \(category).\(response) Der Auftrag bleibt gegen Wiederholung gesperrt; den gespeicherten Status prüfen."
    }
}
