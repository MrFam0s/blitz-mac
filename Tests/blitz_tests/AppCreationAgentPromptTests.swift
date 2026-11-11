import Foundation
import Testing
@testable import Blitz

@Test func appCreationPromptKeepsIdentityPathAsQuotedData() throws {
    let file = URL(fileURLWithPath: "/tmp/Bob's \"App\"\n$(touch ignored)/identity.json")
    let prompt = try AppCreationAgentPrompt.make(identityFile: file)
    let firstLine = try #require(prompt.components(separatedBy: "\n").first)
    let prefix = "Use /asc-app-create-ui to create the app from the confirmed identity JSON at "
    #expect(firstLine.hasPrefix(prefix))
    let encodedPath = String(firstLine.dropFirst(prefix.count).dropLast())
    #expect(try JSONDecoder().decode(String.self, from: Data(encodedPath.utf8)) == file.path)
}

@Test func appCreationPromptDistinguishesPrePostAuthenticationFromUncertainCreation() throws {
    let prompt = try AppCreationAgentPrompt.make(identityFile: URL(fileURLWithPath: "/tmp/identity.json"))
    #expect(prompt.contains("httpStatus=401 AND stage=account_verification AND creationAttempted=false"))
    #expect(prompt.contains("AND recovery.resumeAllowed=true"))
    #expect(prompt.contains("requiresNewConfirmation=false"))
    #expect(prompt.contains("Do not call asc_confirm_created_app or asc_reopen_app_setup for this failure"))
    #expect(prompt.contains("call asc_web_auth once"))
    #expect(prompt.contains("only if it returns success=true"))
    #expect(prompt.contains("--resume-after-auth instead of --create"))
    #expect(prompt.contains("allowed at most once"))
    #expect(prompt.contains("Never repeat a POST after a POST-stage failure, timeout or unknown outcome, including an app_creation-stage 401"))
    #expect(prompt.contains("do not revive an invalidated operation"))
}

@Test func appCreationPromptRevalidatesFullIdentityAndAccountAfterLogin() throws {
    let prompt = try AppCreationAgentPrompt.make(identityFile: URL(fileURLWithPath: "/tmp/identity.json"))
    for field in ["projectId", "operationId", "identity.appName", "identity.bundleId", "identity.sku",
                  "identity.platform", "identity.primaryLocale", "expectedIssuerId", "expectedKeyId"] {
        #expect(prompt.contains(field))
    }
    let login = try #require(prompt.range(of: "call asc_web_auth once"))
    let renewedContext = try #require(prompt.range(of: "Then call get_tab_state for tab=app again"))
    let resume = try #require(prompt.range(of: "--resume-after-auth instead of --create"))
    #expect(login.lowerBound < renewedContext.lowerBound)
    #expect(renewedContext.lowerBound < resume.lowerBound)
    #expect(prompt.contains("same awaitingAppCreation state"))
    #expect(prompt.contains("Never copy or edit the identity file, delete attempt state, or start a new operation to bypass that guard"))
}
