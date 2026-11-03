import Foundation

extension MCPExecutor {
    static func testFlightBuildPayload(_ build: ASCBuild) -> [String: Any] {
        [
            "id": build.id,
            "appId": build.appId as Any? ?? NSNull(),
            "buildNumber": build.attributes.version,
            "version": build.attributes.version, // Existing clients: legacy alias for buildNumber.
            "marketingVersion": build.preReleaseVersion?.attributes.version as Any? ?? NSNull(),
            "platform": build.preReleaseVersion?.attributes.platform as Any? ?? NSNull(),
            "processingState": build.attributes.processingState as Any? ?? NSNull(),
            "expired": build.attributes.expired as Any? ?? NSNull(),
            "expirationDate": build.attributes.expirationDate as Any? ?? NSNull(),
            "uploadedDate": build.attributes.uploadedDate as Any? ?? NSNull(),
            "internalBuildState": build.buildBetaDetail?.internalBuildState as Any? ?? NSNull(),
            "externalBuildState": build.buildBetaDetail?.externalBuildState as Any? ?? NSNull(),
            "autoNotifyEnabled": build.buildBetaDetail?.attributes.autoNotifyEnabled as Any? ?? NSNull(),
        ]
    }

    static func testFlightBuildListPayload(_ builds: [ASCBuild]) -> [String: Any] {
        ["builds": builds.map(testFlightBuildPayload), "totalBuilds": builds.count, "truncated": false]
    }

    static func testFlightGroupPayload(_ group: ASCBetaGroup) -> [String: Any] {
        ["id": group.id, "name": group.attributes.name,
         "appId": group.appId as Any? ?? NSNull(),
         "isInternalGroup": group.attributes.isInternalGroup as Any? ?? NSNull(),
         "hasAccessToAllBuilds": group.attributes.hasAccessToAllBuilds as Any? ?? NSNull(),
         "publicLinkEnabled": group.attributes.publicLinkEnabled as Any? ?? NSNull()]
    }

    static func testFlightTesterPayload(_ tester: ASCBetaTester) -> [String: Any] {
        ["id": tester.id,
         "firstName": tester.attributes.firstName as Any? ?? NSNull(),
         "lastName": tester.attributes.lastName as Any? ?? NSNull(),
         "email": tester.attributes.email as Any? ?? NSNull(),
         "inviteType": tester.attributes.inviteType as Any? ?? NSNull(),
         "state": tester.attributes.state as Any? ?? NSNull()]
    }

    @MainActor
    func testFlightBuildDetailState(_ asc: ASCManager, id: String) -> [String: Any] {
        var result: [String: Any] = [
            "selectedBuildId": id,
            "detailLoaded": asc.testFlightBuildDetails[id] != nil,
            "detailLoading": asc.loadingTestFlightBuildIds.contains(id),
            "detailNeedsRefresh": asc.testFlightBuildErrors[id] != nil,
        ]
        if let error = asc.testFlightBuildErrors[id] { result["detailError"] = error }
        if let detail = asc.testFlightBuildDetails[id] {
            result["buildDetail"] = [
                "build": Self.testFlightBuildPayload(detail.build),
                "betaGroups": detail.betaGroups.map(Self.testFlightGroupPayload),
                "individualTesters": detail.individualTesters.map(Self.testFlightTesterPayload),
                "testerScope": "Individual build assignments only; group members are read through groupId.",
            ]
        }
        return result
    }

    @MainActor
    func testFlightGroupDetailState(_ asc: ASCManager, id: String) -> [String: Any] {
        var result: [String: Any] = [
            "selectedGroupId": id,
            "detailLoaded": asc.testFlightGroupDetails[id] != nil,
            "detailLoading": asc.loadingTestFlightGroupIds.contains(id),
            "detailNeedsRefresh": asc.testFlightGroupErrors[id] != nil,
        ]
        if let error = asc.testFlightGroupErrors[id] { result["detailError"] = error }
        if let detail = asc.testFlightGroupDetails[id] {
            result["groupDetail"] = [
                "group": Self.testFlightGroupPayload(detail.group),
                "builds": detail.builds.map(Self.testFlightBuildPayload),
                "testers": detail.testers.map(Self.testFlightTesterPayload),
                "testerScope": "Members of this group; this is not a list of individual build assignments.",
            ]
        }
        return result
    }
}
