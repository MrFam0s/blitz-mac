"""Validated, locked iPhone MCP distribution used by the builder and installer."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

VERSION = '0.1.18-blitz.1'
COMMIT = '3259f756279cd8cb6bc507b46369111fb5672fa2'


def members(archive):
    result = {}
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        name = member.name.rstrip('/')
        if (path.is_absolute() or '..' in path.parts or not path.parts
                or path.parts[0] != 'package' or name in result
                or not (member.isfile() or member.isdir())
                or member.size > 32 * 1024 * 1024
                or any(part in ('node_modules', '.git') for part in path.parts)):
            raise ValueError('Unsafe or duplicate MCP archive member')
        if str(path) != name:
            raise ValueError('Non-canonical MCP archive member')
        result[name] = member
    if sum(member.size for member in result.values()) > 64 * 1024 * 1024:
        raise ValueError('MCP archive exceeds size limit')
    return result


def read_file(archive, inventory, name):
    member = inventory.get('package/' + name)
    if member is None or not member.isfile():
        raise ValueError('Missing MCP archive file: ' + name)
    return archive.extractfile(member).read()


def check_manifest(manifest, lock_bytes, toolchain):
    if manifest.get('name') != '@blitzdev/iphone-mcp' or manifest.get('version') != VERSION:
        raise ValueError('Unexpected MCP identity')
    lock = json.loads(lock_bytes)
    if (lock.get('lockfileVersion') != 3 or lock.get('name') != manifest['name']
            or lock.get('version') != VERSION
            or lock.get('packages', {}).get('', {}).get('dependencies') != manifest.get('dependencies')):
        raise ValueError('MCP dependency lock does not match manifest')
    if manifest.get('allowScripts') != {'unix-dgram@2.0.7': True}:
        raise ValueError('Unexpected native build permission')
    provenance = manifest.get('blitzMaintenance', {})
    if provenance.get('upstreamCommit') != COMMIT:
        raise ValueError('Unexpected MCP upstream commit')
    expected = {key: toolchain[key] for key in ('nodeVersion', 'npmVersion')}
    if provenance.get('toolchain') != expected:
        raise ValueError('MCP was built with a different Node/npm toolchain')
    if provenance.get('dependencyLockSHA256') != hashlib.sha256(lock_bytes).hexdigest():
        raise ValueError('MCP dependency lock digest mismatch')
    if manifest.get('bin') != {'iphone-mcp': 'dist/cli.js'}:
        raise ValueError('Unexpected MCP executable')
    return provenance


def verify(package, toolchain, overlay=None):
    package = Path(package)
    expected = Path(str(package) + '.sha256').read_text().strip()
    if hashlib.sha256(package.read_bytes()).hexdigest() != expected:
        raise ValueError('MCP package checksum mismatch')
    with tarfile.open(package, 'r:gz') as archive:
        inventory = members(archive)
        manifest = json.loads(read_file(archive, inventory, 'package.json'))
        lock = read_file(archive, inventory, 'package-lock.json')
        provenance = check_manifest(manifest, lock, toolchain)
        if 'package/npm-shrinkwrap.json' in inventory and read_file(archive, inventory, 'npm-shrinkwrap.json') != lock:
            raise ValueError('Ambiguous legacy dependency lock')
        if overlay is not None and provenance.get('overlaySHA256') != hashlib.sha256(Path(overlay).read_bytes()).hexdigest():
            raise ValueError('MCP overlay digest mismatch')
        for name in ('LICENSE', 'dist/cli.js', 'dist/index.js', 'dist/idb/idb-client.js',
                     'dist/idb/simulator-env.js', 'dist/idb/type-text.py'):
            read_file(archive, inventory, name)
    return manifest


def extract(package, destination):
    """Write only regular files into a newly created, private directory."""
    destination = Path(destination)
    if destination.exists():
        raise ValueError('MCP extraction destination already exists')
    destination.mkdir(mode=0o700)
    with tarfile.open(package, 'r:gz') as archive:
        inventory = members(archive)
        for name, member in inventory.items():
            relative = PurePosixPath(name).relative_to('package')
            path = destination.joinpath(*relative.parts)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open('xb') as output:
                    output.write(archive.extractfile(member).read())
                path.chmod(0o755 if member.mode & 0o111 else 0o644)
