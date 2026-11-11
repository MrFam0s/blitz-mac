#!/usr/bin/env python3
"""Create an ASC app from confirmed JSON data, never from interpolated code."""
import argparse
import fcntl
import gzip
import hashlib
import io
import json
import os
import re
import sys
import stat
import tempfile
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
        message += " Renew the web session with asc_web_auth; continuation depends on the recorded request stage."
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


def operation_state_directory():
    return Path.home() / ".blitz/asc-agent/app-creation-operations"


class CreationOperation:
    """Durable one-POST guard shared by every file carrying this operation ID.

    The lock is separate from the atomically replaced journal. Crashes and
    malformed state fail closed; only a proven pre-POST 401 permits one resume.
    This is not a replacement for checking the live Blitz confirmation context.
    """
    def __init__(self, identity, resume_after_auth=False, directory=None):
        self.identity = validate_identity(identity)
        self.digest = hashlib.sha256(json.dumps(self.identity, sort_keys=True,
            ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()
        directory = directory if directory is not None else operation_state_directory()
        key = hashlib.sha256(self.identity["operationId"].encode("utf-8")).hexdigest()
        self.path = directory / (key + ".json")
        self.lock_path = directory / (key + ".lock")
        self.resume_after_auth = resume_after_auth
        self.lock_fd = None
        self.state = None

    @staticmethod
    def private_regular_file(fd):
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise IdentityError("Unsafe app-creation operation file. Stop and review the operation.")

    def read_state(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            self.private_regular_file(handle.fileno())
            if os.fstat(handle.fileno()).st_size > 65536:
                raise IdentityError("Invalid app-creation operation state; no request was sent.")
            try:
                state = json.load(handle)
            except (ValueError, UnicodeError, RecursionError):
                raise IdentityError("Invalid app-creation operation state; no request was sent.") from None
        if (not isinstance(state, dict) or state.get("schemaVersion") != 1
                or state.get("identityDigest") != self.digest):
            raise IdentityError("The saved operation does not match the confirmed identity. No request was sent.")
        return state

    def write_state(self):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent,
                                             prefix=".creation-state-", delete=False) as handle:
                temporary = Path(handle.name)
                json.dump(self.state, handle, sort_keys=True)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
            directory_fd = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def __enter__(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.lock_fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            self.private_regular_file(self.lock_fd)
            try:
                fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise IdentityError("This app-creation operation is already running. No request was sent.") from None
            previous = self.read_state()
            if self.resume_after_auth:
                if (previous is None or previous.get("phase") != "awaiting_auth"
                        or previous.get("httpStatus") != 401
                        or previous.get("failureStage") != "account_verification"
                        or previous.get("creationAttempted") is not False
                        or type(previous.get("authResumptions")) is not int
                        or previous["authResumptions"] != 0):
                    raise IdentityError("Authentication continuation is not permitted for this operation. Do not retry creation.")
            elif previous is not None:
                raise IdentityError("This operation has already started. Only a recorded pre-creation 401 may use --resume-after-auth once; otherwise verify the existing outcome. Do not delete its journal or change its operation ID.")
            # Consume the initial attempt/resumption durably before any session
            # read or network work. A process crash cannot authorize a replay.
            self.state = {"schemaVersion": 1, "identityDigest": self.digest,
                "phase": "account_verification_in_progress", "creationAttempted": False,
                "authResumptions": 1 if self.resume_after_auth else 0}
            self.write_state()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *args):
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None

    def before_create(self):
        if self.state["creationAttempted"] or self.state["phase"] != "account_verification_in_progress":
            raise IdentityError("A creation request was already attempted. Do not retry creation.")
        self.state.update(phase="app_creation_in_progress", creationAttempted=True)
        self.write_state()

    def record_http_error(self, result):
        can_resume = (self.state["creationAttempted"] is False
            and self.state["authResumptions"] == 0
            and result.get("httpStatus") == 401
            and result.get("stage") == "account_verification"
            and result.get("creationAttempted") is False)
        self.state.update(phase="awaiting_auth" if can_resume else "stopped",
            httpStatus=result["httpStatus"], failureStage=result["stage"])
        self.write_state()
        result["recovery"] = {
            "action": "authenticate_then_resume_once" if can_resume else "stop_no_automatic_retry",
            "resumeAllowed": can_resume,
        }
        if can_resume:
            result["recovery"].update(resumeOption="--resume-after-auth",
                requiresUnchangedConfirmedOperation=True)

    def record_success(self):
        self.state.update(phase="created_pending_verification", creationAttempted=True)
        self.write_state()


def validate_identity(raw):
    if not isinstance(raw, dict):
        raise IdentityError("Identity must be a JSON object.")
    identity = dict(raw)
    if identity.get("creationMode", "newStoreApp") != "newStoreApp":
        raise IdentityError("This workflow only creates a new Store record. Add a platform to the existing Store app instead.")
    if "releaseTargetId" in identity and (not isinstance(identity["releaseTargetId"], str)
            or not identity["releaseTargetId"] or identity["releaseTargetId"] != identity["releaseTargetId"].strip()):
        raise IdentityError("Confirm the exact releaseTargetId.")
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
    result = {"bundleId": identity["bundleId"], "expectedName": identity["appName"],
            "expectedSKU": identity["sku"], "expectedPlatform": identity["platform"],
            "expectedLocale": identity["primaryLocale"], "projectId": identity["projectId"],
            "operationId": identity["operationId"]}
    if "releaseTargetId" in identity:
        result["releaseTargetId"] = identity["releaseTargetId"]
    return result


def read_body(response):
    data = response.read()
    if data.startswith(b"\x1f\x8b"):
        data = gzip.decompress(data)
    return json.loads(data.decode("utf-8"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise IdentityError("Unexpected redirect; app creation stopped.")


def create_app(identity, session_path, opener=None, before_create=None):
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
    if before_create is not None:
        before_create()
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
    mode.add_argument("--resume-after-auth", action="store_true", help="Resume once after a recorded pre-creation 401, successful asc_web_auth and unchanged live Blitz confirmation.")
    args = parser.parse_args(argv)
    try:
        with args.identity_file.open(encoding="utf-8") as handle:
            identity = validate_identity(json.load(handle))
        if not args.create and not args.resume_after_auth:
            result = {"status": "validated", "validationScope": "local_identity_and_payload_only",
                      "appleAvailabilityChecked": False, "creationAttempted": False,
                      "payload": build_payload(identity), "confirmationArguments": confirmation_arguments(identity)}
        else:
            with CreationOperation(identity, resume_after_auth=args.resume_after_auth) as operation:
                try:
                    result = create_app(identity, Path(os.path.expanduser("~/.blitz/asc-agent/web-session.json")),
                                        before_create=operation.before_create)
                except urllib.error.HTTPError as error:
                    result = format_http_error(error)
                    operation.record_http_error(result)
                    print(json.dumps(result, ensure_ascii=False), file=sys.stderr)
                    return 1
                operation.record_success()
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
