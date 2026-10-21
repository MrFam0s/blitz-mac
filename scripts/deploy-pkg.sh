#!/bin/bash
# Modified for the AmoSystems Blitz Neo maintenance fork (2026).
# Deploy Blitz Neo installer and app archive to Cloudflare R2
# Usage: ./scripts/deploy-pkg.sh [--snapshot]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RCLONE="$ROOT_DIR/node_modules/@repalash/rclone.js/bin/rclone"

cleanup() {
    [ -n "${JSON_FILE:-}" ] && rm -f "$JSON_FILE"
    [ -n "${APP_ZIP:-}"   ] && rm -f "$APP_ZIP"
}
trap cleanup EXIT
JSON_FILE=""
APP_ZIP=""

# Load .env
if [ -f "$ROOT_DIR/.env" ]; then
    set -a; source "$ROOT_DIR/.env"; set +a
fi

# Validate
[ ! -x "$RCLONE" ] && echo "ERROR: rclone not found. Run 'npm install' first." && exit 1
: "${CLOUDFLARE_ACCOUNT_ID:?Set CLOUDFLARE_ACCOUNT_ID in .env}"
: "${R2_ACCESS_KEY_ID:?Set R2_ACCESS_KEY_ID in .env}"
: "${R2_SECRET_ACCESS_KEY:?Set R2_SECRET_ACCESS_KEY in .env}"

# R2 remote via env vars (no config file needed)
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_ENV_AUTH=false
export RCLONE_CONFIG_R2_REGION=auto

R2_BUCKET="${R2_BUCKET:-blitzapp-releases-1}"

