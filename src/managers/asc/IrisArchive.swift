import CryptoKit
import Foundation

struct IrisFeedbackProjection: Codable {
    static let currentSchemaVersion = 2
    let appId: String
    let cycles: [IrisFeedbackCycle]
    let lastRebuiltAt: String
    var schemaVersion: Int? = IrisFeedbackProjection.currentSchemaVersion

    var needsRebuild: Bool { schemaVersion != Self.currentSchemaVersion }

    /// Older projections inferred targets from arbitrary message text. If raw
    /// data cannot rebuild them, retain the conversation without preserving
    /// those unverified associations or claiming to know its senders.
    var unassignedLegacyFallback: Self {
        guard needsRebuild else { return self }
        let unassigned = cycles.map { cycle in
            var cycle = cycle
            cycle.versionString = nil
            cycle.submissionId = nil
            cycle.appStoreVersionIDs = nil
            cycle.messages = cycle.messages.map { message in
                var message = message
                message.sender = .unknown
                return message
            }
            return cycle
        }
        return .init(appId: appId, cycles: unassigned, lastRebuiltAt: lastRebuiltAt,
                     schemaVersion: schemaVersion)
    }
}

struct IrisFeedbackCycle: Codable, Identifiable {
    struct Message: Codable, Identifiable {
        enum Sender: String, Codable {
            case apple, developer, unknown
        }

        let id: String
        let body: String
        let createdAt: String?
        var sender: Sender? = nil
    }

    struct Reason: Codable, Identifiable {
        let id: String
        let section: String
        let description: String
        let code: String
    }

    let id: String
    var versionString: String?
    var submissionId: String?
    var occurredAt: String
    var threadCreatedAt: String?
    var lastMessageAt: String?
    var messages: [Message]
    var reasons: [Reason]
    var source: String
    var blobHashes: [String]
    var appStoreVersionIDs: [String]? = nil

    var reviewerMessage: String? {
        let bodies = messages.filter { $0.sender == .apple }.map(\.body).map(trimmed).filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return nil }
        return bodies.joined(separator: "\n\n")
    }

    var guidelineIds: [String] {
        Array(Set(reasons.map(\.code).map(trimmed).filter { !$0.isEmpty })).sorted()
    }

    var primaryReasonSection: String? {
        reasons.map(\.section).map(trimmed).first { !$0.isEmpty }
    }

    // A thread is the stable identity for one App Review feedback cycle.
    static func empty(id: String, occurredAt: String? = nil) -> Self {
        IrisFeedbackCycle(
            id: id,
            versionString: nil,
            submissionId: nil,
            occurredAt: occurredAt ?? irisArchiveNowString(),
            threadCreatedAt: nil,
            lastMessageAt: nil,
            messages: [],
            reasons: [],
            source: "archive",
            blobHashes: []
        )
    }
}

enum IrisArchiveStore {
    // Store the exact server payload once by content hash. The manifest is the
    // only place that tracks when and from which endpoint scope we saw that blob.
    static func recordRawResponse(appId: String, scopeKey: String, data: Data) throws {
        let appDir = archiveDirectory(appId: appId)
        let blobsDir = appDir.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let blobHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let blobURL = rawBlobURL(appId: appId, blobHash: blobHash)
        if !FileManager.default.fileExists(atPath: blobURL.path) {
            try data.write(to: blobURL, options: .atomic)
        }

        var manifest = loadManifest(appId: appId)
        let now = irisArchiveNowString()
        if let index = manifest.entries.firstIndex(where: { $0.scopeKey == scopeKey && $0.blobHash == blobHash }) {
            manifest.entries[index].lastSeenAt = now
            manifest.entries[index].seenCount += 1
        } else {
            manifest.entries.append(
                .init(
                    scopeKey: scopeKey,
                    blobHash: blobHash,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    seenCount: 1
                )
            )
        }
        try saveManifest(manifest, appId: appId)
    }

    static func loadProjection(appId: String) -> IrisFeedbackProjection? {
        let projectionURL = projectionURL(appId: appId)
        let cached = (try? Data(contentsOf: projectionURL))
            .flatMap { try? JSONDecoder().decode(IrisFeedbackProjection.self, from: $0) }
        if let cached, !cached.needsRebuild { return cached }
        let fallback = cached?.unassignedLegacyFallback

        let manifest = loadManifest(appId: appId)
        if !manifest.entries.isEmpty {
            // Sender/target metadata can be recovered from the canonical raw
            // responses even when the old derived cache had discarded it.
            return (try? rebuildProjection(appId: appId)) ?? fallback
        }

        return fallback
    }

    @discardableResult
    static func rebuildProjection(appId: String) throws -> IrisFeedbackProjection {
        let manifest = loadManifest(appId: appId)
        let pages = try manifest.entries.map { entry in
            IrisRawPage(url: entry.scopeKey, data: try Data(contentsOf: rawBlobURL(appId: appId, blobHash: entry.blobHash)))
        }
        let projection = try project(appId: appId, pages: pages)
        try saveProjection(projection, appId: appId)
        return projection
    }

