import CoreFoundation
import Foundation

/// Only newly answered questions are included. An explicit false is a saved answer.
struct ReleaseAgeRatingCorrection: Codable, Equatable, Sendable {
    let declarationID: String
    let sharedLocation: Bool?
    let datingAndRelationships: Bool?

    enum CodingKeys: String, CodingKey {
        case declarationID = "declarationId", sharedLocation, datingAndRelationships
    }

    /// V2 journals store the digest of the entire document. Reconstruct the
    /// possible earlier documents in memory, leaving all other content intact.
    static func priorFingerprints(in document: [String: Any], digest: ([String: Any]) throws -> String) throws
        -> [String: Self] {
        guard let infos = document["appInfos"] as? [[String: Any]] else { return [:] }
        typealias Entry = (index: Int, rating: [String: Any], attributes: [String: Any])
        var occurrences: [String: [Entry]] = [:]
        for (index, info) in infos.enumerated() {
            guard let rating = info["ageRating"] as? [String: Any],
                  rating["type"] as? String == "ageRatingDeclarations",
                  let id = rating["id"] as? String, ReleaseWorkflowTarget.validID(id) else { continue }
            occurrences[id, default: []].append((index, rating, rating["attributes"] as? [String: Any] ?? [:]))
        }

        var matches: [String: Self] = [:]
        for (id, entries) in occurrences {
            guard let first = entries.first,
                  let location = boolean(first.attributes["sharedLocation"]),
                  let dating = boolean(first.attributes["datingAndRelationships"]),
                  entries.allSatisfy({ boolean($0.attributes["sharedLocation"]) == location
                      && boolean($0.attributes["datingAndRelationships"]) == dating }) else { continue }

            // Apple can serialize each unanswered question as null or omit it.
            // The third possibility is that an answer was already present.
            let locationValues: [Any?] = [nil, NSNull(), location]
            let datingValues: [Any?] = [nil, NSNull(), dating]
            for oldLocation in locationValues {
                for oldDating in datingValues {
                    let locationChanged = boolean(oldLocation) == nil
                    let datingChanged = boolean(oldDating) == nil
                    guard locationChanged || datingChanged else { continue }
                    var priorInfos = infos
                    for entry in entries {
                        var prior = entry.attributes
                        prior["sharedLocation"] = oldLocation
                        prior["datingAndRelationships"] = oldDating
                        var priorRating = entry.rating
                        priorRating["attributes"] = prior
                        priorInfos[entry.index]["ageRating"] = priorRating
                    }
                    var priorDocument = document
                    priorDocument["appInfos"] = priorInfos
                    matches[try digest(priorDocument)] = Self(declarationID: id,
                        sharedLocation: locationChanged ? location : nil,
                        datingAndRelationships: datingChanged ? dating : nil)
                }
            }
        }
        return matches
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
