// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// Static definitions for all MCP tools exposed by Blitz
enum MCPRegistry {

    /// Returns all tool definitions for the MCP tools/list response
    static func allTools() -> [[String: Any]] {
        var tools: [[String: Any]] = []

        tools.append(tool(
            name: "get_release_targets",
            description: "List configured release targets and Store bindings for the explicitly named local project. Read-only, independent of UI selection. Select exactly one releaseTargetId; this never creates an app or submits every platform.",
            properties: ["projectId": ["type": "string"]], required: ["projectId"]
        ))
        tools.append(tool(
            name: "get_release_context",
            description: "Read the current UI target only if it matches the explicitly intended project and App Store app. Returns expectedTarget for UI-bound mutations. Does not switch apps or authorize writes. Release workflow operations below do not depend on UI selection.",
            properties: ["projectId": ["type": "string"], "appId": ["type": "string"],
                         "releaseTargetId": ["type": "string", "description": "Required when the project has several targets; must match the selected UI target."],
                         "versionId": ["type": ["string", "null"], "description": "Optional expected selected version; explicit null expects no version."]],
            required: ["projectId", "appId"]
        ))
        tools.append(tool(
            name: "release_prepare",
            description: "Prepare a durable release operation for exact project/account/app/platform/version/build IDs, independently of the selected UI app. Apple reads only. The build must already be attached and valid. Records a content fingerprint without changing metadata, assets or submission state. Local tests and source/artifact provenance must be established separately in the project release dossier.",
            properties: [
                "projectId": ["type": "string"], "projectPath": ["type": "string"],
                "releaseTargetId": ["type": "string", "description": "Exact configured target from get_release_targets. Required when several targets exist; UI selection is never adopted."],
                "appId": ["type": "string"], "bundleId": ["type": "string"],
                "platform": ["type": "string", "enum": ProjectPlatform.allCases.map(\.ascPlatformValue)],
                "accountKey": ["type": "string", "description": "Expected nonsecret issuerId:keyId fingerprint."],
                "versionId": ["type": "string"], "buildId": ["type": "string"],
                "releaseMode": ["type": "string", "enum": ["MANUAL", "AFTER_APPROVAL"]]
            ],
            required: ["projectId", "projectPath", "appId", "bundleId", "platform", "accountKey", "versionId", "buildId", "releaseMode"]
        ))
        for (name, description) in [
            ("release_status", "Read and reconcile a durable operation with Apple. Never replays an upload or submission. Use after a timeout or restart before any retry."),
            ("release_validate", "Freshly validate the exact prepared release and compare its content fingerprint. No Apple mutations. Reports blockers, authentication problems and changed content; does not authorize submission."),
            ("release_submit", "Submit the exact validated operation after explicit user authorization. Requires its unchanged confirmationDigest and confirm=true. Sets only the prepared release mode, submits once, and records unknown outcomes for read-only reconciliation. Never attaches an arbitrary build or changes prepared metadata.")
        ] {
            var properties: [String: Any] = ["operationId": ["type": "string"], "accountKey": ["type": "string"],
                "releaseTargetId": ["type": "string", "description": "Optional assertion of the saved operation's immutable target ID; cannot change it."]]
            var required = ["operationId", "accountKey"]
            if name == "release_submit" {
                properties["confirmationDigest"] = ["type": "string"]
                properties["confirm"] = ["type": "boolean", "description": "True only when the user authorized this exact release and mode."]
                properties["resumeSubmissionId"] = ["type": "string", "description": "Explicitly continue only the exact resumableSubmissionId freshly returned by release_status for this same authorized operation. Revalidates identity, content, build, release mode and readiness, then submits that existing draft without creating resources. Omit for a new submission. Never retry an uncertain final submit."]
                properties["confirmLegacyDraftRecovery"] = ["type": "boolean", "description": "Only for a legacy record with requiresLegacyRecoveryConfirmation=true: assert that documented evidence proves the original run stopped before the final submit. A READY_FOR_REVIEW snapshot alone is insufficient. Preserve the original authorization, operation and exact draft. Never set this for an unknown historical final-submit outcome."]
                required += ["confirmationDigest", "confirm"]
            }
            tools.append(tool(name: name, description: description, properties: properties, required: required))
        }

        // -- App State --
        tools.append(tool(
            name: "app_get_state",
            description: "Get current project, active tab, and streaming status",
            properties: [:],
            required: []
        ))

        // -- Navigation --
        tools.append(tool(
            name: "nav_switch_tab",
            description: "Switch the active sidebar tab. Legacy aliases `storeListing` and `appDetails` map to `appInformation`.",
            properties: [
                "tab": ["type": "string", "description": "Tab name. Use 'dashboard' or 'app' for top-level tabs. Legacy names (simulator, database, tests, assets, ascOverview) map to App sub-tabs.", "enum": [
                    "dashboard", "app",
                    "simulator", "database", "tests", "assets", "overview", "ascOverview",
                    "appInformation", "screenshots", "monetization", "review",
                    "analytics", "reviews",
                    "builds", "groups", "betaInfo", "feedback",
                    "settings"
                ]]
            ],
            required: ["tab"]
        ))

        tools.append(tool(
            name: "nav_list_tabs",
            description: "List all available tabs with their groups",
            properties: [:],
            required: []
        ))

        // -- Projects --
        tools.append(tool(
            name: "project_list",
            description: "List all projects",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "project_get_active",
            description: "Get active project details",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "project_open",
            description: "Open a project by its ID",
            properties: [
                "projectId": ["type": "string", "description": "Project ID to open"]
            ],
            required: ["projectId"]
        ))

        tools.append(tool(
            name: "project_create",
            description: "Create a new Blitz Neo project",
            properties: [
                "name": ["type": "string", "description": "Project name"],
                "type": ["type": "string", "description": "Project type (blitz, react-native, flutter, swift)", "enum": ["blitz", "react-native", "flutter", "swift"]],
                "platform": ["type": "string", "description": "Target platform (iOS or macOS). Defaults to iOS.", "enum": ["iOS", "macOS"]]
            ],
            required: ["name", "type"]
        ))

        tools.append(tool(
            name: "project_import",
            description: "Import an existing project from a path",
            properties: [
                "path": ["type": "string", "description": "Absolute path to project"],
                "type": ["type": "string", "description": "Project type", "enum": ["blitz", "react-native", "flutter", "swift"]],
                "platform": ["type": "string", "description": "Target platform (iOS or macOS). Defaults to iOS.", "enum": ["iOS", "macOS"]]
            ],
            required: ["path", "type"]
        ))

        tools.append(tool(
            name: "project_close",
            description: "Close the current project",
            properties: [:],
            required: []
        ))

        // -- Simulator --
        tools.append(tool(
            name: "simulator_list_devices",
            description: "List all simulators and physical devices",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "simulator_select_device",
            description: "Select and boot a simulator by UDID",
            properties: [
                "udid": ["type": "string", "description": "Device UDID"]
            ],
            required: ["udid"]
        ))


        // -- Settings --
        tools.append(tool(
            name: "settings_get",
            description: "Get current app settings",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "settings_update",
            description: "Update app settings (cursor)",
            properties: [
                "showCursor": ["type": "boolean", "description": "Show cursor overlay"],
                "cursorSize": ["type": "number", "description": "Cursor size in pixels"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "settings_save",
            description: "Save current settings to disk",
            properties: [:],
            required: []
        ))

        tools.append(tool(
            name: "get_blitz_screenshot",
            description: "Capture a screenshot of the Blitz Neo macOS app main window",
            properties: [:],
            required: []
        ))

        // -- Rejection Feedback --
        tools.append(tool(
            name: "get_rejection_feedback",
            description: "Get Apple's detailed rejection feedback (guideline violations, reviewer messages) for the current or specified app version. Returns cached data — no Apple ID auth required. Use this when an app is rejected to understand what needs to be fixed.",
            properties: [
                "version": ["type": "string", "description": "Version string to get feedback for (e.g. \"1.0.0\"). Defaults to the latest rejected version."]
            ],
            required: []
        ))

        // -- Tab State --
        tools.append(tool(
            name: "get_tab_state",
            description: "Get the structured data state of any Blitz Neo tab. Returns form field values, submission readiness, versions, builds, localizations, etc. Use this instead of screenshots to read UI state. Legacy aliases `storeListing` and `appDetails` map to `appInformation`.",
            properties: [
                "tab": ["type": "string", "description": "Tab to read state from (defaults to currently active tab). 'app' or 'ascOverview' returns overview/submission readiness.", "enum": [
                    "app", "ascOverview", "overview",
                    "appInformation", "screenshots", "monetization", "review",
                    "analytics", "reviews", "builds", "groups", "betaInfo", "feedback"
                ]],
                "buildId": ["type": "string", "description": "With tab=builds, load read-only beta status, group assignments and individually assigned testers for this exact build in the current app."],
                "groupId": ["type": "string", "description": "With tab=groups, load read-only build and tester memberships for this exact group in the current app."]
            ],
            required: []
        ))

        // -- ASC Credentials --
        tools.append(tool(
            name: "asc_set_credentials",
            description: "Pre-fill the App Store Connect API credential form with issuer ID and private key file. `keyId` is optional; when omitted, Blitz Neo derives it from Apple's default `.p8` filename. The user must confirm in the UI. Works in both onboarding and release tabs.",
            properties: [
                "issuerId": ["type": "string", "description": "Issuer ID (UUID format)"],
                "keyId": ["type": "string", "description": "Optional key ID (10-character alphanumeric). If omitted, Blitz Neo derives it from a filename like AuthKey_XXXXXXXXXX.p8."],
                "privateKeyPath": ["type": "string", "description": "Absolute path to the .p8 private key file (e.g. ~/.blitz/AuthKey_XXXXXXXXXX.p8)"]
            ],
            required: ["issuerId", "privateKeyPath"]
        ))

        // -- ASC Form Tools --
        tools.append(tool(
            name: "asc_fill_form",
            description: "Fill one or more App Store Connect form fields. Navigates to the tab automatically if auto-nav is enabled. For `appInformation`, pass locale to target a specific localization safely. Legacy tabs `storeListing` and `appDetails` are still accepted. See CLAUDE.md for complete field reference.",
            properties: [
                "projectId": ["type": "string", "description": "Required for settings.bundleId before a Store app exists. Store form tabs use expectedTarget instead."],
                "tab": ["type": "string", "description": "Target form tab", "enum": [
                    "appInformation", "storeListing", "appDetails", "monetization", "review.ageRating", "review.contact", "settings.bundleId"
                ]],
                "locale": ["type": "string", "description": "For appInformation only: locale code to target (for example en-US or ja)."],
                "fields": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "field": ["type": "string"],
                            "value": ["type": "string"]
                        ],
                        "required": ["field", "value"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            required: ["tab", "fields"]
        ))

        tools.append(tool(
            name: "app_information_switch_localization",
            description: "Refresh app-information localizations from App Store Connect and switch the Blitz Neo app-information tab to the requested locale.",
            properties: [
                "locale": ["type": "string", "description": "Locale code to select in the app-information tab (for example en-US or ja)"]
            ],
            required: ["locale"]
        ))

        tools.append(tool(
            name: "store_listing_switch_localization",
            description: "Deprecated alias for `app_information_switch_localization`.",
            properties: [
                "locale": ["type": "string", "description": "Locale code to select in the app-information tab (for example en-US or ja)"]
            ],
            required: ["locale"]
        ))

        // -- Screenshot Track Tools --
        tools.append(tool(
            name: "screenshots_switch_localization",
            description: "Refresh screenshot localizations from App Store Connect, switch the Blitz Neo screenshots tab to the requested locale, and hydrate that locale's screenshot tracks. Call this before manipulating track slots or saving when targeting a specific locale.",
            properties: [
                "locale": ["type": "string", "description": "Locale code to select in the screenshots tab (for example en-US or en-GB)"]
            ],
            required: ["locale"]
        ))

        tools.append(tool(
            name: "screenshots_put_track_slot",
            description: "Import a screenshot file directly into a specific track slot (1-10). If the slot is occupied, Blitz Neo inserts the new screenshot there and shifts later slots right. If you are targeting a specific locale, call screenshots_switch_localization first.",
            properties: [
                "sourcePath": ["type": "string", "description": "Absolute path to the source image file"],
                "slotIndex": ["type": "integer", "description": "Track slot position (1-10)"],
                "displayType": ["type": "string", "description": "Display type (default APP_IPHONE_67)", "enum": ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]],
                "locale": ["type": "string", "description": "Locale code. Must match the currently selected screenshots locale in Blitz Neo."],
                "fileName": ["type": "string", "description": "Optional stored file name for the imported image (defaults to the source file name, converting to .png when needed)"]
            ],
            required: ["sourcePath", "slotIndex"]
        ))

        tools.append(tool(
            name: "screenshots_remove_track_slot",
            description: "Remove the screenshot currently staged in a specific track slot (1-10). If you are targeting a specific locale, call screenshots_switch_localization first.",
            properties: [
                "slotIndex": ["type": "integer", "description": "Track slot position (1-10)"],
                "displayType": ["type": "string", "description": "Display type (default APP_IPHONE_67)", "enum": ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]],
                "locale": ["type": "string", "description": "Locale code. Must match the currently selected screenshots locale in Blitz Neo."]
            ],
            required: ["slotIndex"]
        ))

        tools.append(tool(
            name: "screenshots_reorder_track",
            description: "Reorder the current screenshot track using a full 10-element permutation of the current 0-based slot positions. For example, [0,2,1,4,3,5,6,7,8,9] swaps slots 2/3 and 4/5. If you are targeting a specific locale, call screenshots_switch_localization first.",
            properties: [
                "order": [
                    "type": "array",
                    "description": "Exactly 10 integers containing each slot index 0 through 9 once. The value at each position says which current slot moves there.",
                    "items": ["type": "integer"] as [String: Any]
                ] as [String: Any],
                "displayType": ["type": "string", "description": "Display type (default APP_IPHONE_67)", "enum": ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]],
                "locale": ["type": "string", "description": "Locale code. Must match the currently selected screenshots locale in Blitz Neo."]
            ],
            required: ["order"]
        ))

        tools.append(tool(
            name: "screenshots_save",
            description: "Save screenshot track changes to App Store Connect. If displayType is provided, syncs that device family only; otherwise it syncs every prepared/staged device family for the current locale. If you are targeting a specific locale, call screenshots_switch_localization first.",
            properties: [
                "displayType": ["type": "string", "description": "Optional display type. Omit it to sync every prepared/staged device family for the selected locale.", "enum": ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129", "APP_DESKTOP"]],
                "locale": ["type": "string", "description": "Locale code. Must match the currently selected screenshots locale in Blitz Neo."]
            ],
            required: []
        ))

        tools.append(tool(
            name: "asc_select_version",
            description: "Select an App Store version in Blitz Neo by version ID or version string, then refresh the active release tab or overview.",
            properties: [
                "version": ["type": "string", "description": "Version ID or version string (for example \"1.2.3\")"]
            ],
            required: ["version"]
        ))

        tools.append(tool(
            name: "asc_create_version",
            description: "Create a new App Store software update version for the current app. Optionally copy metadata or review contact details from another version and attach a build immediately.",
            properties: [
                "versionString": ["type": "string", "description": "New App Store version string (for example \"1.2.4\")"],
                "copyFromVersion": ["type": "string", "description": "Optional source version ID or version string to copy from"],
                "copyMetadata": ["type": "boolean", "description": "Copy store listing metadata from the source version. Defaults to true."],
                "copyReviewDetail": ["type": "boolean", "description": "Copy review contact details from the source version. Defaults to true."],
                "attachBuildId": ["type": "string", "description": "Optional build ID to attach to the new version immediately"]
            ],
            required: ["versionString"]
        ))

        tools.append(tool(
            name: "asc_open_submit_preview",
            description: "Read submission readiness and open the Submit for Review modal. Does not attach a build or submit anything. Returns missing required fields when incomplete.",
            properties: [:],
            required: []
        ))

        // -- ASC IAP / Subscriptions / Pricing --
        tools.append(tool(
            name: "asc_create_iap",
            description: "Create an in-app purchase in App Store Connect. Creates the IAP, adds en-US localization, sets the price, and uploads a review screenshot. You MUST provide a screenshot — take one of the IAP content in the app simulator first (e.g. the purchase UI or content being unlocked), save to /tmp, then pass the path.",
            properties: [
                "productId": ["type": "string", "description": "Unique product identifier (e.g. com.app.coins100)"],
                "name": ["type": "string", "description": "Internal reference name"],
                "type": ["type": "string", "description": "IAP type", "enum": ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"]],
                "displayName": ["type": "string", "description": "User-facing display name (en-US localization)"],
                "price": ["type": "string", "description": "Price in USD (e.g. \"0.99\", \"4.99\")"],
                "description": ["type": "string", "description": "User-facing description (optional)"],
                "screenshotPath": ["type": "string", "description": "Path to review screenshot (min 640x920px PNG/JPEG). Use blitz-iphone to take a screenshot of the IAP content in the simulator."]
            ],
            required: ["productId", "name", "type", "displayName", "price", "screenshotPath"]
        ))

        tools.append(tool(
            name: "asc_create_subscription",
            description: "Create an auto-renewable subscription in App Store Connect. Creates or reuses a subscription group, adds the subscription with en-US localization, sets the price, and uploads a review screenshot. You MUST provide a screenshot — take one of the subscription content in the app simulator first (e.g. the paywall or premium features screen), save to /tmp, then pass the path.",
            properties: [
                "groupName": ["type": "string", "description": "Subscription group name (created if doesn't exist)"],
                "productId": ["type": "string", "description": "Unique product identifier"],
                "name": ["type": "string", "description": "Internal reference name"],
                "displayName": ["type": "string", "description": "User-facing display name (en-US localization)"],
                "duration": ["type": "string", "description": "Billing period", "enum": [
                    "ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"
                ]],
                "price": ["type": "string", "description": "Price in USD (e.g. \"4.99\")"],
                "description": ["type": "string", "description": "User-facing description (optional)"],
                "screenshotPath": ["type": "string", "description": "Path to review screenshot (min 640x920px PNG/JPEG). Use blitz-iphone to take a screenshot of the subscription content in the simulator."]
            ],
            required: ["groupName", "productId", "name", "displayName", "duration", "price", "screenshotPath"]
        ))

        tools.append(tool(
            name: "asc_web_auth",
            description: "Open the Apple ID login window in Blitz Neo. Validates App Store Connect and preserves an existing valid CLI session instead of blindly overwriting it. Developer Portal capability is reported separately; request it only when needed. Requires user interaction (Apple ID + 2FA). Success renews authentication only; it does not confirm a Store write or authorize repeating a POST. For app-creation account_verification/401 with creationAttempted=false, keep the original operation, compare its complete appCreationSetup state after login, and follow the skill's guarded --resume-after-auth continuation.",
            properties: ["requireDeveloperPortal": ["type": "boolean", "description": "Default false. Set true for a diagnosed Developer Portal session problem, such as an unverified program-license check. A successful login does not mean agreements are active; rerun the original read-only readiness check."]],
            required: []
        ))

        tools.append(tool(
            name: "asc_confirm_created_app",
            description: "Confirm an app after a successful or possibly completed creation request from a specific registered setup operation. Requires the exact confirmed public name, bundle ID, SKU, platform and primary locale, plus the project and operation IDs from its identity JSON. Refuses stale operations, mismatched Apple records or another active project. Retries not-found responses up to 10 times. Do not use after account_verification failed with creationAttempted=false: no creation POST was sent. For its 401, renew authentication and follow the skill's guarded continuation of the original operation instead.",
            properties: [
                "bundleId": ["type": "string", "description": "Exact registered bundle ID from the confirmed identity JSON."],
                "expectedName": ["type": "string", "description": "Confirmed public App Store name (appName)."],
                "expectedSKU": ["type": "string", "description": "Confirmed permanent SKU (sku)."],
                "expectedPlatform": ["type": "string", "enum": ["iOS", "macOS"]],
                "expectedLocale": ["type": "string", "description": "Confirmed primaryLocale, e.g. de-DE."],
                "projectId": ["type": "string", "description": "Original projectId from the identity JSON."],
                "releaseTargetId": ["type": "string", "description": "Original configured releaseTargetId from the identity JSON; required for multi-target projects."],
                "operationId": ["type": "string", "description": "Original operationId from the identity JSON."]
            ],
            required: ["bundleId", "expectedName", "expectedSKU", "expectedPlatform", "expectedLocale", "projectId", "operationId"]
        ))

        tools.append(tool(
            name: "asc_reopen_app_setup",
            description: "Return an unconfirmed app-creation operation to its original identity form without any Apple mutation. Preserves the exact name, bundle ID, SKU, platform and locale. Invalidates the old operation; another creation requires a new user confirmation. Rejects stale or foreign project/account/operation IDs. Do not reset an otherwise unchanged operation solely because account_verification returned 401 with creationAttempted=false; follow the skill's guarded authentication continuation first.",
            properties: [
                "projectId": ["type": "string", "description": "Original projectId from the confirmed identity JSON."],
                "operationId": ["type": "string", "description": "Original operationId from the confirmed identity JSON."],
                "message": ["type": "string", "description": "Optional plain-text diagnosis for the form, without credentials or raw response bodies; maximum 2000 characters."]
            ],
            required: ["projectId", "operationId"]
        ))

        tools.append(tool(
            name: "asc_set_app_price",
            description: "Set the app's price on the App Store. Use \"0\" for free. Optionally schedule a future price change with effectiveDate.",
            properties: [
                "price": ["type": "string", "description": "Price in USD (e.g. \"0.99\", \"0\" for free)"],
                "effectiveDate": ["type": "string", "description": "ISO date for scheduled price change (e.g. \"2026-06-01\"). Omit for immediate change."]
            ],
            required: ["price"]
        ))

        // -- Build Pipeline --
        tools.append(tool(
            name: "app_store_setup_signing",
            description: "Set up code signing for iOS or macOS: registers bundle ID, creates distribution certificate (and installer certificate for macOS), installs provisioning profile, and configures the Xcode project. Automatically detects platform from project metadata. Idempotent — re-running skips completed steps.",
            properties: [
                "teamId": ["type": "string", "description": "Apple Developer Team ID (optional if already saved in project metadata)"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "app_store_build",
            description: "Archive the selected app and export a signed IPA or macOS PKG. Returns the explicit artifact path for app_store_upload; verifies exported app identity, version and build against the archive.",
            properties: [
                "scheme": ["type": "string", "description": "Xcode scheme (auto-detected if omitted)"],
                "configuration": ["type": "string", "description": "Build configuration (default: Release)"]
            ],
            required: []
        ))

        tools.append(tool(
            name: "app_store_upload",
            description: "Upload an explicit IPA or macOS PKG to the captured app and platform. Verifies artifact identity, version, build and encryption metadata. Optionally waits for processing and attaches only to the captured matching editable version.",
            properties: [
                "ipaPath": ["type": "string", "description": "Required path to the exact IPA or macOS PKG returned by app_store_build. No global latest-export fallback."],
                "skipPolling": ["type": "boolean", "description": "Skip waiting for build processing (default: false)"]
            ],
            required: ["ipaPath"]
        ))

        return tools.map { definition in
            guard let name = definition["name"] as? String, MCPExpectedTarget.boundTools.contains(name),
                  var schema = definition["inputSchema"] as? [String: Any],
                  var properties = schema["properties"] as? [String: Any] else { return definition }
            var result = definition
            properties["expectedTarget"] = MCPExpectedTarget.schema
            schema["properties"] = properties
            // settings.bundleId is a pre-Store identity form with its own operation
            // protocol. All other asc_fill_form tabs require this at runtime.
            if name != "asc_fill_form" {
                schema["required"] = (schema["required"] as? [String] ?? []) + ["expectedTarget"]
            }
            result["inputSchema"] = schema
            result["description"] = (result["description"] as? String ?? "")
                + " Pass expectedTarget from get_release_context for the intended app; missing or changed targets are rejected."
            return result
        }
    }

    /// Determine the category for a given tool name
    static func category(for toolName: String) -> ApprovalRequest.ToolCategory {
        switch toolName {
        // Navigation / read-only
        case "app_get_state", "nav_switch_tab", "nav_list_tabs":
            return .navigation
        case "project_list", "project_get_active", "get_release_context", "get_release_targets", "release_prepare", "release_validate", "release_status":
            return .query
        case "simulator_list_devices":
            return .query
        case "settings_get":
            return .query
        case "get_blitz_screenshot", "get_tab_state", "get_rejection_feedback":
            return .query

        // Mutations
        case "project_open", "project_create", "project_import", "project_close":
            return .projectMutation
        case "simulator_select_device":
            return .simulatorControl
        case "settings_update", "settings_save":
            return .settingsMutation

        // ASC credential pre-fill — no approval needed, user must click Save
        case "asc_set_credentials":
            return .query
        case "asc_fill_form":
            return .ascFormMutation
        case "app_information_switch_localization", "store_listing_switch_localization":
            return .ascFormMutation
        case "asc_select_version":
            return .query
        case "asc_create_version", "release_submit":
            return .ascSubmitMutation
        case "screenshots_switch_localization", "screenshots_put_track_slot",
             "screenshots_remove_track_slot", "screenshots_reorder_track", "screenshots_save":
            return .ascScreenshotMutation
        case "asc_open_submit_preview":
            return .ascSubmitMutation
        case "asc_web_auth":
            return .query  // user-interactive (Apple ID login) — no approval needed
        case "asc_confirm_created_app", "asc_reopen_app_setup":
            return .query // Local setup navigation/readback; no Apple mutation.
        case "asc_create_iap", "asc_create_subscription", "asc_set_app_price":
            return .ascFormMutation

        // Build pipeline tools
        case "app_store_setup_signing", "app_store_build", "app_store_upload":
            return .buildPipeline

        default:
            return .unknown
        }
    }

    // MARK: - Helper

    /// Returns all tool names registered in the registry.
    static func allToolNames() -> [String] {
        allTools().compactMap { $0["name"] as? String }
    }

    private static func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema
        ]
    }
}
