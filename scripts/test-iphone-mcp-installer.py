#!/usr/bin/env python3
"""Offline installation transactions, exact runtime and safe package checks."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS / 'pkg-scripts'))
import iphone_mcp_install as installer
from iphone_mcp_archive import COMMIT, VERSION
SCRIPT = SCRIPTS / 'pkg-scripts/install-iphone-mcp.sh'
CLI = '''#!/usr/bin/env node
process.stdin.on('data', data => {
 const request=JSON.parse(data.toString().trim());
 process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result:{serverInfo:{version:'0.1.18-blitz.1'}}})+'\\n');
});
process.stdin.on('end',()=>process.exit(0));
'''


class MCPInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='blitz-mcp-install-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'node runtime'
        (self.prefix / 'bin').mkdir(parents=True)
        (self.prefix / 'bin/node').symlink_to(shutil.which('node'))
        self.toolchain = {'nodeVersion': subprocess.check_output(['node', '--version'], text=True).strip()[1:], 'npmVersion': '12.2.2'}
        self.manifest = self.root / 'toolchain.json'
        self.manifest.write_text(json.dumps(self.toolchain))
        self.destination = self.prefix / 'lib/node_modules/@blitzdev/iphone-mcp'
        self.destination.mkdir(parents=True)
        (self.destination / 'old').write_text('preserve')
        self.link = self.prefix / 'bin/iphone-mcp'
        self.link.symlink_to('../lib/node_modules/@blitzdev/iphone-mcp/dist/cli.js')
        self.package = self.root / 'package.tgz'
        self.checksum = self.root / 'package.tgz.sha256'
        self.fake_package()
        self.stub('exit 24')

    def stub(self, body):
        npm = self.prefix / 'bin/npm'
        npm.write_text('#!/bin/bash\nset -eu\nif [ "$1" = --version ]; then echo 12.2.2; exit 0; fi\n' + body + '\n')
        npm.chmod(0o755)

    def fake_package(self, version=VERSION, lock=True, cli=CLI, extra=None, toolchain=None):
        lock_data = json.dumps({'name': '@blitzdev/iphone-mcp', 'version': version, 'lockfileVersion': 3,
                               'packages': {'': {'dependencies': {}}}}).encode()
        manifest = {'name': '@blitzdev/iphone-mcp', 'version': version, 'type': 'module', 'dependencies': {},
                    'bin': {'iphone-mcp': 'dist/cli.js'}, 'allowScripts': {'unix-dgram@2.0.7': True},
                    'blitzMaintenance': {'upstreamCommit': COMMIT, 'toolchain': toolchain or self.toolchain,
                                         'dependencyLockSHA256': hashlib.sha256(lock_data).hexdigest()}}
        files = {'package.json': json.dumps(manifest).encode(), 'dist/index.js': b'// fixture',
                 'dist/cli.js': cli.encode(), 'LICENSE': b'MIT', 'dist/idb/idb-client.js': b'// fixture',
                 'dist/idb/simulator-env.js': b'// fixture', 'dist/idb/type-text.py': b'# fixture'}
        if lock:
            files['package-lock.json'] = lock_data
        with tarfile.open(self.package, 'w:gz') as archive:
            for name, content in files.items():
                info = tarfile.TarInfo('package/' + name)
                info.size, info.mode = len(content), 0o755 if name.endswith('cli.js') else 0o644
                archive.addfile(info, io.BytesIO(content))
            if extra is not None:
                archive.addfile(extra)
        self.checksum.write_text(hashlib.sha256(self.package.read_bytes()).hexdigest())

    def run_install(self):
        return subprocess.run(['bash', str(SCRIPT), str(self.prefix), str(self.package), str(self.manifest)],
                              capture_output=True, text=True, env={'HOME': str(self.root), 'PATH': os.environ['PATH']})

    def assert_preserved(self):
        self.assertEqual((self.destination / 'old').read_text(), 'preserve')
        self.assertEqual(os.readlink(self.link), '../lib/node_modules/@blitzdev/iphone-mcp/dist/cli.js')
        self.assertEqual(list(self.prefix.glob('.iphone-mcp-install.*')), [])
        self.assertEqual(list(self.destination.parent.glob('iphone-mcp.backup.*')), [])

    def success_stub(self):
        self.stub('''[ -f package-lock.json ]
case "$1" in
 ci) [ "$2" = --omit=dev ] && [ "$3" = --ignore-scripts ]; touch .ci-ran ;;
 rebuild) [ "$2" = unix-dgram ] && [ "$3" = --strict-allow-scripts ] && [ -f .ci-ran ]; mkdir -p node_modules/unix-dgram; echo 'module.exports = {}' > node_modules/unix-dgram/index.js; touch .rebuild-ran ;;
 *) exit 20 ;;
esac''')

    def test_real_npm_loads_separate_empty_configuration(self):
        home = self.root / 'config-home'
        home.mkdir()
        env = installer.environment(Path(shutil.which('node')).parent.parent, home)
        self.assertNotEqual(env['npm_config_userconfig'], env['npm_config_globalconfig'])
        for key in ('npm_config_userconfig', 'npm_config_globalconfig'):
            self.assertEqual(Path(env[key]).read_text(), '')
        result = subprocess.run([shutil.which('npm'), '--version'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checksum_failure_keeps_existing_package(self):
        self.checksum.write_text('invalid')
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_failed_dependency_install_keeps_existing_package(self):
        self.assertEqual(self.run_install().returncode, 24)
        self.assert_preserved()

    def test_wrong_staged_version_keeps_existing_package(self):
        self.fake_package(version='0.1.18')
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_missing_dependency_lock_is_rejected(self):
        self.fake_package(lock=False)
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_successful_rebuild_without_native_module_keeps_existing_package(self):
        self.stub('exit 0')
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_wrong_toolchain_is_rejected_before_npm_install(self):
        self.fake_package(toolchain={'nodeVersion': '22.16.0', 'npmVersion': '10.9.2'})
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_wrong_runtime_is_rejected_before_install(self):
        self.manifest.write_text(json.dumps({**self.toolchain, 'nodeVersion': '0.0.0'}))
        self.fake_package(toolchain={**self.toolchain, 'nodeVersion': '0.0.0'})
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_wrong_initialize_response_keeps_existing_package(self):
        self.fake_package(cli=CLI.replace(VERSION, 'unexpected'))
        self.success_stub()
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_archive_symlink_is_rejected_without_extracting(self):
        info = tarfile.TarInfo('package/escape')
        info.type, info.linkname = tarfile.SYMTYPE, '/tmp'
        self.fake_package(extra=info)
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_archive_traversal_is_rejected(self):
        self.fake_package(extra=tarfile.TarInfo('package/../../escape'))
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_preserved()

    def test_package_symlink_is_not_followed(self):
        self.destination.rename(self.root / 'foreign')
        self.destination.symlink_to(self.root / 'foreign')
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual((self.root / 'foreign/old').read_text(), 'preserve')

    def test_foreign_launcher_is_not_replaced(self):
        self.link.unlink()
        self.link.write_text('unrelated')
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertEqual(self.link.read_text(), 'unrelated')
        self.assertEqual((self.destination / 'old').read_text(), 'preserve')

    def test_failed_exchange_rolls_back_package(self):
        staging = self.prefix / '.fixture'
        staging.mkdir()
        package = staging / 'package'
        package.mkdir()
        (package / 'new').write_text('new')
        with patch.object(installer, 'exchange_directories', side_effect=OSError('fixture: exchange failed')):
            with self.assertRaises(OSError):
                installer.activate(package, self.destination, self.link, os.readlink(self.link))
        self.assert_preserved()
        self.assertEqual((package / 'new').read_text(), 'new')

    def test_new_launcher_failure_rolls_back_new_install(self):
        shutil.rmtree(self.destination)
        self.link.unlink()
        staging = self.prefix / '.fixture'
        staging.mkdir()
        package = staging / 'package'
        package.mkdir()
        original_replace = os.replace
        def replace(source, target):
            if Path(target) == self.link:
                raise OSError('fixture: launcher rename failed')
            return original_replace(source, target)
        with patch.object(installer.os, 'replace', side_effect=replace):
            with self.assertRaises(OSError):
                installer.activate(package, self.destination, self.link, '../lib/node_modules/@blitzdev/iphone-mcp/dist/cli.js')
        self.assertFalse(self.destination.exists())
        self.assertFalse(os.path.lexists(self.link))
        self.assertTrue(package.exists())

    def test_runtime_lock_blocks_parallel_package_install(self):
        import fcntl
        lock = self.prefix.with_name('.' + self.prefix.name + '.install.lock')
        with lock.open('w') as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Another runtime', result.stderr)
        self.assert_preserved()

    def test_success_uses_ci_updates_link_and_retains_backup(self):
        self.success_stub()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / '.rebuild-ran').exists())
        backups = list(self.destination.parent.glob('iphone-mcp.backup.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'old').read_text(), 'preserve')
        self.assertEqual(self.link.resolve(), (self.destination / 'dist/cli.js').resolve())
        self.assertEqual(list(self.prefix.glob('.iphone-mcp-install.*')), [])
        installer.verify_installed(self.prefix, self.package, self.manifest)
        (self.destination / 'dist').rename(self.root / 'external-dist')
        (self.destination / 'dist').symlink_to(self.root / 'external-dist')
        with self.assertRaisesRegex(ValueError, 'indirect'):
            installer.verify_installed(self.prefix, self.package, self.manifest)
        (self.destination / 'dist').unlink()
        (self.root / 'external-dist').rename(self.destination / 'dist')
        (self.destination / 'dist/index.js').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'differs'):
            installer.verify_installed(self.prefix, self.package, self.manifest)


if __name__ == '__main__':
    unittest.main()
