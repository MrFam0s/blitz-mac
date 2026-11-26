import Foundation
import Testing
@testable import Blitz

@MainActor
struct ReleaseAgeRatingFingerprintTests {
    private func document(_ declarations: [(String, [String: Any])], notes: String = "original") -> [String: Any] {
        let infos: [[String: Any]] = declarations.enumerated().map { index, declaration in
            ["id": "info-\(index)", "ageRating": ["type": "ageRatingDeclarations",
                "id": declaration.0, "attributes": declaration.1] as [String: Any]]
        }
        return ["appInfos": infos, "reviewNotes": notes]
    }

    @Test func identifiesOnlyTheNewAnswersForTheSameDeclarationAcrossAppInfos() throws {
        let before: [String: Any] = ["sharedLocation": NSNull(), "gambling": false]
        var after = before
        after["sharedLocation"] = false
        after["datingAndRelationships"] = true
        let original = document([("age", before), ("age", before)])
        let corrected = document([("age", after), ("age", after)])
        let fingerprint = try ReleaseWorkflowASCAdapter.fingerprints(original, checkAgeRatingCorrection: false)
        let current = try ReleaseWorkflowASCAdapter.fingerprints(corrected, checkAgeRatingCorrection: true)
        #expect(current.incompleteAgeRatings[fingerprint.current] ==
            ReleaseAgeRatingCorrection(declarationID: "age", sharedLocation: false, datingAndRelationships: true))
        let partiallyAnswered: [String: Any] = ["sharedLocation": false, "gambling": false]
        let partial = try ReleaseWorkflowASCAdapter.fingerprints(document([("age", partiallyAnswered), ("age", partiallyAnswered)]),
                                                                 checkAgeRatingCorrection: false)
        #expect(current.incompleteAgeRatings[partial.current] ==
            ReleaseAgeRatingCorrection(declarationID: "age", sharedLocation: nil, datingAndRelationships: true))
        #expect(current.incompleteAgeRatings[current.current] == nil)
        #expect(try ReleaseWorkflowASCAdapter.fingerprints(corrected, checkAgeRatingCorrection: false).incompleteAgeRatings.isEmpty)
    }

    @Test func rejectsOtherChangesAndMalformedAnswers() throws {
        let empty: [String: Any] = ["gambling": false]
        let full: [String: Any] = ["gambling": false, "sharedLocation": false, "datingAndRelationships": true]
        let old = try ReleaseWorkflowASCAdapter.fingerprints(document([("one", empty), ("two", empty)]), checkAgeRatingCorrection: false)
        let changed: [[String: Any]] = [
            document([("one", full), ("two", full)]),
            document([("one", full), ("two", empty)], notes: "updated"),
            document([("one", full.merging(["gambling": true]) { _, new in new }), ("two", empty)]),
            document([("one", full.merging(["sharedLocation": NSNumber(value: 0)]) { _, new in new }), ("two", empty)]),
            document([("one", full.merging(["datingAndRelationships": NSNull()]) { _, new in new }), ("two", empty)])
        ]
        for value in changed {
            let current = try ReleaseWorkflowASCAdapter.fingerprints(value, checkAgeRatingCorrection: true)
            #expect(current.incompleteAgeRatings[old.current] == nil)
        }
        let edited = try ReleaseWorkflowASCAdapter.fingerprints(document([("one", ["sharedLocation": true,
            "datingAndRelationships": true, "gambling": false]), ("two", empty)]), checkAgeRatingCorrection: false)
        let current = try ReleaseWorkflowASCAdapter.fingerprints(document([("one", full), ("two", empty)]), checkAgeRatingCorrection: true)
        #expect(current.incompleteAgeRatings[edited.current] == nil)
    }
}
