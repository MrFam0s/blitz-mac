#!/usr/bin/env python3
"""Create an ASC app from confirmed JSON data, never from interpolated code."""
import argparse
import gzip
import io
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request
import urllib.parse
import zlib
from pathlib import Path

BASE_URL = "https://appstoreconnect.apple.com/iris/v1/"
MAX_ERROR_BODY_BYTES = 65536
MAX_ERROR_ENTRIES = 8
MAX_ERROR_TEXT_CHARACTERS = 512

# Only known identity pointers are exposed; arbitrary response objects and URLs
# never become diagnostics. Error prose is bounded and checked separately.
IDENTITY_FIELDS = {
    "name": "appName", "bundleId": "bundleId", "sku": "sku",
    "primaryLocale": "primaryLocale", "locale": "primaryLocale",
    "platform": "platform", "versionString": "versionString", "companyName": "companyName",
}
ERROR_POINTER = re.compile(
    r"^/(?:data/attributes|included/(?:[0-9]+|appInfoLocalizations|appStoreVersions|appStoreVersionLocalizations)(?:/attributes)?)/"
    r"(name|bundleId|sku|primaryLocale|locale|platform|versionString|companyName)$"
)
SENSITIVE_ERROR_TEXT = re.compile(
    r"-----BEGIN|(?:Bearer|Basic)\s+\S+|"
    r"(?:cookie|set-cookie|authorization|proxy-authorization|x-apple-[\w-]+|scnt|"
    r"session(?:id|token)?|password|passwd|private[\s_-]?key|access[\s_-]?token|"
    r"refresh[\s_-]?token|id[\s_-]?token|secret)\s*[:=]|"
    r"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\b|"
    r"https?://|[<>]",
    re.IGNORECASE,
)


def safe_error_text(value, secrets=()):
    if not isinstance(value, str) or not value:
        return None
    original = value
    # Remove invisible controls before checking for credential or markup text.
    value = " ".join("".join(c for c in value if not unicodedata.category(c).startswith("C") or c in "\n\r\t").split())
    # Never copy a cookie value echoed by Apple, even without its header name.
    if any(secret and (secret in original or secret in value) for secret in secrets) or SENSITIVE_ERROR_TEXT.search(value):
        return "[Sensitive or non-text error detail omitted]"
    return value[:MAX_ERROR_TEXT_CHARACTERS] or None


def apple_error_details(error):
    try:
        body = error.read(MAX_ERROR_BODY_BYTES + 1)
        if not body or len(body) > MAX_ERROR_BODY_BYTES:
            return []
        if body.startswith(b"\x1f\x8b"):
            with gzip.GzipFile(fileobj=io.BytesIO(body)) as compressed:
                body = compressed.read(MAX_ERROR_BODY_BYTES + 1)
            if len(body) > MAX_ERROR_BODY_BYTES:
                return []
        document = json.loads(body.decode("utf-8"))
        entries = document.get("errors") if isinstance(document, dict) else None
        if not isinstance(entries, list):
            return []
    except (ValueError, UnicodeError, OSError, EOFError, AttributeError, TypeError, zlib.error, RecursionError):
        return []
    finally:
        error.close()
    result = []
    secrets = getattr(error, "blitz_sensitive_values", ())
    for entry in entries[:MAX_ERROR_ENTRIES]:
        if not isinstance(entry, dict):
            continue
        item = {}
        code = entry.get("code")
        if (isinstance(code, str) and re.fullmatch(r"[A-Z][A-Z0-9_.-]{0,127}", code)
                and not any(secret and secret in code for secret in secrets)
                and not SENSITIVE_ERROR_TEXT.search(code)):
            item["code"] = code
        for field in ("title", "detail"):
            value = safe_error_text(entry.get(field), secrets)
            if value:
                item[field] = value
        source = entry.get("source")
        pointer = source.get("pointer") if isinstance(source, dict) else None
        if (isinstance(pointer, str) and len(pointer) <= 256 and ERROR_POINTER.fullmatch(pointer)
                and not any(secret and secret in pointer for secret in secrets)):
            item["source"] = {"pointer": pointer}
        if item:
            result.append(item)
    return result


