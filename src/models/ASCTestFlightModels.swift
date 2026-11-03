import Foundation

/// A tester can have no identifying attributes when they joined through a public link.
struct ASCBetaTester: Decodable, Identifiable {
    let id: String
    let attributes: Attributes

    struct Attributes: Decodable {
        var firstName: String? = nil
        var lastName: String? = nil
        var email: String? = nil
        var inviteType: String? = nil
        var state: String? = nil
    }

    private enum CodingKeys: String, CodingKey { case id, attributes }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        attributes = try values.decodeIfPresent(Attributes.self, forKey: .attributes) ?? Attributes()
    }
}

struct ASCBuildBetaDetail: Codable, Identifiable {
    let id: String
    let attributes: Attributes
    struct Attributes: Codable {
        let internalBuildState: String?
        let externalBuildState: String?
        let autoNotifyEnabled: Bool?
    }
    var internalBuildState: String? { attributes.internalBuildState }
    var externalBuildState: String? { attributes.externalBuildState }
}

/// Relationship details stay in memory; tester identities are never persisted in tab caches.
struct ASCTestFlightBuildDetail {
    let build: ASCBuild
    let betaGroups: [ASCBetaGroup]
    let individualTesters: [ASCBetaTester]
}

struct ASCTestFlightGroupDetail {
    let group: ASCBetaGroup
    let builds: [ASCBuild]
    let testers: [ASCBetaTester]
}

/// Tester identities and submitted feedback are private, even in failed request payloads.
enum ASCTestFlightPrivacy {
    static let omittedErrorDescription = "TestFlight request failed; private response omitted from logs."
    static func shouldRedact(path: String) -> Bool {
        let components = URLComponents(string: path)
        let resourcePath = components?.path ?? path
        let privateResources = ["betaTesters", "individualTesters", "betaFeedbackScreenshotSubmissions", "betaFeedbackCrashSubmissions"]
        if resourcePath.split(separator: "/").contains(where: { privateResources.contains(String($0)) }) { return true }
        return components?.queryItems?.contains(where: {
            $0.name == "include" && ($0.value ?? "").split(separator: ",").contains(where: {
                privateResources.contains(String($0)) || $0 == "tester"
            })
        }) == true
    }

    static func bodyForLogging(_ body: Data, path: String) -> Data {
        shouldRedact(path: path) ? Data("<private TestFlight response omitted>".utf8) : body
    }
}
