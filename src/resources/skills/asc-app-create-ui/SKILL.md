---
name: asc-app-create-ui
description: Create an App Store Connect app via iris API using web session from Blitz Neo
---

<!-- Modified for the AmoSystems Blitz Neo maintenance fork (2026). -->

Create an App Store Connect app using Apple's iris API. Authentication is handled via a web session file at `~/.blitz/asc-agent/web-session.json` managed by Blitz Neo.

Extract from the conversation context:
- `bundleId` — the exact supplied bundle identifier, preserving capitalization (e.g. `org.amosystems.ClubBundle`); do not regenerate it from the app name or project folder
- `appName` — the confirmed public app name, which may differ from the project folder or bundle-ID suffix
- `platform` — the selected project platform (`iOS` or `macOS`); ask if it is unresolved
- `sku` — an explicitly selected SKU, or `<ConfirmedAppName>-<platform>` as resolved below

## Workflow

### 1. Check for an existing web session

```bash
test -f ~/.blitz/asc-agent/web-session.json && echo "SESSION_EXISTS" || echo "NO_SESSION"
```

- If `NO_SESSION`: call the `asc_web_auth` MCP tool first. Wait for it to complete before proceeding.
- If `SESSION_EXISTS`: proceed.

### 2. Ask the user for the primary language

Ask what primary language/locale the app should use. Common choices: `en-US` (English US), `en-GB` (English UK), `ja` (Japanese), `zh-Hans` (Simplified Chinese), `ko` (Korean), `fr-FR` (French), `de-DE` (German).

### 3. Confirm the public name, platform and SKU

Use the project context and the user's confirmed public app name. Do not infer a
replacement name from the project folder or bundle-ID suffix, which may retain
an old name. If the public name has not been confirmed, confirm it with the user.

Unless the user has explicitly selected an alternative, use the confirmed name
followed by `-iOS` or `-macOS` as the SKU (for example, `ClubBundle-iOS`). Preserve
capitalization and do not add random digits. If Apple rejects its characters or
reports a SKU conflict, ask the user for an alternative before trying again.
Use `IOS` for an iOS app or `MAC_OS` for a macOS app in the API payload.

### 4. Create the app via iris API

Use the following self-contained script. Replace `BUNDLE_ID`, `SKU`, `APP_NAME`, `LOCALE`, and `PLATFORM` with the resolved values. **Do not print or log cookies.**

Key differences from the public REST API:
- Uses `appstoreconnect.apple.com/iris/v1/` (not `api.appstoreconnect.apple.com`)
- Authenticated via web session cookies (not JWT)
- Uses `appInfos` relationship (not `bundleId` relationship)
- App name goes on `appInfoLocalizations` (not `appStoreVersionLocalizations`)
- Uses `${new-...}` placeholder IDs for inline-created resources