def format_http_error(error):
    stage = getattr(error, "blitz_stage", "unknown")
    details = apple_error_details(error)
    if stage == "account_verification":
        message = "Apple rejected account verification. No app creation request was sent."
    elif stage == "app_creation" and error.code == 409:
        message = "Apple reported an app-creation conflict. Check the exact Apple error and existing records before retrying; do not change the confirmed identity automatically."
    else:
        message = "Apple rejected the request. Check the reported stage and Apple error before retrying."
    if error.code == 401:
        message += " The web session expired; complete asc_web_auth before retrying."
    result = {"status": "error", "httpStatus": error.code, "stage": stage,
              "creationAttempted": {"account_verification": False, "app_creation": True}.get(stage),
              "message": message}
    if details:
        result["appleErrors"] = details
    if stage == "app_creation" and error.code == 409:
        fields = []
        for item in details:
            pointer = item.get("source", {}).get("pointer", "")
            match = ERROR_POINTER.fullmatch(pointer)
            if match:
                field = IDENTITY_FIELDS[match.group(1)]
                if field not in fields:
                    fields.append(field)
        result["conflictFields"] = fields
    return result


def request_json(opener, request, stage, sensitive_values=()):
    try:
        with opener.open(request, timeout=60) as response:
            return read_body(response)
    except urllib.error.HTTPError as error:
        # Preserve the stage and redact known cookie values without exposing
        # request headers, the session or arbitrary response bodies.
        error.blitz_stage = stage
        error.blitz_sensitive_values = tuple(sensitive_values)
        raise


class IdentityError(ValueError):
    pass