    /// Pure archive projection for both production rebuilds and offline tests.
    /// Malformed pages fail the rebuild; they must never erase a valid cache or
    /// turn an incomplete read into an assertion that there are no messages.
    static func project(appId: String, pages: [IrisRawPage], rebuiltAt: String = irisArchiveNowString()) throws -> IrisFeedbackProjection {
        var cyclesByThreadId: [String: IrisFeedbackCycle] = [:]
        var structuredSubmissionIDs: [String: Set<String>] = [:]
        for entry in pages {
            let data = entry.data
            let blobHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

            // Projection is rebuilt from raw blobs, not incrementally mutated on fetch.
            // That keeps the archive canonical and the derived view disposable.
            if URL(string: entry.url)?.path.hasSuffix("/resolutionCenterThreads") == true {
                let threads = try JSONDecoder().decode(IrisThreadPage.self, from: data).data
                for thread in threads {
                    var cycle = cyclesByThreadId[thread.id] ?? .empty(
                        id: thread.id,
                        occurredAt: thread.attributes.createdDate
                    )
                    if !cycle.blobHashes.contains(blobHash) {
                        cycle.blobHashes.append(blobHash)
                    }
                    if let createdDate = thread.attributes.createdDate {
                        cycle.threadCreatedAt = createdDate
                        cycle.occurredAt = createdDate
                    }
                    if irisArchiveSortDate(thread.attributes.lastMessageResponseDate) > irisArchiveSortDate(cycle.lastMessageAt) {
                        cycle.lastMessageAt = thread.attributes.lastMessageResponseDate
                    }
                    if let relatedVersions = thread.relationships?.appStoreVersions?.data {
                        let IDs = relatedVersions.filter { $0.type == "appStoreVersions" }.map(\.id)
                        cycle.appStoreVersionIDs = Array(Set((cycle.appStoreVersionIDs ?? []) + IDs)).sorted()
                    }
                    if let submission = thread.relationships?.reviewSubmission?.data,
                       submission.type == "reviewSubmissions" {
                        structuredSubmissionIDs[thread.id, default: []].insert(submission.id)
                    }
                    cyclesByThreadId[thread.id] = cycle
                }
                continue
            }

            guard let threadId = threadId(forScopeKey: entry.url) else { continue }
            let page = try JSONDecoder().decode(IrisMessagePage.self, from: data)
            var cycle = cyclesByThreadId[threadId] ?? .empty(id: threadId)
            if !cycle.blobHashes.contains(blobHash) {
                cycle.blobHashes.append(blobHash)
            }

            for message in page.data {
                // Message ids are stable. If we see the same id again, prefer the
                // richer body and otherwise the newest copy.
                let incoming = IrisFeedbackCycle.Message(
                    id: message.id,
                    body: trimmed(htmlToPlainText(message.attributes.messageBody ?? "")),
                    createdAt: message.attributes.createdDate,
                    sender: message.sender
                )
                if let index = cycle.messages.firstIndex(where: { $0.id == incoming.id }) {
                    let existing = cycle.messages[index]
                    let preferIncoming = !trimmed(incoming.body).isEmpty
                        && (trimmed(existing.body).isEmpty
                            || irisArchiveSortDate(incoming.createdAt) >= irisArchiveSortDate(existing.createdAt))
                    let preferred = preferIncoming ? incoming : existing
                    let sender = incoming.sender != .unknown ? incoming.sender : existing.sender
                    cycle.messages[index] = .init(id: preferred.id, body: preferred.body,
                                                  createdAt: preferred.createdAt, sender: sender)
                } else {
                    cycle.messages.append(incoming)
                }
            }
            cycle.messages.sort {
                irisArchiveSortDate($0.createdAt) < irisArchiveSortDate($1.createdAt)
            }

            let included = (page.included ?? []).filter { $0.type == "reviewRejections" }
            for item in included {
                let itemData = try JSONEncoder().encode(item)
                let rejection = try JSONDecoder().decode(IrisReviewRejection.self, from: itemData)
                for (index, reason) in (rejection.attributes.reasons ?? []).enumerated() {
                    // Rejection ids can contain multiple reasons, so reason identity is
                    // "<rejection id>:<reason index>".
                    let incoming = IrisFeedbackCycle.Reason(
                        id: "\(rejection.id):\(index)",
                        section: trimmed(reason.reasonSection),
                        description: trimmed(reason.reasonDescription),
                        code: trimmed(reason.reasonCode)
                    )
                    if let existingIndex = cycle.reasons.firstIndex(where: { $0.id == incoming.id }) {
                        cycle.reasons[existingIndex] = incoming
                    } else {
                        cycle.reasons.append(incoming)
                    }
                }
            }
            cycle.reasons.sort { $0.id < $1.id }

            if cycle.threadCreatedAt == nil,
               let earliestMessageAt = cycle.messages.compactMap(\.createdAt).min(by: { irisArchiveSortDate($0) < irisArchiveSortDate($1) }) {
                cycle.occurredAt = earliestMessageAt
            }
            if let latestMessageAt = cycle.messages.compactMap(\.createdAt).max(by: { irisArchiveSortDate($0) < irisArchiveSortDate($1) }),
               irisArchiveSortDate(latestMessageAt) > irisArchiveSortDate(cycle.lastMessageAt) {
                cycle.lastMessageAt = latestMessageAt
            }
            cyclesByThreadId[threadId] = cycle
        }

        let cycles = cyclesByThreadId.values
            .filter { !$0.messages.isEmpty || !$0.reasons.isEmpty || $0.versionString != nil || $0.submissionId != nil }
            .map { cycle in
                var cycle = cycle
                cycle.blobHashes.sort()
                // A conversation may span several review rounds. Developer
                // replies and conflicting reviewer markers are never a target.
                let appleBodies = cycle.messages.filter { $0.sender == .apple }.map(\.body)
                cycle.versionString = uniqueMatch(in: appleBodies, label: "Version reviewed")
                if let IDs = structuredSubmissionIDs[cycle.id], !IDs.isEmpty {
                    cycle.submissionId = IDs.count == 1 ? IDs.first : nil
                } else {
                    cycle.submissionId = uniqueMatch(in: appleBodies, label: "Submission ID")
                }
                return cycle
            }
            .sorted { irisArchiveSortDate($0.occurredAt) > irisArchiveSortDate($1.occurredAt) }

        return IrisFeedbackProjection(
            appId: appId,
            cycles: cycles,
            lastRebuiltAt: rebuiltAt
        )
    }

