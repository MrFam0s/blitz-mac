# App Store Submission Pipeline

Fully automated pipeline to build, sign, upload, and submit an iOS app to the App Store — all from CLI with zero Xcode GUI interaction. Proven working on macOS with Xcode 26.1.1 and OpenSSL 3.6.0.

## Architecture

```
Blitz App (Swift)
  │
  ├─ ASC API (REST + JWT)  ──→  Certificates, Profiles, Metadata, Screenshots, Submission
  ├─ xcodebuild             ──→  Archive, Export IPA
  ├─ xcrun altool            ──→  Upload IPA to TestFlight
  └─ xcrun simctl            ──→  Simulator screenshots
```

## Prerequisites

| Requirement | How to check | Notes |
|---|---|---|
| Xcode (14+) | `xcodebuild -version` | Must be installed, not just CLI tools |
| Node.js | `node --version` | Used for JWT generation (ES256 signing) |
| OpenSSL 3.x | `openssl version` | Homebrew version; needed for `-legacy` p12 flag |
| ASC API Key (.p8) | Stored in `~/.blitz/{projectId}/asc-credentials.json` | Admin role required |
| Apple Developer Account | Member of Apple Developer Program | $99/year enrollment |

### Credentials file format (`asc-credentials.json`)

```json
{
  "issuerId": "ce69cf18-497f-451c-...",
  "keyId": "C86Q7ZJ3YC",
  "privateKey": "-----BEGIN PRIVATE KEY-----\nMIGT..."
}
```

---

## Phase 0: JWT Generation

All ASC API calls require a JWT bearer token signed with the .p8 key.

**Algorithm:** ES256 (ECDSA with P-256 and SHA-256)

```javascript
const crypto = require('crypto');
const now = Math.floor(Date.now() / 1000);
const header = Buffer.from(JSON.stringify({
  alg: 'ES256', kid: KEY_ID, typ: 'JWT'
})).toString('base64url');
const payload = Buffer.from(JSON.stringify({
  iss: ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1'
})).toString('base64url');

const signingInput = header + '.' + payload;
const sign = crypto.createSign('SHA256');
sign.update(signingInput);
const derSig = sign.sign({ key: PRIVATE_KEY, dsaEncoding: 'der' });

// Convert DER to raw r||s format for JWT
const r = derSig.slice(derSig[3] === 32 ? 4 : 5, derSig[3] === 32 ? 36 : 37);
const sOffset = 2 + derSig[1] - 32;
const s = derSig.slice(sOffset);
const rawSig = Buffer.concat([r.slice(-32), s.slice(-32)]);

const jwt = signingInput + '.' + rawSig.toString('base64url');
```

**Token lifetime:** 20 minutes max. Generate fresh for each batch of API calls.

---

## Phase 1: Signing Infrastructure Setup

One-time setup per bundle ID. Can be cached/reused until certificates expire.

### Step 1.1: Register Bundle ID (if needed)

```
POST https://api.appstoreconnect.apple.com/v1/bundleIds
```

```json
{
  "data": {
    "type": "bundleIds",
    "attributes": {
      "identifier": "com.example.myapp",
      "name": "My App",
      "platform": "IOS"
    }
  }
}
```

**Check first:** `GET /v1/bundleIds?filter[identifier]=com.example.myapp`

### Step 1.2: Create Distribution Certificate

Generate a local RSA key + CSR, then POST to Apple.

```bash
# Generate private key (keep this — needed for code signing)
openssl genrsa -out dist_cert_key.pem 2048

# Generate CSR
openssl req -new -key dist_cert_key.pem -out dist_cert.csr \
  -subj "/CN=Your Name/O=TEAM_ID/C=US"
```

```
POST https://api.appstoreconnect.apple.com/v1/certificates
```

```json
{
  "data": {
    "type": "certificates",
    "attributes": {
      "certificateType": "DISTRIBUTION",
      "csrContent": "<raw PEM CSR content>"
    }
  }
}
```

**Response contains:** `data.id` (cert resource ID) and `data.attributes.certificateContent` (base64-encoded DER certificate).

### Step 1.3: Install Certificate in Keychain

