#!/usr/bin/env python3
"""Normalize npm's file selection and explicitly ship the pinned dependency lock.

npm 12 only consumes package-lock.json and excludes both lock names from npm
pack. This private distribution is not published to npm: keep npm's selected
files, add the verified source package-lock.json, then checksum the final artifact.
"""
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / 'pkg-scripts'))
from iphone_mcp_archive import check_manifest, members, read_file


def pack(source, package, toolchain):
    source, package = Path(source), Path(package)
    lock = (source / 'package-lock.json').read_bytes()
    source_manifest = (source / 'package.json').read_bytes()
    check_manifest(json.loads(source_manifest), lock, toolchain)
    with tarfile.open(package, 'r:gz') as archive:
        inventory = members(archive)
        if read_file(archive, inventory, 'package.json') != source_manifest:
            raise ValueError('npm changed the source package manifest')
        files = {}
        for name, member in inventory.items():
            if member.isfile():
                files[name] = (archive.extractfile(member).read(), 0o755 if member.mode & 0o111 else 0o644)
        lock_name = 'package/package-lock.json'
        if lock_name in files and files[lock_name][0] != lock:
            raise ValueError('Packed lock differs from pinned source lock')
        legacy = files.pop('package/npm-shrinkwrap.json', None)
        if legacy is not None and legacy[0] != lock:
            raise ValueError('Ambiguous legacy dependency lock')
        files[lock_name] = (lock, 0o644)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=package.parent, prefix='.mcp-pack-', delete=False) as raw:
            temporary = Path(raw.name)
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as output:
                    for name, (data, mode) in sorted(files.items()):
                        info = tarfile.TarInfo(name)
                        info.size, info.mode, info.mtime = len(data), mode, 0
                        output.addfile(info, io.BytesIO(data))
        temporary.replace(package)
        Path(str(package) + '.sha256').write_text(hashlib.sha256(package.read_bytes()).hexdigest() + '\n')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    pack(sys.argv[1], sys.argv[2], json.loads(Path(sys.argv[3]).read_text()))
