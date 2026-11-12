#!/usr/bin/env python3
"""Install the pinned Node/npm and maintained MCP as one verified transaction.

Only official, checksum-pinned archives are accepted. The existing runtime stays
usable until the replacement (including its native MCP module) passes validation.
macOS directory exchange keeps the stable prefix present throughout activation.
"""
import argparse
import base64
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import uuid


def load_manifest(path):
    data = json.loads(Path(path).read_text())
    if data.get('schemaVersion') != 1:
        raise ValueError('Unsupported Node toolchain manifest')
    for key in ['nodeVersion', 'npmVersion']:
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', data.get(key, '')):
            raise ValueError('Invalid toolchain version: ' + key)
    for arch in ['darwin-arm64', 'darwin-x64']:
        item = data['nodeArchives'][arch]
        expected = 'https://nodejs.org/dist/v{0}/node-v{0}-{1}.tar.gz'.format(data['nodeVersion'], arch)
        if item['url'] != expected or not re.fullmatch(r'[a-f0-9]{64}', item['sha256']):
            raise ValueError('Invalid official Node archive pin: ' + arch)
    npm = data['npmArchive']
    if npm['url'] != 'https://registry.npmjs.org/npm/-/npm-{}.tgz'.format(data['npmVersion']):
        raise ValueError('Invalid official npm archive URL')
    if len(base64.b64decode(npm['sha512'], validate=True)) != 64:
        raise ValueError('Invalid npm integrity pin')
    return data


def archive_digest(path, algorithm):
    digest = hashlib.new(algorithm)
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.digest()


def fetch_archive(spec, directory, algorithm):
    expected = bytes.fromhex(spec['sha256']) if algorithm == 'sha256' else base64.b64decode(spec['sha512'])
    destination = directory / Path(urllib.parse.urlsplit(spec['url']).path).name
    if destination.is_symlink():
        raise ValueError('Download cache entry must not be a symlink')
    if destination.is_file() and archive_digest(destination, algorithm) == expected:
        return destination
    descriptor, name = tempfile.mkstemp(prefix='.download-', dir=directory)
    partial = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as target, urllib.request.urlopen(spec['url'], timeout=60) as source:
            if source.geturl() != spec['url']:
                raise ValueError('Unexpected archive redirect')
            total = 0
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > 256 * 1024 * 1024:
                    raise ValueError('Archive exceeds download limit')
                target.write(chunk)
        if archive_digest(partial, algorithm) != expected:
            raise ValueError('Official archive checksum mismatch')
        os.replace(partial, destination)
    finally:
        partial.unlink(missing_ok=True)
    return destination


def extract_archive(archive_path, destination, top_directory):
    """Extract one expected top-level directory without traversing archive links."""
    destination.mkdir(parents=True, exist_ok=True)
    seen = set()
    with tarfile.open(archive_path, 'r:gz') as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != top_directory:
                raise ValueError('Unsafe archive member path')
            relative = Path(*path.parts[1:])
            if relative == Path('.'):
                if not member.isdir():
                    raise ValueError('Invalid archive root')
                continue
            if str(relative) in seen:
                raise ValueError('Duplicate archive member')
            seen.add(str(relative))
            target = destination / relative
            current = destination
            for part in relative.parts[:-1]:
                current = current / part
                if current.is_symlink():
                    raise ValueError('Archive path traverses a symlink')
                current.mkdir(exist_ok=True)
            if member.isdir():
                if target.is_symlink():
                    raise ValueError('Archive directory is a symlink')
                target.mkdir(exist_ok=True)
            elif member.isfile():
                if target.exists() or target.is_symlink():
                    raise ValueError('Archive file would overwrite existing path')
                source = archive.extractfile(member)
                with source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            elif member.issym():
                if PurePosixPath(member.linkname).is_absolute():
                    raise ValueError('Absolute archive symlink')
                resolved = (target.parent / member.linkname).resolve()
                if os.path.commonpath([str(destination.resolve()), str(resolved)]) != str(destination.resolve()):
                    raise ValueError('Archive symlink escapes destination')
                target.symlink_to(member.linkname)
            else:
                raise ValueError('Unsupported archive member type')