```bash
# Decode the cert from API response
echo "$CERT_B64" | base64 -d > dist_cert.cer

# Convert DER to PEM
openssl x509 -inform DER -in dist_cert.cer -out dist_cert_pem.cer

# Create p12 bundle (MUST use -legacy for OpenSSL 3.x + macOS keychain)
openssl pkcs12 -export -out dist_cert.p12 \
  -inkey dist_cert_key.pem \
  -in dist_cert_pem.cer \
  -passout pass:temp123 \
  -legacy

# Import into login keychain
security import dist_cert.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P "temp123" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
```

**Verify:** `security find-identity -v -p codesigning | grep "Apple Distribution"`

**Critical:** The `-legacy` flag is required for OpenSSL 3.x. Without it, macOS keychain rejects the p12 with "MAC verification failed."

### Step 1.4: Create App Store Provisioning Profile

```
POST https://api.appstoreconnect.apple.com/v1/profiles
```

```json
{
  "data": {
    "type": "profiles",
    "attributes": {
      "name": "MyApp AppStore Profile",
      "profileType": "IOS_APP_STORE"
    },
    "relationships": {
      "bundleId": {
        "data": { "type": "bundleIds", "id": "<BUNDLE_ID_RESOURCE_ID>" }
      },
      "certificates": {
        "data": [{ "type": "certificates", "id": "<DIST_CERT_ID>" }]
      }
    }
  }
}
```

**Note:** `IOS_APP_STORE` profiles do NOT include devices (unlike `IOS_APP_DEVELOPMENT`).

### Step 1.5: Install Provisioning Profile

```bash
# Download profile content from API response
echo "$PROFILE_B64" | base64 -d > profile.mobileprovision

# Extract UUID
PROFILE_UUID=$(security cms -D -i profile.mobileprovision | plutil -extract UUID raw -)

# Install
mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
cp profile.mobileprovision \
  ~/Library/MobileDevice/Provisioning\ Profiles/${PROFILE_UUID}.mobileprovision
```

---

## Phase 2: Configure Xcode Project

Modify `project.pbxproj` to enable automatic signing with the team.

### Step 2.1: Set Team + Automatic Signing in TargetAttributes

Find the target ID (e.g. `13B07F861A680F5B00A75B9A`) in the `TargetAttributes` section and add:

```
DevelopmentTeam = <TEAM_ID>;
ProvisioningStyle = Automatic;
```

### Step 2.2: Add to Build Configurations (Debug + Release)

For each target build configuration, add:

```
CODE_SIGN_STYLE = Automatic;
DEVELOPMENT_TEAM = <TEAM_ID>;
```

### Step 2.3: Set Bundle Identifier

Replace placeholder bundle ID in both Debug and Release configurations:

```
PRODUCT_BUNDLE_IDENTIFIER = com.example.myapp;
```

**Implementation:** Use `sed` on `project.pbxproj`. The file is plain text (old-style plist), not XML.

```bash
PBXPROJ="ios/BlitzApp.xcodeproj/project.pbxproj"
TEAM_ID="YOUR_TEAM_ID"
BUNDLE_ID="com.example.myapp"

# TargetAttributes
sed -i '' 's/<TARGET_ID> = {/<TARGET_ID> = {\
						DevelopmentTeam = '"$TEAM_ID"';\
						ProvisioningStyle = Automatic;/' "$PBXPROJ"

# Build configurations (find the target configs, not project-level)
# Add after CURRENT_PROJECT_VERSION in each target config
sed -i '' '/<TARGET_CONFIG_ID> \/\* Debug \*\//,/name = Debug;/{
  s/CURRENT_PROJECT_VERSION = 1;/CURRENT_PROJECT_VERSION = 1;\
				CODE_SIGN_STYLE = Automatic;\
				DEVELOPMENT_TEAM = '"$TEAM_ID"';/
}' "$PBXPROJ"

# Bundle ID
sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = .*;/PRODUCT_BUNDLE_IDENTIFIER = '"$BUNDLE_ID"';/g' "$PBXPROJ"
```

---

## Phase 3: Build & Export IPA

### Step 3.1: Archive

```bash
xcodebuild \
  -workspace ios/BlitzApp.xcworkspace \
  -scheme BlitzApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/BlitzApp.xcarchive \
  -allowProvisioningUpdates \
  archive
```