# App metadata
APP_NAME="Blitz Neo"
ARTIFACT_NAME="BlitzNeo"
APP_ID="org.amosystems.BlitzNeo"
VERSION=$(node -e "const p=JSON.parse(require('fs').readFileSync('$ROOT_DIR/package.json','utf8')); process.stdout.write(p.version)" 2>/dev/null \
  || grep '"version"' "$ROOT_DIR/package.json" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')

# Parse args
SNAPSHOT=false
[ "${1:-}" = "--snapshot" ] && SNAPSHOT=true

# Resolve .pkg
PKG="$ROOT_DIR/build/$ARTIFACT_NAME-$VERSION.pkg"
[ ! -f "$PKG" ] && echo "ERROR: Expected $PKG but not found. Run 'npm run build:pkg' first." && exit 1

FILENAME=$(basename "$PKG")
CHECKSUM=$(shasum -a 256 "$PKG" | cut -d' ' -f1)
SIZE=$(stat -f%z "$PKG")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Deploying $FILENAME (v$VERSION, $SIZE bytes)"
echo "  checksum: $CHECKSUM"

# Zip .app for upload
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
APP_ZIP="$ROOT_DIR/build/$ARTIFACT_NAME-$VERSION.app.zip"
if [ -d "$APP_DIR" ]; then
    echo "Zipping $APP_NAME.app..."
    (cd "$(dirname "$APP_DIR")" && zip -qry "$APP_ZIP" "$(basename "$APP_DIR")")
    APP_ZIP_FILENAME=$(basename "$APP_ZIP")
    APP_CHECKSUM=$(shasum -a 256 "$APP_ZIP" | cut -d' ' -f1)
    APP_SIZE=$(stat -f%z "$APP_ZIP")
    echo "  app: $APP_ZIP_FILENAME ($APP_SIZE bytes)"
else
    echo "WARNING: $APP_DIR not found, skipping .app upload."
    APP_ZIP=""
fi

# Read changelog
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"
RELEASE_NOTES=""
if [ -f "$CHANGELOG_FILE" ]; then
    RELEASE_NOTES=$(sed -n "/^## $VERSION/,/^## /{/^## $VERSION/d;/^## /d;p;}" "$CHANGELOG_FILE" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/N;/^\n$/d')
    if [ -n "$RELEASE_NOTES" ]; then
        echo "  release notes: found"
    else
        echo "ERROR: No release notes found for v$VERSION in CHANGELOG.md."
        echo "  Add a section like:"
        echo ""
        echo "    ## $VERSION"
        echo "    - Your changes here"
        echo ""
        exit 1
    fi
else
    echo "ERROR: CHANGELOG.md not found at $CHANGELOG_FILE."
    exit 1
fi

# Build R2 path prefix
if [ "$SNAPSHOT" = true ]; then
    SNAP_ID="$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    PREFIX="apps/$APP_ID/snapshots/$SNAP_ID"
    echo "  snapshot: $SNAP_ID"
else
    PREFIX="apps/$APP_ID/releases/v$VERSION"
fi

# Version check (releases only — prevent downgrades)
if [ "$SNAPSHOT" = false ]; then
    LATEST_PATH="apps/$APP_ID/latest.json"
    EXISTING=$("$RCLONE" cat "r2:${R2_BUCKET}/${LATEST_PATH}" 2>/dev/null || echo '{}')
    EXISTING_VERSION=$(echo "$EXISTING" | grep -o '"version" *: *"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/' || echo "")

    if [ -n "$EXISTING_VERSION" ]; then
        IFS='.' read -r e_maj e_min e_pat <<< "$EXISTING_VERSION"
        IFS='.' read -r n_maj n_min n_pat <<< "$VERSION"
        e_num=$((e_maj * 10000 + e_min * 100 + e_pat))
        n_num=$((n_maj * 10000 + n_min * 100 + n_pat))
        if [ "$n_num" -le "$e_num" ]; then
            echo "ERROR: v$VERSION is not newer than existing v$EXISTING_VERSION. Bump version first."
            exit 1
        fi
        echo "  upgrading: v$EXISTING_VERSION -> v$VERSION"
    fi
fi

# Build release JSON
JSON_FILE="$(mktemp)"

RELEASE_NOTES_JSON=$(printf '%s' "$RELEASE_NOTES" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

APP_JSON=""
if [ -n "${APP_ZIP:-}" ]; then
    APP_JSON=$(cat << APPEOF
,
  "app": {
    "filename": "$APP_ZIP_FILENAME",
    "path": "$PREFIX/$APP_ZIP_FILENAME",
    "checksum_sha256": "$APP_CHECKSUM",
    "size": $APP_SIZE
  }
APPEOF
)
fi

cat > "$JSON_FILE" << EOF
{
  "version": "$VERSION",
  "filename": "$FILENAME",
  "path": "$PREFIX/$FILENAME",
  "platform": "macos",
  "arch": "universal",
  "checksum_sha256": "$CHECKSUM",
  "size": $SIZE,
  "timestamp": "$TIMESTAMP",
  "release_notes": $RELEASE_NOTES_JSON${APP_JSON}
}
EOF

echo "Uploading..."

echo "  $PREFIX/$FILENAME"
"$RCLONE" copyto "$PKG" "r2:${R2_BUCKET}/${PREFIX}/${FILENAME}" --s3-no-check-bucket --verbose || exit 1

if [ -n "${APP_ZIP:-}" ]; then
    echo "  $PREFIX/$APP_ZIP_FILENAME"
    "$RCLONE" copyto "$APP_ZIP" "r2:${R2_BUCKET}/${PREFIX}/${APP_ZIP_FILENAME}" --s3-no-check-bucket --verbose || exit 1
fi

echo "  $PREFIX/release.json"
"$RCLONE" copyto "$JSON_FILE" "r2:${R2_BUCKET}/${PREFIX}/release.json" --s3-no-check-bucket --verbose || exit 1

if [ "$SNAPSHOT" = false ]; then
    echo "  $LATEST_PATH"
    "$RCLONE" copyto "$JSON_FILE" "r2:${R2_BUCKET}/${LATEST_PATH}" --s3-no-check-bucket --verbose || exit 1
fi

echo "Done."