def validate_identity(raw):
    if not isinstance(raw, dict):
        raise IdentityError("Identity must be a JSON object.")
    identity = dict(raw)
    for key in ("appName", "bundleId", "sku", "platform", "primaryLocale", "projectId", "operationId", "expectedIssuerId", "expectedKeyId"):
        value = identity.get(key)
        if not isinstance(value, str) or not value or value != value.strip():
            raise IdentityError(f"Confirm a nonempty {key} without surrounding whitespace.")
    if not 2 <= len(identity["appName"]) <= 30:
        raise IdentityError("The public app name must contain 2–30 characters.")
    if any(unicodedata.category(c) == "Cc" for c in identity["appName"]):
        raise IdentityError("The public app name must not contain control characters.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identity["bundleId"]):
        raise IdentityError("Confirm a bundle ID containing ASCII letters, digits, hyphens and nonempty dot-separated components.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", identity["sku"]):
        raise IdentityError("Confirm an alternative SKU: letters, digits, periods, hyphens and underscores only; start with a letter or digit.")
    if identity["platform"] not in ("iOS", "macOS"):
        raise IdentityError("Confirm the iOS or macOS project platform.")
    if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", identity["primaryLocale"]):
        raise IdentityError("Confirm a primary locale such as de-DE or en-US.")
    return identity


def build_payload(raw):
    identity = validate_identity(raw)
    locale = identity["primaryLocale"]
    return {
        "data": {
            "type": "apps",
            "attributes": {"bundleId": identity["bundleId"], "sku": identity["sku"], "primaryLocale": locale},
            "relationships": {
                "appStoreVersions": {"data": [{"type": "appStoreVersions", "id": "${new-appStoreVersion-1}"}]},
                "appInfos": {"data": [{"type": "appInfos", "id": "${new-appInfo-1}"}]},
            },
        },
        "included": [
            {"type": "appStoreVersions", "id": "${new-appStoreVersion-1}",
             "attributes": {"platform": {"iOS": "IOS", "macOS": "MAC_OS"}[identity["platform"]], "versionString": "1.0"},
             "relationships": {"appStoreVersionLocalizations": {"data": [{"type": "appStoreVersionLocalizations", "id": "${new-appStoreVersionLocalization-1}"}]}}},
            {"type": "appStoreVersionLocalizations", "id": "${new-appStoreVersionLocalization-1}", "attributes": {"locale": locale}},
            {"type": "appInfos", "id": "${new-appInfo-1}",
             "relationships": {"appInfoLocalizations": {"data": [{"type": "appInfoLocalizations", "id": "${new-appInfoLocalization-1}"}]}}},
            {"type": "appInfoLocalizations", "id": "${new-appInfoLocalization-1}", "attributes": {"locale": locale, "name": identity["appName"]}},
        ],
    }


def confirmation_arguments(identity):
    identity = validate_identity(identity)
    return {"bundleId": identity["bundleId"], "expectedName": identity["appName"],
            "expectedSKU": identity["sku"], "expectedPlatform": identity["platform"],
            "expectedLocale": identity["primaryLocale"], "projectId": identity["projectId"],
            "operationId": identity["operationId"]}


def read_body(response):
    data = response.read()
    if data.startswith(b"\x1f\x8b"):
        data = gzip.decompress(data)
    return json.loads(data.decode("utf-8"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise IdentityError("Unexpected redirect; app creation stopped.")


def create_app(identity, session_path, opener=None):
    # Validation deliberately precedes reading authentication or sending requests.
    payload = build_payload(identity)
    with session_path.open(encoding="utf-8") as handle:
        store = json.load(handle)
    session = store["sessions"][store["last_key"]]
    cookies = [cookie for group in session["cookies"].values() for cookie in group
               if cookie.get("name") and cookie.get("value")]
    cookie_header = "; ".join(
        f'{c["name"]}="{c["value"]}"' if c["name"].startswith("DES") else f'{c["name"]}={c["value"]}'
        for c in cookies
    )
    if not cookie_header:
        raise IdentityError("No web session cookies. Complete asc_web_auth first.")
    # Freeze one session for both account verification and creation. Never select
    # another last_key between these calls. Only nonsecret key metadata is fetched.
    opener = opener or urllib.request.build_opener(NoRedirect())
    headers = {"Content-Type": "application/json", "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest", "Origin": "https://appstoreconnect.apple.com",
        "Referer": "https://appstoreconnect.apple.com/", "Cookie": cookie_header}
    key_url = BASE_URL + "apiKeys/" + urllib.parse.quote(identity["expectedKeyId"], safe="") + "?include=provider"
    lookup = urllib.request.Request(key_url, method="GET", headers=headers)
    sensitive_values = [cookie["value"] for cookie in cookies]
    key = request_json(opener, lookup, "account_verification", sensitive_values).get("data", {})
    provider = (key.get("attributes", {}).get("provider") or {}).get("id")
    if not provider:
        provider = ((key.get("relationships", {}).get("provider") or {}).get("data") or {}).get("id")
    if key.get("id") != identity["expectedKeyId"] or provider != identity["expectedIssuerId"]:
        raise IdentityError("The Apple web session does not match the confirmed App Store Connect account. No app was created; sign in to the intended account before retrying.")
    request = urllib.request.Request(BASE_URL + "apps", method="POST",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"), headers=headers)
    result = request_json(opener, request, "app_creation", sensitive_values)
    app_id = result.get("data", {}).get("id")
    if not isinstance(app_id, str) or not app_id:
        raise IdentityError("Apple's response did not include an app ID. Check before retrying creation.")
    return {"status": "created_pending_verification", "appId": app_id,
            "confirmationArguments": confirmation_arguments(identity)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity-file", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Validate and print the payload without reading credentials or accessing Apple (default).")
    mode.add_argument("--create", action="store_true", help="Create the confirmed app at Apple. Do not retry blindly.")
    args = parser.parse_args(argv)
    try:
        with args.identity_file.open(encoding="utf-8") as handle:
            identity = validate_identity(json.load(handle))
        if not args.create:
            result = {"status": "validated", "validationScope": "local_identity_and_payload_only",
                      "appleAvailabilityChecked": False, "creationAttempted": False,
                      "payload": build_payload(identity), "confirmationArguments": confirmation_arguments(identity)}
        else:
            result = create_app(identity, Path(os.path.expanduser("~/.blitz/asc-agent/web-session.json")))
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except urllib.error.HTTPError as error:
        print(json.dumps(format_http_error(error), ensure_ascii=False), file=sys.stderr)
    except IdentityError as error:
        print(json.dumps({"status": "error", "message": str(error)}), file=sys.stderr)
    except (ValueError, KeyError, OSError, urllib.error.URLError):
        # Session parsing and transport exceptions may contain credentials; keep them private.
        print(json.dumps({"status": "error", "message": "App creation stopped. Check the confirmed identity JSON and web-session availability; do not retry blindly."}), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