**Timeout:** ~2-5 minutes depending on project size. React Native projects are slower due to Hermes compilation.

### Step 3.2: Create ExportOptions.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
```

### Step 3.3: Export IPA

```bash
xcodebuild -exportArchive \
  -archivePath /tmp/BlitzApp.xcarchive \
  -exportPath /tmp/BlitzAppIPA \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates
```

**Output:** `BlitzApp.ipa` (~10MB for a basic React Native app)

---

## Phase 4: Upload to TestFlight

```bash
xcrun altool --upload-app \
  -f /tmp/BlitzAppIPA/BlitzApp.ipa \
  --type ios \
  --apiKey <KEY_ID> \
  --apiIssuer <ISSUER_ID>
```

**API key location:** altool looks for `.p8` files in:
- `./private_keys/`
- `~/private_keys/`
- `~/.private_keys/`
- `~/.appstoreconnect/private_keys/`

Place the key as `AuthKey_<KEY_ID>.p8` in one of these directories.

**Processing time:** After upload, Apple processes the build (5-30 minutes). Poll build status:

```
GET /v1/builds?filter[app]=<APP_ID>&sort=-uploadedDate&limit=1
```

Wait for `processingState` to change from `PROCESSING` to `VALID`.

---

## Phase 5: Screenshots

### Step 5.1: Required Sizes (2025+)

Only two sizes are mandatory. Apple auto-scales for smaller devices.

| Display Size | Device | Resolution | Required |
|---|---|---|---|
| 6.9" iPhone | iPhone 16 Pro Max | 1320 x 2868 | Yes |
| 13" iPad | iPad Pro 13" | 2064 x 2752 | Only if universal app |

Min 1, max 10 screenshots per device size.

### Step 5.2: Capture from Simulator

```bash
# Boot the right simulator (6.9" = iPhone 16 Pro Max)
UDID="8B6603C0-F3AD-469A-9CE1-6B1F15F8A945"  # iPhone 16 Pro Max
xcrun simctl boot $UDID

# Wait for boot
xcrun simctl bootstatus $UDID

# Install the app
xcrun simctl install $UDID /path/to/BlitzApp.app

# Launch the app
xcrun simctl launch $UDID bliz-test

# Take screenshot
xcrun simctl io $UDID screenshot /tmp/screenshot_1.png
```

**For navigating the app between screenshots:** Use Blitz's existing MCP device interaction tools (`device_action` tap/swipe) or simctl's input commands.

### Step 5.3: Upload Screenshots via ASC API

```
# 1. Create screenshot set for the localization
POST /v1/appScreenshotSets
{
  "data": {
    "type": "appScreenshotSets",
    "attributes": {
      "screenshotDisplayType": "APP_IPHONE_67"  # 6.9" display
    },
    "relationships": {
      "appStoreVersionLocalization": {
        "data": { "type": "appStoreVersionLocalizations", "id": "<LOC_ID>" }
      }
    }
  }
}

# 2. Reserve screenshot upload
POST /v1/appScreenshots
{
  "data": {
    "type": "appScreenshots",
    "attributes": {
      "fileName": "screenshot_1.png",
      "fileSize": <SIZE_IN_BYTES>
    },
    "relationships": {
      "appScreenshotSet": {
        "data": { "type": "appScreenshotSets", "id": "<SET_ID>" }
      }
    }
  }
}

# 3. Upload the image data to the URL from the reservation response
# Response includes uploadOperations[].url and uploadOperations[].requestHeaders

# 4. Commit the upload
PATCH /v1/appScreenshots/<SCREENSHOT_ID>
{
  "data": {
    "type": "appScreenshots",
    "id": "<SCREENSHOT_ID>",
    "attributes": {
      "uploaded": true,
      "sourceFileChecksum": "<MD5_OF_FILE>"
    }
  }
}
```

**Screenshot display types:**
- `APP_IPHONE_67` — large iPhone display
- `APP_IPHONE_DUO` — outer display (1398×2034) and inner display (2007×2853), including their landscape dimensions. Both displays share one set per localization. Apple requires Duo screenshots starting in April 2027 for apps built with the iOS 27.1 SDK or later. [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- `APP_IPAD_PRO_3GEN_129` — 12.9" iPad Pro (if universal)

---

## Phase 6: Metadata

### Step 6.1: Set App Store Version Localizations

```
# Get the latest version
GET /v1/apps/<APP_ID>/appStoreVersions?limit=1

