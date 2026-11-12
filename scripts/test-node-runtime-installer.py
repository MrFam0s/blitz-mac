#!/usr/bin/env python3
"""Offline regressions for the toolchain's archive and activation boundaries."""
import copy
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('node_installer', ROOT / 'scripts/pkg-scripts/install-node-runtime.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def archive(path, top, files):
    with tarfile.open(path, 'w:gz') as output:
        for name, content in files:
            entry = tarfile.TarInfo(top + '/' + name)
            if isinstance(content, tuple):
                entry.type = tarfile.SYMTYPE
                entry.linkname = content[0]
                output.addfile(entry)
            else:
                payload = content.encode()
                entry.size = len(payload)
                entry.mode = 0o755
                output.addfile(entry, io.BytesIO(payload))


class RuntimeInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='blitz-node-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / 'node runtime'
        self.prefix.mkdir()
        (self.prefix / 'old').write_text('preserve old runtime and native module')
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_bytes((ROOT / 'config/node-toolchain.json').read_bytes())
        self.node_archive = self.root / 'node.tgz'
        self.npm_archive = self.root / 'npm.tgz'
        self.mcp_package = self.root / 'mcp.tgz'
        self.mcp_package.write_bytes(b'test package')
        archive(self.node_archive, 'node-v26.13.1-darwin-arm64', [
            ('bin/node', '#!/bin/sh\necho v26.13.1\n'),
            ('lib/node_modules/npm/bin/npm-cli.js', '#!/bin/sh\necho old-npm\n'),
            ('bin/npm', ('../lib/node_modules/npm/bin/npm-cli.js',))])
        archive(self.npm_archive, 'package', [('bin/npm-cli.js', '#!/bin/sh\necho 12.2.2\n'),
                                             ('bin/npx-cli.js', '#!/bin/sh\nexit 0\n')])
        self.mcp_installer = self.root / 'install-mcp.sh'
        self.mcp_installer.write_text('''#!/bin/sh
set -eu
[ -f "$3" ]
mkdir -p "$1/lib/mcp"
printf '#!/bin/sh\\nexit 0\\n' > "$1/lib/mcp/cli"
chmod 755 "$1/lib/mcp/cli"
ln -s ../lib/mcp/cli "$1/bin/iphone-mcp"
''')

    def install(self):
        with patch.object(MODULE.platform, 'machine', return_value='arm64'), \
             patch.object(MODULE, 'fetch_archive', side_effect=[self.node_archive, self.npm_archive]):
            return MODULE.install(self.prefix, self.manifest, self.mcp_package, self.mcp_installer)

    def assert_preserved(self):
        self.assertEqual((self.prefix / 'old').read_text(), 'preserve old runtime and native module')
        self.assertEqual(list(self.root.glob('.node runtime.staging.*')), [])
        self.assertEqual(list(self.root.glob('node runtime.backup.*')), [])

    def test_success_activates_complete_runtime_and_retains_old(self):
        backup = self.install()
        self.assertTrue((backup / 'old').is_file())
        self.assertFalse((self.prefix / 'old').exists())
        self.assertTrue((self.prefix / 'bin/iphone-mcp').is_file())
        MODULE.verify_versions(self.prefix, MODULE.load_manifest(self.manifest))
        self.assertTrue((self.prefix / '.blitz-toolchain.json').is_file())
        self.assertEqual(list(self.root.glob('.node runtime.staging.*')), [])

    def test_first_install_has_no_old_backup(self):
        (self.prefix / 'old').unlink()
        self.prefix.rmdir()
        self.assertIsNone(self.install())
        self.assertTrue((self.prefix / 'bin/iphone-mcp').is_file())

    def test_verified_identical_install_does_not_download_or_replace(self):
        backup = self.install()
        inode = self.prefix.stat().st_ino
        (self.root / 'iphone_mcp_install.py').write_text('import sys; assert sys.argv[1]=="--verify-installed"\n')
        with patch.object(MODULE.platform, 'machine', return_value='arm64'), \
             patch.object(MODULE, 'fetch_archive', side_effect=AssertionError('Unexpected download')):
            self.assertIsNone(MODULE.install(self.prefix, self.manifest, self.mcp_package, self.mcp_installer))
        self.assertEqual(self.prefix.stat().st_ino, inode)
        self.assertTrue((backup / 'old').is_file())

    def test_matching_receipt_with_failed_mcp_check_can_be_repaired(self):
        self.install()
        inode = self.prefix.stat().st_ino
        (self.root / 'iphone_mcp_install.py').write_text('raise SystemExit(23)\n')
        (self.prefix / 'damaged-native-marker').write_text('old damaged installation')
        backup = self.install()
        self.assertNotEqual(self.prefix.stat().st_ino, inode)
        self.assertTrue((backup / 'damaged-native-marker').is_file())
        self.assertFalse((self.prefix / 'damaged-native-marker').exists())

    def test_mcp_failure_preserves_old_native_runtime(self):
        self.mcp_installer.write_text('#!/bin/sh\nexit 19\n')
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assert_preserved()

    def test_wrong_staged_version_cannot_activate(self):
        archive(self.npm_archive, 'package', [('bin/npm-cli.js', '#!/bin/sh\necho 11.0.0\n'),
                                             ('bin/npx-cli.js', '#!/bin/sh\nexit 0\n')])
        with self.assertRaisesRegex(ValueError, 'version mismatch'):
            self.install()
        self.assert_preserved()

    def test_exchange_failure_preserves_old_and_cleans_stage(self):
        with patch.object(MODULE, 'exchange_directories', side_effect=OSError('injected exchange failure')):
            with self.assertRaises(OSError):
                self.install()
        self.assert_preserved()

    def test_symlink_prefix_is_rejected_without_touching_target(self):
        link = self.root / 'alias'
        link.symlink_to(self.prefix, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'real directory'):
            MODULE.install(link, self.manifest, self.mcp_package, self.mcp_installer)
        self.assert_preserved()

    def test_concurrent_install_is_rejected(self):
        with (self.root / '.node runtime.install.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, 'Another Node'):
                self.install()
        self.assert_preserved()

    def test_manifest_rejects_unpinned_or_nonofficial_sources(self):
        original = json.loads(self.manifest.read_text())
        for mutate in [lambda d: d.update(nodeVersion='latest'),
                       lambda d: d['npmArchive'].update(url='https://example.org/npm.tgz'),
                       lambda d: d['nodeArchives']['darwin-arm64'].update(sha256='invalid')]:
            data = copy.deepcopy(original)
            mutate(data)
            self.manifest.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                MODULE.load_manifest(self.manifest)
        self.assert_preserved()

    def test_download_checksum_mismatch_cannot_replace_cached_archive(self):
        manifest = MODULE.load_manifest(self.manifest)
        spec = manifest['nodeArchives']['darwin-arm64']
        response = io.BytesIO(b'invalid download')
        response.geturl = lambda: spec['url']
        with patch.object(MODULE.urllib.request, 'urlopen', return_value=response):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                MODULE.fetch_archive(spec, self.root, 'sha256')
        self.assertEqual(list(self.root.glob('.download-*')), [])
        self.assertFalse((self.root / Path(spec['url']).name).exists())
        self.assert_preserved()

    def test_archives_reject_escape_and_duplicate_paths(self):
        cases = [ [('file', 'first'), ('file', 'second')],
                  [('../outside', 'escape')],
                  [('link', ('../../outside',))],
                  [('link', ('inside',)), ('link/file', 'traverse link')],
                  [('link', ('/tmp/outside',))] ]
        for index, files in enumerate(cases):
            with self.subTest(index=index):
                path = self.root / ('archive-' + str(index) + '.tgz')
                archive(path, 'package', files)
                with self.assertRaises(ValueError):
                    MODULE.extract_archive(path, self.root / ('out-' + str(index)), 'package')


class ToolchainResolverTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='blitz-node-resolve-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def runtime(self, name, node, npm):
        directory = self.root / name
        directory.mkdir(parents=True)
        for command, value in [('node', node), ('npm', npm)]:
            executable = directory / command
            executable.write_text('#!/bin/sh\necho ' + value + '\n')
            executable.chmod(0o755)
        return directory

    def resolve(self, path, explicit=None):
        environment = {'HOME': str(self.root), 'PATH': str(path) + ':' + os.environ['PATH']}
        if explicit:
            environment['BLITZ_NODE_BIN'] = str(explicit)
        script = 'source "$1"; blitz_resolve_node_toolchain "$2" || exit $?; printf "%s\\n" "$BLITZ_NODE_BIN"'
        return subprocess.run(['/bin/bash', '-c', script, 'resolver',
                               str(ROOT / 'scripts/node-toolchain.sh'), str(ROOT / 'config/node-toolchain.json')],
                              env=environment, capture_output=True, text=True)

    def test_current_exact_toolchain_is_selected(self):
        current = self.runtime('current', 'v26.13.1', '12.2.2')
        self.runtime('.blitz/node-runtime/bin', 'v22.16.0', '10.9.2')
        result = self.resolve(current)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(current))

    def test_mismatched_path_uses_matching_private_runtime(self):
        current = self.runtime('current', 'v27.0.0', '12.2.2')
        private = self.runtime('.blitz/node-runtime/bin', 'v26.13.1', '12.2.2')
        result = self.resolve(current)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(private))

    def test_explicit_mismatch_does_not_silently_fall_back(self):
        current = self.runtime('current', 'v26.13.1', '12.2.2')
        invalid = self.runtime('invalid', 'v26.13.1', '11.0.0')
        result = self.resolve(current, explicit=invalid)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('BLITZ_NODE_BIN must provide', result.stderr)


if __name__ == '__main__':
    unittest.main()
