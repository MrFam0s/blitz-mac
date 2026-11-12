#!/usr/bin/env python3
"""Verify checksum, lock, toolchain and pinned source without running the MCP."""
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'scripts/pkg-scripts'))
from iphone_mcp_archive import verify

verify(sys.argv[1], json.loads((root / 'config/node-toolchain.json').read_text()),
       root / 'helpers/iphone-mcp-overlay/maintenance.patch')
print('iPhone MCP 0.1.18-blitz.1: checksum, lock, toolchain and pinned source verified')
