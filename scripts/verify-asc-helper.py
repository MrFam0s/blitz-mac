"""Check Blitz's bundled ASC protocol/CLI contract without account access."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile

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
    assert len(responses) == 2 and all("error" not in r for r in responses), "RPC contract failed"
    results = {r["id"]: r["result"] for r in responses}
    ping, cli = results["ping"], results["cli"]
    assert ping["protocolVersion"] == "1" and not ping["sessionOpen"], "Unexpected protocol/session"
    assert ping["version"].startswith(version + " ") and commit in ping["version"], "ASC pin mismatch"
    assert cli["exitCode"] == 0 and cli["stdout"].strip() == ping["version"], "RPC CLI mismatch"
    direct = subprocess.run([binary, "__ascd_run_cli__", "version"], env=env,
                            text=True, capture_output=True, timeout=30, check=True)
    assert direct.stdout.strip() == ping["version"], "Direct CLI mismatch"
print(f"ASC {version}: pinned source, JSON-lines RPC and direct CLI verified (no account access).")