```bash
python3 -c "
import json, os, urllib.request, sys, gzip

def read_body(r):
    # iris may gzip responses even unasked; urllib does not decompress
    b = r.read()
    return (gzip.decompress(b) if b[:2] == bytes([31, 139]) else b).decode()

BUNDLE_ID = 'BUNDLE_ID_HERE'
SKU = 'SKU_HERE'
APP_NAME = 'APP_NAME_HERE'
LOCALE = 'LOCALE_HERE'
PLATFORM = 'PLATFORM_HERE'  # IOS or MAC_OS, matching the selected project
if PLATFORM not in ('IOS', 'MAC_OS'):
    print('ERROR: Resolve the selected project platform before app creation.')
    sys.exit(1)

session_path = os.path.expanduser('~/.blitz/asc-agent/web-session.json')
if not os.path.isfile(session_path):
    print('ERROR: No web session found. Call asc_web_auth MCP tool first.')
    sys.exit(1)
with open(session_path) as f:
    raw = f.read()

store = json.loads(raw)
session = store['sessions'][store['last_key']]
cookie_str = '; '.join(
    (f'{c[\"name\"]}=\"{c[\"value\"]}\"' if c['name'].startswith('DES') else f'{c[\"name\"]}={c[\"value\"]}')
    for cl in session['cookies'].values() for c in cl
    if c.get('name') and c.get('value')
)

headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest',
    'Origin': 'https://appstoreconnect.apple.com',
    'Referer': 'https://appstoreconnect.apple.com/',
    'Cookie': cookie_str
}

create_body = json.dumps({
    'data': {
        'type': 'apps',
        'attributes': {
            'bundleId': BUNDLE_ID,
            'sku': SKU,
            'primaryLocale': LOCALE,
        },
        'relationships': {
            'appStoreVersions': {
                'data': [{'type': 'appStoreVersions', 'id': '\${new-appStoreVersion-1}'}]
            },
            'appInfos': {
                'data': [{'type': 'appInfos', 'id': '\${new-appInfo-1}'}]
            }
        }
    },
    'included': [
        {
            'type': 'appStoreVersions',
            'id': '\${new-appStoreVersion-1}',
            'attributes': {'platform': PLATFORM, 'versionString': '1.0'},
            'relationships': {
                'appStoreVersionLocalizations': {
                    'data': [{'type': 'appStoreVersionLocalizations', 'id': '\${new-appStoreVersionLocalization-1}'}]
                }
            }
        },
        {
            'type': 'appStoreVersionLocalizations',
            'id': '\${new-appStoreVersionLocalization-1}',
            'attributes': {'locale': LOCALE}
        },
        {
            'type': 'appInfos',
            'id': '\${new-appInfo-1}',
            'relationships': {
                'appInfoLocalizations': {
                    'data': [{'type': 'appInfoLocalizations', 'id': '\${new-appInfoLocalization-1}'}]
                }
            }
        },
        {
            'type': 'appInfoLocalizations',
            'id': '\${new-appInfoLocalization-1}',
            'attributes': {'locale': LOCALE, 'name': APP_NAME}
        }
    ]
}).encode()

req = urllib.request.Request(
    'https://appstoreconnect.apple.com/iris/v1/apps',
    data=create_body, method='POST', headers=headers)
try:
    resp = urllib.request.urlopen(req)
    result = json.loads(read_body(resp))
    app_id = result['data']['id']
    print(f'App created successfully!')
    print(f'App ID: {app_id}')
    print(f'Bundle ID: {BUNDLE_ID}')
    print(f'Name: {APP_NAME}')
    print(f'SKU: {SKU}')
except urllib.error.HTTPError as e:
    body = read_body(e)
    if e.code == 401:
        print('ERROR: Session expired. Call asc_web_auth MCP tool to re-authenticate.')
    elif e.code == 409:
        print(f'ERROR: App may already exist or conflict. Details: {body[:500]}')
    else:
        print(f'ERROR creating app: HTTP {e.code} — {body[:500]}')
    sys.exit(1)
"
```

### 5. Auto-confirm the Blitz Neo bundle-ID setup flow

After the iris API call succeeds, call the `asc_confirm_created_app` MCP tool immediately. This tool polls App Store Connect up to 10 times and, once the app is visible, programmatically triggers the same confirmation path as the `Confirm` button in Blitz Neo's bundle-ID setup UI.

If the tool reports success, the manual confirmation step in Blitz Neo is complete. If it fails after 10 retries, report that clearly to the user.

### 6. Report results

After success, report the App ID, bundle ID, name, and SKU to the user.

## Common Errors

### 401 Not Authorized
Call the `asc_web_auth` MCP tool to open the Apple ID login window in Blitz Neo. Then retry.

### 409 Conflict
Inspect the conflict first: an app with the same bundle ID or SKU may already
exist. If the intended app already exists, confirm that record instead of
creating a duplicate. If the SKU must change, ask the user for an alternative;
do not silently append a suffix or retry with a generated SKU.

## Agent Behavior

- **Do NOT ask for Apple ID email** — authentication is handled via cached web session file, not email.
- **NEVER print, log, or echo session cookies.**
- Use the self-contained python script — do NOT extract cookies separately.
- If iris API returns 401, call `asc_web_auth` MCP tool and retry.