def runtime_environment(prefix):
    environment = {key: os.environ[key] for key in ['HOME', 'TMPDIR', 'npm_config_cache'] if key in os.environ}
    environment['PATH'] = str(prefix / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
    environment['npm_config_update_notifier'] = 'false'
    environment['PYTHONDONTWRITEBYTECODE'] = '1'
    return environment


def verify_versions(prefix, manifest):
    environment = runtime_environment(prefix)
    for executable, expected in [('node', 'v' + manifest['nodeVersion']), ('npm', manifest['npmVersion'])]:
        actual = subprocess.check_output([str(prefix / 'bin' / executable), '--version'],
                                         env=environment, text=True, timeout=30).strip()
        if actual != expected:
            raise ValueError('Staged {} version mismatch'.format(executable))


def exchange_directories(first, second):
    if platform.system() != 'Darwin':
        raise ValueError('Atomic runtime replacement requires macOS')
    libc = ctypes.CDLL(None, use_errno=True)
    exchange = libc.renamex_np
    exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    exchange.restype = ctypes.c_int
    if exchange(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def activate(staged, prefix):
    if prefix.is_symlink() or (prefix.exists() and not prefix.is_dir()):
        raise ValueError('Runtime prefix must be a real directory')
    if not prefix.exists():
        os.rename(staged, prefix)
        return None
    backup = prefix.with_name(prefix.name + '.backup.' + uuid.uuid4().hex)
    # Give the fully verified staged tree its eventual backup path first. After
    # exchange, that path contains the complete old runtime, even after a crash.
    os.rename(staged, backup)
    try:
        exchange_directories(backup, prefix)
    except BaseException:
        os.rename(backup, staged)
        raise
    return backup


def install(prefix, manifest_path, mcp_package, mcp_installer, download_cache=None):
    manifest = load_manifest(manifest_path)
    prefix = Path(prefix).absolute()
    if prefix.name in ['', '.', '..'] or prefix.parent == prefix:
        raise ValueError('Unsafe runtime prefix')
    if prefix.is_symlink() or (prefix.exists() and not prefix.is_dir()):
        raise ValueError('Runtime prefix must be a real directory')
    prefix.parent.mkdir(parents=True, exist_ok=True)
    architecture = {'arm64': 'darwin-arm64', 'x86_64': 'darwin-x64'}.get(platform.machine())
    if platform.system() != 'Darwin' or architecture is None:
        raise ValueError('Unsupported runtime platform')
    lock_path = prefix.with_name('.' + prefix.name + '.install.lock')
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another Node runtime installation is running')
        receipt = {'schemaVersion': 1, 'manifestSHA256': hashlib.sha256(Path(manifest_path).read_bytes()).hexdigest(),
                   'mcpPackageSHA256': archive_digest(mcp_package, 'sha256').hex(), 'architecture': architecture}
        receipt_path = prefix / '.blitz-toolchain.json'
        if receipt_path.is_file() and not receipt_path.is_symlink():
            try:
                previous_receipt = json.loads(receipt_path.read_text())
            except (ValueError, OSError):
                previous_receipt = None
            if previous_receipt == receipt:
                verifier = Path(mcp_installer).absolute().with_name('iphone_mcp_install.py')
                try:
                    verify_versions(prefix, manifest)
                    subprocess.run([sys.executable, '-B', str(verifier), '--verify-installed', str(prefix),
                                    str(Path(mcp_package).absolute()), str(Path(manifest_path).absolute())],
                                   env=runtime_environment(prefix), check=True, timeout=90)
                except (ValueError, OSError, subprocess.SubprocessError):
                    print('Existing runtime validation failed; preparing a complete verified replacement.', file=sys.stderr)
                else:
                    print('Pinned Node/npm and maintained iPhone MCP already installed and verified at ' + str(prefix))
                    return None
        with tempfile.TemporaryDirectory(prefix='.' + prefix.name + '.staging.', dir=prefix.parent) as temporary:
            work = Path(temporary)
            downloads = Path(download_cache).absolute() if download_cache else work / 'downloads'
            if downloads.is_symlink():
                raise ValueError('Download cache directory must not be a symlink')
            downloads.mkdir(parents=True, exist_ok=True)
            node_archive = fetch_archive(manifest['nodeArchives'][architecture], downloads, 'sha256')
            npm_archive = fetch_archive(manifest['npmArchive'], downloads, 'sha512')
            staged = work / 'runtime'
            extract_archive(node_archive, staged, 'node-v{}-{}'.format(manifest['nodeVersion'], architecture))
            npm_directory = staged / 'lib/node_modules/npm'
            if npm_directory.is_symlink():
                raise ValueError('Bundled npm must not be a symlink')
            if npm_directory.exists():
                shutil.rmtree(npm_directory)
            extract_archive(npm_archive, npm_directory, 'package')
            for command, script in [('npm', 'npm-cli.js'), ('npx', 'npx-cli.js')]:
                link = staged / 'bin' / command
                if link.is_dir() and not link.is_symlink():
                    raise ValueError('Unexpected npm launcher directory')
                link.unlink(missing_ok=True)
                link.symlink_to('../lib/node_modules/npm/bin/' + script)
            verify_versions(staged, manifest)
            subprocess.run(['/bin/bash', str(Path(mcp_installer).absolute()), str(staged),
                            str(Path(mcp_package).absolute()), str(Path(manifest_path).absolute())],
                           env=runtime_environment(staged), check=True, timeout=900)
            verify_versions(staged, manifest)
            if not (staged / 'bin/iphone-mcp').is_file():
                raise ValueError('Verified MCP launcher missing')
            (staged / '.blitz-toolchain.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
            staged.chmod(0o755)
            backup = activate(staged, prefix)
            print('Installed Node {} / npm {} and verified iPhone MCP at {}'.format(
                manifest['nodeVersion'], manifest['npmVersion'], prefix))
            if backup:
                print('Previous complete runtime retained at ' + str(backup))
            return backup
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--mcp-package', required=True, type=Path)
    parser.add_argument('--mcp-installer', required=True, type=Path)
    parser.add_argument('--download-cache', type=Path)
    arguments = parser.parse_args()
    try:
        install(arguments.prefix, arguments.manifest, arguments.mcp_package,
                arguments.mcp_installer, arguments.download_cache)
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        print('Node runtime installation failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
