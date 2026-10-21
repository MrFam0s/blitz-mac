#!/bin/bash
# Blitz Neo maintenance: retain the prior native app as a recoverable backup.
# User settings, credentials, projects and privacy grants are never changed here.
set -euo pipefail

NEW_APP="${1:?Pass the installed Blitz Neo app}"
LEGACY_APP="${2:?Pass the legacy Blitz app}"
BACKUP_ROOT="${3:?Pass the private backup directory}"

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Never retire the working app when the replacement is absent or incomplete.
if [ "$(bundle_id "$NEW_APP")" != "org.amosystems.BlitzNeo" ] || [ ! -x "$NEW_APP/Contents/MacOS/Blitz" ]; then
    echo "Blitz Neo replacement is missing or incomplete; legacy app retained." >&2
    exit 1
fi

# Only retire this fork's exact native predecessor, not unrelated apps or links.
if [ ! -d "$LEGACY_APP" ] || [ -L "$LEGACY_APP" ] || [ "$(bundle_id "$LEGACY_APP")" != "com.blitz.macos" ]; then
    exit 0
fi

umask 077
mkdir -p "$BACKUP_ROOT"
BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/Blitz-before-Neo.XXXXXX")"
if ! mv "$LEGACY_APP" "$BACKUP_DIR/Blitz.app"; then
    rmdir "$BACKUP_DIR" 2>/dev/null || true
    echo "Could not archive the legacy app; it was retained." >&2
    exit 1
fi
printf 'Previous Blitz app preserved at %s\n' "$BACKUP_DIR/Blitz.app"
