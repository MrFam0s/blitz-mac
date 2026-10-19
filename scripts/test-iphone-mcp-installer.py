#!/usr/bin/env python3
"""Offline installation transaction checks; no user runtime or network access."""
import hashlib,io,json,os,shutil,subprocess,tarfile,tempfile,unittest
from pathlib import Path
SCRIPT=Path(__file__).parent/'pkg-scripts/install-iphone-mcp.sh'
class MCPInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='blitz-mcp-install-test-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.prefix=self.root/'node runtime';(self.prefix/'bin').mkdir(parents=True)
        (self.prefix/'bin/node').symlink_to(shutil.which('node'))
        self.destination=self.prefix/'lib/node_modules/@blitzdev/iphone-mcp';self.destination.mkdir(parents=True)
        (self.destination/'old').write_text('preserve')
        self.package=self.root/'package.tgz';self.checksum=self.root/'package.tgz.sha256'
        self.fake_package('0.1.18-blitz.1');self.stub('exit 24')
    def stub(self,body):
        npm=self.prefix/'bin/npm';npm.write_text('#!/bin/bash\nset -eu\n'+body+'\n');npm.chmod(0o755)
    def fake_package(self,version,lock=True):
        manifest={'name':'@blitzdev/iphone-mcp','version':version,'type':'module','blitzMaintenance':{'upstreamCommit':'3259f756279cd8cb6bc507b46369111fb5672fa2'}}
        files={'package.json':json.dumps(manifest),'dist/index.js':'// fixture','dist/cli.js':'#!/usr/bin/env node\n'}
        if lock:files['npm-shrinkwrap.json']='{}'
        with tarfile.open(self.package,'w:gz') as archive:
            for name,content in files.items():
                data=content.encode();info=tarfile.TarInfo('package/'+name);info.size=len(data);info.mode=0o755 if name.endswith('cli.js') else 0o644
                archive.addfile(info,io.BytesIO(data))
        self.checksum.write_text(hashlib.sha256(self.package.read_bytes()).hexdigest())
    def run_install(self):
        return subprocess.run(['bash',str(SCRIPT),str(self.prefix),str(self.package)],capture_output=True,text=True,env={'HOME':str(self.root),'PATH':os.environ['PATH']})
    def assert_preserved(self):
        self.assertEqual((self.destination/'old').read_text(),'preserve')
        self.assertEqual(list(self.prefix.glob('.iphone-mcp-install.*')),[])
        self.assertEqual(list(self.destination.parent.glob('iphone-mcp.backup.*')),[])
    def test_checksum_failure_keeps_existing_package(self):
        self.checksum.write_text('invalid');r=self.run_install();self.assertNotEqual(r.returncode,0);self.assert_preserved()
    def test_failed_dependency_install_keeps_existing_package(self):
        r=self.run_install();self.assertEqual(r.returncode,24);self.assert_preserved()
    def test_wrong_staged_version_keeps_existing_package(self):
        self.fake_package('0.1.18');self.stub('exit 0');r=self.run_install();self.assertNotEqual(r.returncode,0);self.assert_preserved()
    def test_missing_dependency_lock_is_rejected(self):
        self.fake_package('0.1.18-blitz.1',lock=False);self.stub('exit 0');r=self.run_install();self.assertNotEqual(r.returncode,0);self.assert_preserved()
    def test_success_uses_ci_updates_link_and_retains_backup(self):
        self.stub('''[ -f npm-shrinkwrap.json ]
case "$1" in
 ci) [ "$2" = --omit=dev ] && [ "$3" = --ignore-scripts ]; touch .ci-ran ;;
 rebuild) [ "$2" = unix-dgram ] && [ -f .ci-ran ]; touch .rebuild-ran ;;
 *) exit 20 ;;
esac''')
        r=self.run_install();self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((self.destination/'.rebuild-ran').exists())
        backups=list(self.destination.parent.glob('iphone-mcp.backup.*'));self.assertEqual(len(backups),1)
        self.assertEqual((backups[0]/'old').read_text(),'preserve')
        self.assertEqual((self.prefix/'bin/iphone-mcp').resolve(),(self.destination/'dist/cli.js').resolve())
        self.assertEqual(list(self.prefix.glob('.iphone-mcp-install.*')),[])
if __name__=='__main__':unittest.main()
