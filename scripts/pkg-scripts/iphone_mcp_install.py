#!/usr/bin/env python3
"""Stage and validate the MCP before replacing its package and relative launcher."""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import selectors
import platform
import subprocess
import sys
sys.dont_write_bytecode = True
import tarfile
import tempfile
import time
import uuid

from iphone_mcp_archive import VERSION, extract, members, verify


def environment(prefix, home):
    # No user npm config, Node injections or stored credentials are needed here.
    # npm 12 rejects loading one file as both user and global configuration.
    user_config, global_config = home / 'user.npmrc', home / 'global.npmrc'
    user_config.write_text('')
    global_config.write_text('')
    return {'PATH': str(prefix / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': str(home), 'TMPDIR': str(home), 'npm_config_userconfig': str(user_config),
            'npm_config_globalconfig': str(global_config), 'npm_config_audit': 'false',
            'npm_config_fund': 'false'}


def check_runtime(prefix, toolchain, env):
    for binary, expected in [('node', 'v' + toolchain['nodeVersion']), ('npm', toolchain['npmVersion'])]:
        result = subprocess.check_output([str(prefix / 'bin' / binary), '--version'], env=env,
                                         text=True, timeout=30).strip()
        if result != expected:
            raise ValueError('Incorrect ' + binary + ' version for the pinned MCP')


def smoke(prefix, package, env):
    node = str(prefix / 'bin/node')
    subprocess.run([node, '-e', "require('unix-dgram')"], cwd=package, env=env, check=True, timeout=30)
    request = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
        'protocolVersion': '2024-11-05', 'capabilities': {},
        'clientInfo': {'name': 'blitz-install-check', 'version': '1'}}}
    child = subprocess.Popen([node, str(package / 'dist/cli.js')], cwd=package, env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        child.stdin.write((json.dumps(request) + '\n').encode())
        child.stdin.flush()
        output, diagnostics = b'', b''
        deadline = time.monotonic() + 15
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ, 'stdout')
            selector.register(child.stderr, selectors.EVENT_READ, 'stderr')
            while b'\n' not in output:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError('MCP initialize timed out')
                for key, _ in selector.select(min(remaining, 1)):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif key.data == 'stdout':
                        output += chunk
                    else:
                        diagnostics = (diagnostics + chunk)[-8192:]
                if len(output) > 65536:
                    raise ValueError('MCP initialize response is too large')
                if child.poll() is not None and b'\n' not in output:
                    raise ValueError('MCP exited before initialize: ' + str(child.returncode))
        response = json.loads(output.split(b'\n', 1)[0])
        if response.get('id') != 1 or response.get('result', {}).get('serverInfo', {}).get('version') != VERSION:
            raise ValueError('Unexpected MCP initialize response')
        child.stdin.close()
        if child.wait(timeout=5) != 0:
            raise ValueError('MCP failed to exit cleanly after EOF')
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream is not None:
                stream.close()


def validate_destination(prefix):
    # Refuse to modify an indirect/unrelated installation, including broken links.
    if prefix.is_symlink() or not prefix.is_dir():
        raise ValueError('MCP runtime prefix must be an existing real directory')
    destination = prefix / 'lib/node_modules/@blitzdev/iphone-mcp'
    for path in (prefix / 'bin', prefix / 'lib', prefix / 'lib/node_modules',
                 destination.parent, destination):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise ValueError('MCP destination contains an indirect or invalid directory')
    launcher = prefix / 'bin/iphone-mcp'
    relative = '../lib/node_modules/@blitzdev/iphone-mcp/dist/cli.js'
    if os.path.lexists(launcher) and (not launcher.is_symlink() or os.readlink(launcher) != relative):
        raise ValueError('Refusing to replace an unrelated MCP launcher')
    return destination, launcher, relative


def activate(staged, destination, launcher, relative):
    """Keep an existing installation present even if the process is interrupted."""
    backup = destination.with_name(destination.name + '.backup.' + uuid.uuid4().hex)
    staged_link = staged.parent / 'iphone-mcp'
    staged_link.symlink_to(relative)
    if destination.exists():
        # The old and new package use the identical relative launcher. An
        # existing launcher never needs replacement; a missing one is reversible.
        added_link = not os.path.lexists(launcher)
        if added_link:
            os.replace(staged_link, launcher)
        os.replace(staged, backup)
        try:
            exchange_directories(backup, destination)
        except BaseException:
            os.replace(backup, staged)
            if added_link:
                launcher.unlink()
            raise
        return backup
    changed_package = False
    try:
        os.replace(staged, destination)
        changed_package = True
        os.replace(staged_link, launcher)
    except BaseException:
        if changed_package:
            os.replace(destination, staged)
        raise
    return None


def exchange_directories(first, second):
    if platform.system() != 'Darwin':
        raise ValueError('Atomic MCP replacement requires macOS')
    libc = ctypes.CDLL(None, use_errno=True)
    exchange = libc.renamex_np
    exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    exchange.restype = ctypes.c_int
    if exchange(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def verify_installed(prefix, package, manifest):
    toolchain = json.loads(manifest.read_text())
    verify(package, toolchain)
    destination, launcher, relative = validate_destination(prefix)
    if not launcher.is_symlink() or not destination.is_dir():
        raise ValueError('MCP is not installed')
    with tarfile.open(package) as archive:
        for name, member in members(archive).items():
            if not member.isfile():
                continue
            path = destination.joinpath(*Path(name).parts[1:])
            ancestors = path.relative_to(destination).parts
            current = destination
            for part in ancestors:
                current = current / part
                if current.is_symlink():
                    raise ValueError('Installed MCP contains an indirect path')
            if not path.is_file() or path.read_bytes() != archive.extractfile(member).read():
                raise ValueError('Installed MCP differs from its verified package')
    with tempfile.TemporaryDirectory(prefix='.iphone-mcp-check.', dir=prefix) as temporary:
        env = environment(prefix, Path(temporary))
        check_runtime(prefix, toolchain, env)
        smoke(prefix, destination, env)


def install(prefix, package, manifest):
    toolchain = json.loads(manifest.read_text())
    verify(package, toolchain)
    destination, launcher, relative = validate_destination(prefix)
    # Shared with full runtime migration, outside the tree that gets exchanged.
    lock = prefix.with_name('.' + prefix.name + '.install.lock')
    descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another runtime or MCP installation is running')
        with tempfile.TemporaryDirectory(prefix='.iphone-mcp-install.', dir=prefix) as temporary:
            temporary = Path(temporary)
            env = environment(prefix, temporary)
            check_runtime(prefix, toolchain, env)
            staged = temporary / 'package'
            extract(package, staged)
            npm = str(prefix / 'bin/npm')
            subprocess.run([npm, 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'],
                           cwd=staged, env=env, check=True, timeout=600)
            subprocess.run([npm, 'rebuild', 'unix-dgram', '--strict-allow-scripts', '--no-audit', '--no-fund'],
                           cwd=staged, env=env, check=True, timeout=300)
            smoke(prefix, staged, env)
            destination.parent.mkdir(parents=True, exist_ok=True)
            backup = activate(staged, destination, launcher, relative)
            print('Installed iPhone MCP ' + VERSION + (('; backup: ' + str(backup)) if backup else ''))
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    args = sys.argv[1:]
    verify_only = args and args[0] == '--verify-installed'
    if verify_only:
        args.pop(0)
    try:
        prefix, package, manifest = (Path(value).absolute() for value in args)
        (verify_installed if verify_only else install)(prefix, package, manifest)
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        sys.exit('iPhone MCP installation failed: ' + str(error))