# Get localizations for that version
GET /v1/appStoreVersions/<VERSION_ID>/appStoreVersionLocalizations

# Update metadata
PATCH /v1/appStoreVersionLocalizations/<LOC_ID>
{
  "data": {
    "type": "appStoreVersionLocalizations",
    "id": "<LOC_ID>",
    "attributes": {
      "description": "App description here...",
      "keywords": "keyword1, keyword2, keyword3",
      "whatsNew": "Bug fixes and improvements",
      "supportUrl": "https://example.com/support",
      "marketingUrl": "https://example.com"
    }
  }
}
```

---

## Phase 7: Select Build & Submit for Review

### Step 7.1: Set Encryption Compliance

Skip the compliance prompt by declaring no exempt encryption:

```
PATCH /v1/builds/<BUILD_ID>
{
  "data": {
    "type": "builds",
    "id": "<BUILD_ID>",
    "attributes": {
      "usesNonExemptEncryption": false
    }
  }
}
```

**Alternative:** Add `ITSAppUsesNonExemptEncryption = NO` to Info.plist before building.

### Step 7.2: Link Build to Version

```
PATCH /v1/appStoreVersions/<VERSION_ID>
{
  "data": {
    "type": "appStoreVersions",
    "id": "<VERSION_ID>",
    "relationships": {
      "build": {
        "data": { "type": "builds", "id": "<BUILD_ID>" }
      }
    }
  }
}
```

### Step 7.3: Required metadata before submission

All of these must be set or the submission will be blocked:

```
# Copyright + content rights
PATCH /v1/appStoreVersions/<VERSION_ID>
{ "attributes": { "copyright": "2026 Your Name" } }

PATCH /v1/apps/<APP_ID>
{ "attributes": { "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT" } }

# Privacy policy URL (on app info localization)
PATCH /v1/appInfoLocalizations/<APP_INFO_LOC_ID>
{ "attributes": { "privacyPolicyUrl": "https://example.com/privacy" } }

# Primary category
PATCH /v1/appInfos/<APP_INFO_ID>
{ "attributes": { "primaryCategory": "UTILITIES" } }
```

### Step 7.4: Age Rating Declarations

All fields are required — none can be null:

```
PATCH /v1/ageRatingDeclarations/<AGE_RATING_ID>
{
  "attributes": {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gambling": false,
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "messagingAndChat": false,
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "unrestrictedWebAccess": false,
    "userGeneratedContent": false,
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "advertising": false,
    "lootBox": false,
    "healthOrWellnessTopics": false,
    "parentalControls": false,
    "ageAssurance": false
  }
}
```

**Note:** `ageAssurance` is a boolean (not a string). The `ageRatingDeclaration` ID is the same as the `appInfo` ID.

### Step 7.5: App Store Review Detail

```
POST /v1/appStoreReviewDetails
{
  "data": {
    "type": "appStoreReviewDetails",
    "attributes": {
      "contactFirstName": "First",
      "contactLastName": "Last",
      "contactPhone": "+1 650 555 0100",
      "contactEmail": "you@example.com",
      "demoAccountRequired": false,
      "notes": "Simple app. No login required."
    },
    "relationships": {
      "appStoreVersion": {
        "data": { "type": "appStoreVersions", "id": "<VERSION_ID>" }
      }
    }
  }
}
```

**Note:** Phone must be `+<countryCode> <area> <number>` format. Empty strings for `demoAccountName`/`demoAccountPassword` will cause 409 — omit them if not needed.

### Step 7.6: Pricing (required even for free apps)

```
POST /v1/appPriceSchedules
{
  "data": {
    "type": "appPriceSchedules",
    "relationships": {
      "app": { "data": { "type": "apps", "id": "<APP_ID>" } },
      "baseTerritory": { "data": { "type": "territories", "id": "USA" } },
      "manualPrices": {
        "data": [{ "type": "appPrices", "id": "${p0}" }]
      }
    }
  },
  "included": [{
    "type": "appPrices",
    "id": "${p0}",
    "attributes": { "startDate": null, "endDate": null },
    "relationships": {
      "appPricePoint": {
        "data": { "type": "appPricePoints", "id": "<FREE_PRICE_POINT_ID>" }
      },
      "territory": { "data": { "type": "territories", "id": "USA" } }
    }
  }]
}
```

**Get free price point ID:**
```
GET /v1/apps/<APP_ID>/appPricePoints?filter[territory]=USA&limit=3
```
The first result with `customerPrice: "0.0"` is the free tier.

**Critical:** The relationship type must be `"appPrices"` (NOT `"appManualPrices"` — despite the relationship being called `manualPrices`).

### Step 7.7: Privacy Nutrition Labels (MANUAL — one-time only)

**⚠️ Not available in the REST API.** Must be completed in the App Store Connect web UI before first submission:

1. Go to `https://appstoreconnect.apple.com/apps/<APP_ID>/distribution/privacy`
2. Complete the App Privacy questionnaire (answer "No" to all for a non-collecting app)
3. Click **Publish**

