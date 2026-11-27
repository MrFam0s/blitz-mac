import CoreFoundation
import Foundation

extension MCPRegistry {
    static func chinaTools() -> [[String: Any]] {
        let string = ["type": "string", "minLength": 1] as [String: Any]
        return [
            storeTool(name: "store_china_declarations_get",
                      description: "Read mainland China compliance requirements through the cached Apple web session bound to this app. Returns providerId, requirementId, status, formId and required actions. List status does not disclose a saved Yes/No.",
                      properties: ["providerId": string], required: []),
            storeTool(name: "store_china_declaration_set",
                      description: "File one expressly authorized, product-verified mainland China declaration for the app and provider from the read tool. Supports positive answers with filing records or evidence in the registered project. A saved receipt is reconciled with Apple's current form. Pending forms are read-only. For an authorized correction of a collected editable answer provide its exact replacingFormId.",
                      properties: ["providerId": string, "requirementId": string,
                                   "requirement": ["type": "string", "enum": ["AI_GENERATED_CONTENT", "SECURITY_ASSESSMENT"]],
                                   "declared": ["type": "boolean"], "confirm": ["type": "boolean", "enum": [true]],
                                   "filingType": ["type": "string", "enum": ["LLM", "ALGORITHM"]],
                                   "filingName": string, "filingNumber": string, "thirdPartyTechnology": ["type": "boolean"],
                                   "thirdPartyAuthorizationPath": string, "proofPath": string, "reportPath": string,
                                   "replacingFormId": string],
                      required: ["providerId", "requirementId", "requirement", "declared", "confirm"])
        ]
    }
}

extension MCPExecutor {
    func executeChinaTool(name: String, arguments: [String: Any], context: MCPStoreContext) async throws -> [String: Any] {
        let writing = name == "store_china_declaration_set"
        var params = try MCPChinaDeclaration.parameters(arguments, writing: writing)
        params["appId"] = context.appID
        params["bundleId"] = context.bundleID
        var files = [MCPStoreFile]()
        defer { for file in files { file.remove() } }
        for key in ["thirdPartyAuthorizationPath", "proofPath", "reportPath"] {
            guard let path = params[key] as? String else { continue }
            let file = try MCPStoreFile.stage(relativePath: path, projectRoot: context.projectRoot,
                                              allowedExtensions: ["doc", "docx", "jpeg", "jpg", "png", "pdf"], maxBytes: 20 * 1024 * 1024)
            files.append(file)
            params[key] = file.url.path
        }
        try await context.validate()
        let result = try await ASCDaemonClient(credentials: context.credentials).chinaForms(writing: writing, params: params)
        let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        guard let json, json["appId"] as? String == context.appID,
              let provider = json["providerId"] as? String, !provider.isEmpty,
              (params["providerId"] as? String).map({ $0 == provider }) ?? true else {
            throw ASCError.notFound("Apple declaration identity could not be verified. Read the current declarations before retrying.")
        }
        var response = mcpJSON(json)
        if writing, json["outcome"] as? String != "saved" { response["isError"] = true }
        return response
    }
}

enum MCPChinaDeclaration {
    static func parameters(_ arguments: [String: Any], writing: Bool) throws -> [String: Any] {
        let invalid = MCPServerService.MCPError.invalidToolArgs
        var params: [String: Any] = [:]
        let textKeys = writing ? ["providerId", "requirement", "requirementId", "replacingFormId", "filingName",
                                  "filingNumber", "filingType", "thirdPartyAuthorizationPath", "proofPath", "reportPath"] : ["providerId"]
        for key in textKeys where arguments[key] != nil {
            guard let text = arguments[key] as? String, !text.isEmpty,
                  text == text.trimmingCharacters(in: .whitespacesAndNewlines) else { throw invalid }
            params[key] = text
        }
        guard writing else { return params }
        for key in ["confirm", "declared", "thirdPartyTechnology"] where arguments[key] != nil {
            guard let number = arguments[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid }
            params[key] = number.boolValue
        }
        guard params["confirm"] as? Bool == true, let answer = params["declared"] as? Bool,
              let requirement = params["requirement"] as? String,
              ["AI_GENERATED_CONTENT", "SECURITY_ASSESSMENT"].contains(requirement),
              params["requirementId"] != nil, params["providerId"] != nil else { throw invalid }
        let evidenceKeys = ["filingType", "filingName", "filingNumber", "thirdPartyTechnology", "thirdPartyAuthorizationPath", "proofPath", "reportPath"]
        var expected = Set<String>()
        if answer && requirement == "SECURITY_ASSESSMENT" {
            expected = ["proofPath", "reportPath"]
        } else if answer {
            guard let type = params["filingType"] as? String, ["LLM", "ALGORITHM"].contains(type),
                  let thirdParty = params["thirdPartyTechnology"] as? Bool else { throw invalid }
            expected = ["filingType", "filingName", "filingNumber", "thirdPartyTechnology"]
            if thirdParty { expected.insert("thirdPartyAuthorizationPath") }
        }
        guard Set(evidenceKeys.filter { params[$0] != nil }) == expected else { throw invalid }
        return params
    }
}