    private struct IrisArchiveManifest: Codable {
        let appId: String
        var entries: [Entry]

        struct Entry: Codable {
            let scopeKey: String
            let blobHash: String
            var firstSeenAt: String
            var lastSeenAt: String
            var seenCount: Int
        }
    }

    private struct IrisMessagePage: Decodable {
        let data: [IrisResolutionCenterMessage]
        let included: [IrisIncludedItem]?
    }

    private struct IrisThreadPage: Decodable {
        let data: [Thread]

        struct Thread: Decodable {
            let id: String
            let attributes: Attributes
            let relationships: Relationships?

            struct Attributes: Decodable {
                let createdDate: String?
                let lastMessageResponseDate: String?
            }

            struct Relationships: Decodable {
                let appStoreVersions: ToMany?
                let reviewSubmission: ToOne?

                struct ToMany: Decodable { let data: [Resource]? }
                struct ToOne: Decodable { let data: Resource? }
                struct Resource: Decodable {
                    let type: String
                    let id: String
                }
            }
        }
    }

    // Apple embeds fields like "Submission ID: ..." inside the message body.
    private static func uniqueMatch(in texts: [String], label: String) -> String? {
        var values: Set<String> = []
        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) {
                let stringLine = trimmed(String(line))
                guard let range = stringLine.range(of: "\(label):", options: [.caseInsensitive, .anchored]) else { continue }
                let value = trimmed(String(stringLine[range.upperBound...]))
                if !value.isEmpty { values.insert(value) }
            }
        }
        return values.count == 1 ? values.first : nil
    }

    private static func saveProjection(_ projection: IrisFeedbackProjection, appId: String) throws {
        let url = projectionURL(appId: appId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(projection).write(to: url, options: .atomic)
    }

    private static func loadManifest(appId: String) -> IrisArchiveManifest {
        let url = manifestURL(appId: appId)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(IrisArchiveManifest.self, from: data) else {
            return IrisArchiveManifest(appId: appId, entries: [])
        }
        return manifest
    }

    private static func saveManifest(_ manifest: IrisArchiveManifest, appId: String) throws {
        let url = manifestURL(appId: appId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func archiveDirectory(appId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".blitz/iris-cache-v2/\(appId)")
    }

    private static func rawBlobURL(appId: String, blobHash: String) -> URL {
        archiveDirectory(appId: appId).appendingPathComponent("blobs/\(blobHash).json")
    }

    private static func manifestURL(appId: String) -> URL {
        archiveDirectory(appId: appId).appendingPathComponent("manifest.json")
    }

    private static func projectionURL(appId: String) -> URL {
        archiveDirectory(appId: appId).appendingPathComponent("projection.json")
    }

    private static func threadId(forScopeKey scopeKey: String) -> String? {
        guard let components = URL(string: scopeKey)?.pathComponents,
              let index = components.firstIndex(of: "resolutionCenterThreads"),
              components.indices.contains(index + 2),
              components[index + 2] == "resolutionCenterMessages" else {
            return nil
        }
        return components[index + 1]
    }
}

func trimmed(_ string: String?) -> String {
    (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func irisArchiveNowString() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func irisArchiveDate(_ iso: String?) -> Date? {
    guard let iso, !iso.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let basic = ISO8601DateFormatter()
    return fractional.date(from: iso) ?? basic.date(from: iso)
}

func irisArchiveSortDate(_ iso: String?) -> Date {
    irisArchiveDate(iso) ?? .distantPast
}
