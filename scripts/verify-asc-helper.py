"""Check Blitz's bundled ASC protocol/CLI contract without account access."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise SystemExit(message)


binary = str(Path(sys.argv[1]).resolve())
build_script = (Path(__file__).resolve().parent / "build-asc-helper.sh").read_text()
version = re.search(r'^ASC_VERSION="([^"]+)"$', build_script, re.M)[1]
commit = re.search(r'^ASC_COMMIT="([^"]+)"$', build_script, re.M)[1]
with tempfile.TemporaryDirectory(prefix="blitz-asc-smoke-") as isolated:
    env = {k: v for k, v in os.environ.items() if not k.startswith("ASC_")}
    env.update(ASC_CONFIG_PATH=str(Path(isolated) / "absent-config.json"),
               ASC_BYPASS_KEYCHAIN="1", ASC_TELEMETRY_DISABLED="1", ASC_SKILLS_AUTO_CHECK="0")
    requests = [{"id": "ping", "method": "ping"},
                {"id": "cli", "method": "cli.exec", "params": {"args": ["version"]}}]
    rpc = subprocess.run([binary], input="".join(json.dumps(r) + "\n" for r in requests),
                         text=True, capture_output=True, env=env, timeout=30, check=True)
    responses = [json.loads(line) for line in rpc.stdout.splitlines()]
    require(len(responses) == 2 and all("error" not in r for r in responses), "RPC contract failed")
    results = {r["id"]: r["result"] for r in responses}
    ping, cli = results["ping"], results["cli"]
    require("release.chinaCompliance" in ping.get("capabilities", []), "ASC helper lacks regional release readiness")
    require("store.chinaForms" in ping.get("capabilities", []), "ASC helper lacks provider-bound China declarations")
    require(ping["protocolVersion"] == "1" and not ping["sessionOpen"], "Unexpected protocol/session")
    require(ping["version"].startswith(version + " ") and commit in ping["version"], "ASC pin mismatch")
    require(cli["exitCode"] == 0 and cli["stdout"].strip() == ping["version"], "RPC CLI mismatch")
    direct = subprocess.run([binary, "__ascd_run_cli__", "version"], env=env,
                            text=True, capture_output=True, timeout=30, check=True)
    require(direct.stdout.strip() == ping["version"], "Direct CLI mismatch")
    edit_help = subprocess.run([binary, "__ascd_run_cli__", "age-rating", "edit", "--help"], env=env,
                               text=True, capture_output=True, timeout=30, check=True)
    help_text = edit_help.stdout + edit_help.stderr
    require(all(flag in help_text for flag in ("--shared-location", "--dating-and-relationships")),
            "ASC helper lacks the current age-rating questionnaire")
print(f"ASC {version}: pinned source, JSON-lines RPC and direct CLI verified (no account access).")