Once published, this is retained for future updates unless your data practices change.

### Step 7.8: Submit for Review (new reviewSubmissions API)

**Note:** `POST /v1/appStoreVersionSubmissions` is deprecated and returns 403. Use the newer `reviewSubmissions` flow:

```
# 1. Create review submission
POST /v1/reviewSubmissions
{
  "data": {
    "type": "reviewSubmissions",
    "attributes": { "platform": "IOS" },
    "relationships": {
      "app": { "data": { "type": "apps", "id": "<APP_ID>" } }
    }
  }
}
# Returns reviewSubmission ID and state READY_FOR_REVIEW

# 2. Add version to submission
POST /v1/reviewSubmissionItems
{
  "data": {
    "type": "reviewSubmissionItems",
    "relationships": {
      "appStoreVersion": {
        "data": { "type": "appStoreVersions", "id": "<VERSION_ID>" }
      },
      "reviewSubmission": {
        "data": { "type": "reviewSubmissions", "id": "<REVIEW_SUB_ID>" }
      }
    }
  }
}
# Returns item with state READY_FOR_REVIEW

# 3. Submit
PATCH /v1/reviewSubmissions/<REVIEW_SUB_ID>
{
  "data": {
    "type": "reviewSubmissions",
    "id": "<REVIEW_SUB_ID>",
    "attributes": { "submitted": true }
  }
}
# Returns state WAITING_FOR_REVIEW ✅
```

**If POST reviewSubmissionItems returns 409 with associatedErrors:** Fix each error in the `associatedErrors` map before retrying. Common ones:
- `/v1/appDataUsages/` → complete privacy questionnaire in web UI
- `/v2/appPrices/` → set pricing via appPriceSchedules POST
- Missing metadata fields → patch them individually

---

## Implementation Plan for Blitz

### What to build as native Swift (AppStoreConnectService)

These are straightforward API calls, fast, and benefit from being always available:

- JWT generation (port Node.js crypto to Swift `CryptoKit` / `Security` framework)
- All ASC API calls (metadata, screenshots, versions, submissions)
- Certificate creation + keychain installation
- Provisioning profile creation + installation
- Build status polling

### What to build as CLI wrappers (ProcessRunner)

These are long-running shell processes:

- `xcodebuild archive` (2-5 min)
- `xcodebuild -exportArchive` (30s)
- `xcrun altool --upload-app` (1-5 min)
- `xcrun simctl` screenshot capture

### What to expose as MCP tools

For AI agent-driven submission:

- `app_store_setup_signing` — Creates cert + profile + configures project (Phase 1+2)
- `app_store_build` — Archive + export IPA (Phase 3)
- `app_store_upload` — Upload to TestFlight (Phase 4)
- `app_store_capture_screenshots` — Boot sim + capture screenshots (Phase 5.1-5.2)
- `app_store_upload_screenshots` — Upload to ASC (Phase 5.3)
- `app_store_set_metadata` — Fill in all metadata fields (Phase 6)
- `app_store_submit` — Select build + submit for review (Phase 7)
- `app_store_status` — Check review/processing status

---

## Gotchas & Edge Cases

