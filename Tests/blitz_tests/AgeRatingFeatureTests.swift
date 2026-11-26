import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func ageRatingDistinguishesUnansweredFromNoInReadinessAndMCP() throws {
    let manager = ASCManager()
    var attributes = ASCAgeRatingDeclaration.Attributes()
    for (_, path) in ASCAgeRatingDeclaration.Attributes.booleanFields { attributes[keyPath: path] = false }
    for (_, path) in ASCAgeRatingDeclaration.Attributes.frequencyFields { attributes[keyPath: path] = "NONE" }
    for location in [nil, false, true] as [Bool?] {
        for dating in [nil, false, true] as [Bool?] {
            attributes.sharedLocation = location
            attributes.datingAndRelationships = dating
            manager.ageRatingDeclaration = .init(id: "rating", attributes: attributes)
            #expect(manager.ageRatingIsConfigured == (location != nil && dating != nil))
            let state = try #require(MCPExecutor.ageRatingStatePayload(
                ageRating: manager.ageRatingDeclaration, isSaved: manager.ageRatingIsConfigured, pendingDraft: nil
            ))
            let missing = try #require(state["missingRequired"] as? [String])
            #expect(missing.contains("sharedLocation") == (location == nil))
            #expect(missing.contains("datingAndRelationships") == (dating == nil))
            #expect(state["sharedLocation"] as? Bool == location)
            #expect(state["datingAndRelationships"] as? Bool == dating)
        }
    }
}

@Test func ageRatingPatchContainsOnlyExplicitValidAnswers() throws {
    let patch = try MCPExecutor.ageRatingPatch(["sharedLocation": "false"])
    #expect(patch.keys.sorted() == ["sharedLocation"])
    #expect(patch["sharedLocation"] as? Bool == false)
    let fields = try #require(MCPExecutor.validFieldsByTab["review.ageRating"])
    #expect(fields.isSuperset(of: ["sharedLocation", "datingAndRelationships"]))
    #expect(throws: MCPServerService.MCPError.self) {
        try MCPExecutor.ageRatingPatch(["sharedLocation": "false", "datingAndRelationships": "unanswered"])
    }
}

@Test func ageRatingDecodesNullAbsentAndAnsweredBooleans() throws {
    let old = try JSONDecoder().decode(ASCAgeRatingDeclaration.self, from: Data(#"{"id":"rating","attributes":{"datingAndRelationships":null}}"#.utf8))
    #expect(old.attributes.sharedLocation == nil)
    #expect(old.attributes.datingAndRelationships == nil)
    let updated = try JSONDecoder().decode(ASCAgeRatingDeclaration.self, from: Data(#"{"id":"rating","attributes":{"sharedLocation":false,"datingAndRelationships":true}}"#.utf8))
    #expect(updated.attributes.sharedLocation == false)
    #expect(updated.attributes.datingAndRelationships == true)
}

@Test func ageRatingFormPatchPreservesUnansweredAndUneditedFields() {
    let saved = ASCAgeRatingDeclaration.Attributes(gambling: false, gamblingSimulated: "NONE")
    var draft = saved
    draft.sharedLocation = false
    draft.datingAndRelationships = true
    let patch = draft.changedAnswers(from: saved)
    #expect(Set(patch.keys) == ["sharedLocation", "datingAndRelationships"])
    #expect(patch["sharedLocation"] as? Bool == false)
    #expect(patch["datingAndRelationships"] as? Bool == true)
    #expect(saved.changedAnswers(from: saved).isEmpty)
    #expect(!saved.confirms(answers: patch))
    #expect(draft.confirms(answers: patch))
    #expect(!draft.confirms(answers: ["sharedLocation": true]))
}
