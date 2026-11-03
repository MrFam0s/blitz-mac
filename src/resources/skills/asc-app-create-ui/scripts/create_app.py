#!/usr/bin/env python3
"""Create an ASC app from confirmed JSON data, never from interpolated code."""
import argparse
import gzip
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request
import urllib.parse
from pathlib import Path

BASE_URL = "https://appstoreconnect.apple.com/iris/v1/"


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
    with opener.open(lookup, timeout=60) as response:
        key = read_body(response).get("data", {})
    provider = (key.get("attributes", {}).get("provider") or {}).get("id")
    if not provider:
        provider = ((key.get("relationships", {}).get("provider") or {}).get("data") or {}).get("id")
    if key.get("id") != identity["expectedKeyId"] or provider != identity["expectedIssuerId"]:
        raise IdentityError("The Apple web session does not match the confirmed App Store Connect account. No app was created; sign in to the intended account before retrying.")
    request = urllib.request.Request(BASE_URL + "apps", method="POST",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"), headers=headers)
    with opener.open(request, timeout=60) as response:
        result = read_body(response)
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
            result = {"status": "validated", "payload": build_payload(identity), "confirmationArguments": confirmation_arguments(identity)}
        else:
            result = create_app(identity, Path(os.path.expanduser("~/.blitz/asc-agent/web-session.json")))
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except urllib.error.HTTPError as error:
        # Never echo cookies or arbitrary response bodies into logs.
        if error.code == 401:
            message = "Web session expired. Complete asc_web_auth before retrying."
        elif error.code == 409:
            message = "Conflict. Check for the intended existing app; confirm any alternative name or SKU before retrying."
        else:
            message = "Apple rejected app creation. Inspect the account in App Store Connect before retrying."
        print(json.dumps({"status": "error", "httpStatus": error.code, "message": message}), file=sys.stderr)
    except IdentityError as error:
        print(json.dumps({"status": "error", "message": str(error)}), file=sys.stderr)
    except (ValueError, KeyError, OSError, urllib.error.URLError):
        # Session parsing and transport exceptions may contain credentials; keep them private.
        print(json.dumps({"status": "error", "message": "App creation stopped. Check the confirmed identity JSON and web-session availability; do not retry blindly."}), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