| Issue | Solution |
|---|---|
| OpenSSL 3.x p12 rejected by macOS keychain | Use `-legacy` flag on `openssl pkcs12 -export` |
| `altool` can't find .p8 key | Place `AuthKey_<KEY_ID>.p8` in `~/.private_keys/` or `~/.appstoreconnect/private_keys/` |
| Simulator screenshot wrong resolution | Must use exact device (iPhone 16 Pro Max for 6.9") — iPhone 15 is only 1179x2556 |
| Build stuck in PROCESSING | Poll `/v1/builds` every 30s, timeout after 30 min |
| "No profiles found" on export | Profile must be installed in `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision` |
| `DEVELOPMENT_TEAM` not set | Must be in both `TargetAttributes` and each target's `buildSettings` sections |
| Bundle ID mismatch | Must match exactly between pbxproj, ASC registered ID, and provisioning profile |
| JWT expired during long build | Generate new JWT for each API call batch; 20-min max lifetime |
| Warm template uses placeholder bundle ID | `dev.blitz.mac.warm` must be replaced during project setup |

---

## Phase 4 Extra: App Icon Requirements

Apple rejects uploads missing app icons. The warm template ships with an empty `AppIcon.appiconset` (just `Contents.json`, no PNGs). Must be fixed before upload.

### Generate icons programmatically (no design tool needed)

```python
# Generate a 1024x1024 base PNG using only Python stdlib
import struct, zlib

def make_png(w, h, r, g, b):
    def chunk(name, data):
        c = zlib.crc32(name + data) & 0xffffffff
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', c)
    rows = b''.join(b'\x00' + bytes([r, g, b, 255]) * w for _ in range(h))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows))
            + chunk(b'IEND', b''))

open('/tmp/icon_1024.png', 'wb').write(make_png(1024, 1024, 30, 130, 210))
```

```bash
# Resize to all required sizes using sips (built-in macOS)
ICONDIR="ios/BlitzApp/Images.xcassets/AppIcon.appiconset"
for SIZE in 20 29 40 60 76 83 1024; do
  for SCALE in 1 2 3; do
    PX=$((SIZE * SCALE))
    sips -z $PX $PX /tmp/icon_1024.png \
      --out "$ICONDIR/icon_${SIZE}x${SIZE}@${SCALE}x.png" 2>/dev/null
  done
done
```

### Required Contents.json entries

Must include `filename` for every slot, otherwise Xcode compiles the catalog but produces no icons:

```json
{ "filename": "icon_60x60@2x.png", "idiom": "iphone", "scale": "2x", "size": "60x60" },
{ "filename": "icon_60x60@3x.png", "idiom": "iphone", "scale": "3x", "size": "60x60" },
{ "filename": "icon_1024x1024@1x.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024" }
```

### CFBundleIconName in Info.plist

```bash
plutil -insert CFBundleIconName -string "AppIcon" ios/BlitzApp/Info.plist
```

Without this, Apple returns: `Missing Info.plist value. A value for the Info.plist key 'CFBundleIconName' is missing`.

---

## Phase 4 Extra: xcworkspace Missing After Project Creation

React Native projects require `pod install` to generate the `.xcworkspace`. If the workspace doesn't exist:

```bash
cd ios && pod install
```

The warm template has `Podfile.lock` and a `Pods/` directory but `xcworkspace` is NOT committed/copied. Always regenerate it after copying the template to a new project.

---

## Verified Working (March 2026)

Tested fully end-to-end:
- macOS 25.1.0 (Darwin)
- Xcode 26.1.1
- OpenSSL 3.6.0
- React Native 0.79 project (BlitzApp warm template)
- Team ID: `YOUR_TEAM_ID`
- Bundle ID: `your.bundle.id`
- Distribution cert: created via API
- App Store provisioning profile: created via API
- IPA: ~10MB
- **Upload: SUCCEEDED**
- **App Store Submission: SUCCEEDED**

### altool auth note

Use `--apiKey` + `--apiIssuer` with Team Keys (not Individual Keys). Place the `.p8` file in `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` before calling altool.

### Pricing note

`POST /v2/appPriceSchedules` (v2) returns 404. Use `POST /v1/appPriceSchedules` with type `"appPrices"` in both the `manualPrices` relationship data and the `included` array.

### Privacy labels note

`/v1/appDataUsages` does not exist in the REST API (confirmed against Apple's official OpenAPI spec). This step cannot be automated — it requires the web UI one time per app.
