import XCTest
@testable import Blitz

final class MCPChinaDeclarationTests: XCTestCase {
    private let answer: [String: Any] = ["providerId": "provider", "requirementId": "REQ",
        "requirement": "AI_GENERATED_CONTENT", "declared": false, "confirm": true]

    func testFalseIsExplicitAndRejectsExtraEvidence() throws {
        XCTAssertEqual(try MCPChinaDeclaration.parameters(answer, writing: true)["declared"] as? Bool, false)
        for extra: [String: Any] in [["declared": 0], ["declared": "false"], ["confirm": false], ["confirm": 1],
                                       ["providerId": ""], ["proofPath": "unused.pdf"]] {
            XCTAssertThrowsError(try MCPChinaDeclaration.parameters(answer.merging(extra) { $1 }, writing: true))
        }
        var missing = answer
        missing.removeValue(forKey: "declared")
        XCTAssertThrowsError(try MCPChinaDeclaration.parameters(missing, writing: true))
    }

    func testPositiveAnswersRequireOnlyCorrespondingEvidence() throws {
        var ai = answer.merging(["declared": true, "filingType": "LLM", "filingName": "model", "filingNumber": "001",
                                 "thirdPartyTechnology": true]) { $1 }
        XCTAssertThrowsError(try MCPChinaDeclaration.parameters(ai, writing: true))
        ai["thirdPartyAuthorizationPath"] = "evidence/license.pdf"
        XCTAssertNoThrow(try MCPChinaDeclaration.parameters(ai, writing: true))
        ai["thirdPartyTechnology"] = false
        XCTAssertThrowsError(try MCPChinaDeclaration.parameters(ai, writing: true))

        var security = answer.merging(["declared": true, "requirement": "SECURITY_ASSESSMENT", "proofPath": "proof.pdf"]) { $1 }
        XCTAssertThrowsError(try MCPChinaDeclaration.parameters(security, writing: true))
        security["reportPath"] = "report.pdf"
        XCTAssertNoThrow(try MCPChinaDeclaration.parameters(security, writing: true))
    }
}
