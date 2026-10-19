#!/usr/bin/env python3
"""Verify the bundled MCP's checksum and current source provenance without running it."""
from pathlib import Path
import hashlib,json,sys,tarfile
root=Path(__file__).resolve().parent.parent
package=Path(sys.argv[1])
expected=package.with_name(package.name+'.sha256').read_text().strip()
assert hashlib.sha256(package.read_bytes()).hexdigest()==expected, 'MCP package checksum mismatch'
with tarfile.open(package) as archive:
    manifest=json.load(archive.extractfile('package/package.json'))
    assert manifest['name']=='@blitzdev/iphone-mcp'
    assert manifest['version']=='0.1.18-blitz.1'
    lock=json.load(archive.extractfile('package/npm-shrinkwrap.json'))
    assert lock['version']==manifest['version']
    assert lock['packages']['']['dependencies']==manifest['dependencies']
    provenance=manifest['blitzMaintenance']
    assert provenance['upstreamCommit']=='3259f756279cd8cb6bc507b46369111fb5672fa2'
    assert provenance['overlaySHA256']==hashlib.sha256((root/'helpers/iphone-mcp-overlay/maintenance.patch').read_bytes()).hexdigest()
    for path in ['package/LICENSE','package/dist/cli.js','package/dist/idb/idb-client.js','package/dist/idb/simulator-env.js','package/dist/idb/type-text.py']:
        assert archive.getmember(path).isfile()
print('iPhone MCP 0.1.18-blitz.1: checksum and pinned source/overlay verified')
