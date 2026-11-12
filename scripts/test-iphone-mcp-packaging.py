#!/usr/bin/env python3
"""Offline regression coverage for npm 12's omitted lock and deterministic output."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts/pkg-scripts'))
from iphone_mcp_archive import COMMIT, VERSION, extract, verify
from iphone_mcp_install import environment
spec = importlib.util.spec_from_file_location('mcp_pack', ROOT / 'scripts/pack-iphone-mcp.py')
pack_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack_module)


class MCPPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='blitz-mcp-pack-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.toolchain = json.loads((ROOT / 'config/node-toolchain.json').read_text())
        self.lock = json.dumps({'name': '@blitzdev/iphone-mcp', 'version': VERSION, 'lockfileVersion': 3,
                                'packages': {'': {'dependencies': {}}}}).encode()
        self.manifest = json.dumps({'name': '@blitzdev/iphone-mcp', 'version': VERSION, 'dependencies': {},
            'allowScripts': {'unix-dgram@2.0.7': True}, 'bin': {'iphone-mcp': 'dist/cli.js'},
            'blitzMaintenance': {'upstreamCommit': COMMIT,
              'toolchain': {key: self.toolchain[key] for key in ('nodeVersion', 'npmVersion')},
              'dependencyLockSHA256': hashlib.sha256(self.lock).hexdigest()}}).encode()
        (self.source / 'package.json').write_bytes(self.manifest)
        (self.source / 'package-lock.json').write_bytes(self.lock)
        self.package = self.root / 'package.tgz'

    def npm_archive(self, lock=None, extra=None, manifest=None, mtime=123, legacy=None):
        files = {'package.json': manifest or self.manifest, 'dist/cli.js': b'#!/usr/bin/env node\n',
                 'dist/index.js': b'// fixture', 'LICENSE': b'MIT', 'dist/idb/idb-client.js': b'// fixture',
                 'dist/idb/simulator-env.js': b'// fixture', 'dist/idb/type-text.py': b'# fixture'}
        if lock is not None:
            files['package-lock.json'] = lock
        if legacy is not None:
            files['npm-shrinkwrap.json'] = legacy
        with tarfile.open(self.package, 'w:gz') as archive:
            for name, data in files.items():
                info = tarfile.TarInfo('package/' + name)
                info.size, info.mode, info.mtime = len(data), 0o755 if name.endswith('cli.js') else 0o644, mtime
                archive.addfile(info, io.BytesIO(data))
            if extra is not None:
                archive.addfile(extra)

    def pack(self):
        pack_module.pack(self.source, self.package, self.toolchain)

    def test_missing_npm12_lock_is_restored_and_verified(self):
        self.npm_archive()
        self.pack()
        verify(self.package, self.toolchain)
        with tarfile.open(self.package) as archive:
            self.assertEqual(archive.extractfile('package/package-lock.json').read(), self.lock)
            self.assertTrue(archive.getmember('package/dist/cli.js').mode & 0o111)

    def test_same_source_has_deterministic_bytes_despite_npm_timestamps(self):
        self.npm_archive(mtime=10)
        self.pack()
        first = self.package.read_bytes()
        self.npm_archive(lock=self.lock, mtime=2000)
        self.pack()
        self.assertEqual(self.package.read_bytes(), first)

    def test_postpacked_lock_is_consumed_by_real_npm_ci_offline(self):
        self.npm_archive()
        self.pack()
        destination, home = self.root / 'real-ci', self.root / 'isolated-home'
        home.mkdir()
        extract(self.package, destination)
        node = Path(shutil.which('node')).absolute()
        env = environment(node.parent.parent, home)
        npm = shutil.which('npm')
        version = subprocess.check_output([npm, '--version'], env=env, text=True).strip()
        self.assertEqual(version, self.toolchain['npmVersion'])
        result = subprocess.run([npm, 'ci', '--offline', '--ignore-scripts', '--no-audit', '--no-fund'],
                                cwd=destination, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / 'package-lock.json').read_bytes(), self.lock)

    def test_identical_legacy_lock_is_removed_from_canonical_archive(self):
        self.npm_archive(legacy=self.lock)
        self.pack()
        with tarfile.open(self.package) as archive:
            self.assertNotIn('package/npm-shrinkwrap.json', archive.getnames())
            self.assertEqual(archive.extractfile('package/package-lock.json').read(), self.lock)

    def test_conflicting_legacy_lock_is_rejected(self):
        self.npm_archive(legacy=b'{}')
        with self.assertRaisesRegex(ValueError, 'Ambiguous legacy'):
            self.pack()

    def test_different_packed_lock_is_rejected(self):
        self.npm_archive(lock=b'{}')
        with self.assertRaisesRegex(ValueError, 'Packed lock differs'):
            self.pack()

    def test_changed_source_lock_is_rejected(self):
        self.npm_archive()
        (self.source / 'package-lock.json').write_bytes(self.lock + b' ')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            self.pack()

    def test_npm_changed_manifest_is_rejected(self):
        self.npm_archive(manifest=self.manifest + b' ')
        with self.assertRaisesRegex(ValueError, 'changed the source'):
            self.pack()

    def test_symlink_from_npm_pack_is_rejected(self):
        info = tarfile.TarInfo('package/link')
        info.type, info.linkname = tarfile.SYMTYPE, '../../outside'
        self.npm_archive(extra=info)
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            self.pack()

    def test_duplicate_archive_path_is_rejected(self):
        self.npm_archive(extra=tarfile.TarInfo('package/package.json'))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.pack()

    def test_bundled_node_modules_are_rejected(self):
        self.npm_archive(extra=tarfile.TarInfo('package/node_modules/foreign.js'))
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            self.pack()

    def test_checksum_tampering_is_rejected(self):
        self.npm_archive()
        self.pack()
        self.package.write_bytes(self.package.read_bytes() + b'bad')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            verify(self.package, self.toolchain)

    def test_wrong_build_toolchain_is_rejected(self):
        self.npm_archive()
        with self.assertRaisesRegex(ValueError, 'different Node/npm'):
            pack_module.pack(self.source, self.package, {**self.toolchain, 'nodeVersion': '22.16.0'})


if __name__ == '__main__':
    unittest.main()
