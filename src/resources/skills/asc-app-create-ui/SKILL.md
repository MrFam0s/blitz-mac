---
name: asc-app-create-ui
description: Create an App Store Connect app from the identity confirmed in Blitz Neo
---

<!-- Modified for the AmoSystems Blitz Neo maintenance fork (2026). -->

Use the confirmed identity supplied by Blitz Neo: `appName`, `bundleId`, `sku`,
`platform` (`iOS` or `macOS`), `primaryLocale`, `projectId` and `operationId`.
Keep these values together for this creation operation. Never infer a replacement
name or identifier from a project folder or change their capitalization.

## Confirm the identity

Before creation, confirm the public app name, exact bundle ID, SKU, platform and
primary language. Do not ask again when the user has already confirmed them in
the current operation. The public name is distinct from the project folder and
technical bundle suffix. Preserve punctuation in the public name.

The default SKU is `<ConfirmedAppName>-<platform>`, preserving capitalization and
without random digits. A SKU must start with an ASCII letter or digit and contain
only ASCII letters, digits, periods, hyphens or underscores. If this default is
invalid or already taken, ask for an alternative; do not silently modify it.
Return to Blitz's identity form to confirm changed values and start a new
operation. Do not reuse an old operation ID after changing the identity.

Bundle IDs contain only ASCII letters, digits, hyphens and nonempty components
separated by periods. Use the exact ID confirmed by Blitz/Apple, including all
periods and capitalization. Names must contain 2–30 characters. If context or
identity fields are missing, return to the setup form instead of guessing them.

## Pass data as JSON, never as executable code

Write the confirmed identity to a local JSON file using a structured file-writing
tool or JSON serializer. Names containing quotes, apostrophes, dollar signs or
backslashes are data. Never insert them into shell/Python source, an unquoted
heredoc or a manually interpolated command.

Use the static `scripts/create_app.py` next to this skill. Resolve its path from
the skill directory you actually read. Pass only the JSON file path as an
argument, safely quoted. The default/`--dry-run` validates without reading a web
session or calling Apple:

```bash
python3 /absolute/path/to/asc-app-create-ui/scripts/create_app.py --identity-file /absolute/path/to/confirmed-identity.json --dry-run
```

Review the validated payload against the confirmed identity. If validation fails,
correct the data with the user and the Blitz setup form; never repair the script
by embedding user values in it.

## Authenticate and create

Blitz Neo manages the Apple web session. If no session exists, use `asc_web_auth`
and wait until it completes. Do not ask for an Apple ID email or read/copy/print
cookies yourself. Only the static script reads the session during `--create`.

After the identity is confirmed and app creation is authorized, run the same
command with `--create` instead of `--dry-run`. This performs a real Apple write.
The script rejects redirects and never logs session cookies. A successful POST
returns `created_pending_verification`, the app ID and `confirmationArguments`;
this is not final confirmation that all values match.

On 401, renew the existing web session with `asc_web_auth`. On 409, check whether
the intended app already exists before attempting any further creation. Never
change the SKU or public name automatically. After a timeout or incomplete
response, check Apple's state before retrying to avoid duplicate creation.

## Verify the actual Apple record

Call `asc_confirm_created_app` with **all** returned `confirmationArguments`:
`bundleId`, `expectedName`, `expectedSKU`, `expectedPlatform`, `expectedLocale`,
`projectId`, and `operationId`. Use the same arguments when verifying an existing
record after a conflict. Do not omit expectations or switch to another project
in order to make a mismatch pass.

Blitz compares the real Apple record with the confirmed identity and the original
project/account context. If verification fails or the context has changed, report
that explicitly and return to the original project/setup operation. Do not claim
success solely from the POST or echo expected values as if read back from Apple.

After verified success, report the actual app ID, public name, bundle ID, SKU,
platform and locale. Creating the record does not submit or publish the app.

## Account binding before creation

The confirmed JSON also carries nonsecret `expectedIssuerId` and `expectedKeyId`
from the selected Blitz API account. Never replace these with values from the web
session. Before POST, the script reads the key metadata with the same frozen web
cookies and verifies its key ID and provider/issuer ID. A missing, denied or
mismatched lookup stops creation. Sign in to the intended account or use the
manual instructions; do not bypass this check or omit these fields. The dry run
remains offline and does not read session cookies.
