import Foundation

/// Instructions for the already confirmed operation, including the one safe
/// continuation after authentication failed before any creation POST was sent.
enum AppCreationAgentPrompt {
    static func make(identityFile: URL) throws -> String {
        let path = String(decoding: try JSONEncoder().encode(identityFile.path), as: UTF8.self)
        return """
        Use /asc-app-create-ui to create the app from the confirmed identity JSON at \(path).
        Read the current bundled skill and its static create_app.py. Use every identity value exactly as stored; never derive, rename or change capitalization. This operation is already confirmed. creationMode must be newStoreApp when present: this creates a separate Store record for the selected releaseTargetId, not another platform of an existing record. For an existing Store app, stop and use its explicit platform draft flow instead; never create a duplicate record.

        Run create_app.py with --identity-file and first --dry-run. This checks syntax only, not availability or authentication at Apple.
        Before the initial --create, call get_tab_state for tab=app and compare appCreationSetup with this identity file. Require phase=awaitingAppCreation, requiresNewConfirmation=false and exact matching projectId, operationId, releaseTargetId when present, identity.appName, identity.bundleId, identity.sku, identity.platform, identity.primaryLocale, expectedIssuerId and expectedKeyId. Stop if this state is absent or any value differs; do not revive an invalidated operation. Then run --create once.

        Interpret each structured HTTP failure by its stage and creationAttempted value. Report only the sanitized Apple error.
        The sole authentication continuation is httpStatus=401 AND stage=account_verification AND creationAttempted=false AND recovery.resumeAllowed=true. No creation POST was sent in that case. Do not call asc_confirm_created_app or asc_reopen_app_setup for this failure, and do not ask for the unchanged identity again.
        For that exact failure, call asc_web_auth once. Continue only if it returns success=true. Then call get_tab_state for tab=app again and require the same awaitingAppCreation state, operationId, projectId, releaseTargetId when present, complete identity, expectedIssuerId and expectedKeyId as above. Login alone does not verify the selected API account or grant a new creation operation.
        If every value still matches, run the same create_app.py with the same --identity-file and --resume-after-auth instead of --create. This continuation is allowed at most once; the script must prove the prior pre-POST 401 and recheck the renewed session against the confirmed account before its first POST. Never copy or edit the identity file, delete attempt state, or start a new operation to bypass that guard.
        If login is cancelled, context differs, the guarded continuation is rejected, or authentication fails again, stop with the diagnosis. Preserve the unchanged operation when still active; no confirmation lookup or form reset is needed when creationAttempted=false.

        After a successful POST, or a creation request whose outcome may be uncertain, verify through asc_confirm_created_app with bundleId, expectedName=appName, expectedSKU=sku, expectedPlatform=platform, expectedLocale=primaryLocale, projectId, operationId and releaseTargetId when present from the identity file. Never repeat a POST after a POST-stage failure, timeout or unknown outcome, including an app_creation-stage 401.
        If a possibly attempted creation remains unconfirmed after read-only verification, call asc_reopen_app_setup with the original projectId, operationId and a brief non-secret error message. This returns to the identity form for a new user confirmation. Then stop: the old operation is invalid and must not be confirmed or retried. Do not use this recovery for the known pre-POST authentication failure above.
        """
    }
}
