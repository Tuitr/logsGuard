"""Run only via integration.sh on its private, mounted loop filesystem."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMP = ['auth_service', 'data_process_service', 'system_event_handler_service']

@unittest.skipUnless(os.environ.get('LOGS_TEST_MOUNT'), 'use tests/integration.sh')
class Loop(unittest.TestCase):
    def setUp(self):
        self.mount = Path(os.environ['LOGS_TEST_MOUNT'])
        subprocess.run(['mountpoint','-q',str(self.mount)],check=True)
        for p in self.mount.iterdir():
            if p.is_dir(): shutil.rmtree(p)
            else: p.unlink()
        for c in COMP: (self.mount/c).mkdir()

    def write(self, path, mb, random=False):
        subprocess.run(['dd', 'if=/dev/urandom' if random else 'if=/dev/zero',
                        f'of={path}', 'bs=1M', f'count={mb}', 'status=none'],check=True)

    def snapshot(self):
        return {str(p.relative_to(self.mount)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.mount.rglob('*') if p.is_file()}

    def guard(self, threshold):
        return subprocess.run(['bash',str(ROOT/'logs_guard.sh')],
                              env=dict(os.environ,LOGS_DIR=str(self.mount),THRESHOLD=str(threshold)),
                              capture_output=True,text=True)

    def test_below(self):
        self.write(self.mount/COMP[0]/'z.log',1)
        before=self.snapshot(); result=self.guard(90)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(before,self.snapshot())

    def test_one_two_three(self):
        for count in (1,2,3):
            with self.subTest(count=count):
                for c in COMP:
                    for p in (self.mount/c).iterdir(): p.unlink()
                for c in COMP[:count]:
                    self.write(self.mount/c/'a.log',12//count)
                    self.write(self.mount/c/'z.log',12//count)
                before=self.snapshot(); result=self.guard(40)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                for c in COMP:
                    archives=list((self.mount/c).glob('*.tar.gz'))
                    self.assertEqual(len(archives),int(c in COMP[:count]))
                    if archives:
                        with tarfile.open(archives[0]) as tf:
                            self.assertEqual(tf.getnames(),['a.log'])
                            self.assertEqual(hashlib.sha256(tf.extractfile('a.log').read()).hexdigest(),before[c+'/a.log'])
                        self.assertEqual(hashlib.sha256((self.mount/c/'z.log').read_bytes()).hexdigest(),before[c+'/z.log'])

    def test_nonlogs_and_single(self):
        self.write(self.mount/'filler.bin',26)
        self.write(self.mount/COMP[0]/'z.log',1)
        before=self.snapshot(); result=self.guard(40)
        self.assertEqual(result.returncode,5,result.stdout+result.stderr)
        self.assertIn('всё ещё',result.stdout)
        self.assertEqual(before,self.snapshot())

    def test_single_large_current(self):
        self.write(self.mount/COMP[0]/'z.log',26)
        before=self.snapshot(); result=self.guard(40)
        self.assertEqual(result.returncode,5,result.stdout+result.stderr)
        self.assertEqual(before,self.snapshot())

    def test_real_enospc(self):
        self.write(self.mount/COMP[0]/'a.log',22,random=True)
        self.write(self.mount/COMP[0]/'z.log',1,random=True)
        # Fill every available block with real writes; reaching ENOSPC is required.
        fill=subprocess.run(['dd','if=/dev/urandom',f'of={self.mount / "filler.bin"}',
                             'bs=65536','status=none'],capture_output=True,text=True,
                            env=dict(os.environ,LC_ALL='C'))
        self.assertNotEqual(fill.returncode,0)
        self.assertIn('No space left on device',fill.stderr)
        before=self.snapshot(); result=self.guard(90)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('No space left on device',result.stderr)
        self.assertIn('исходники сохранены',result.stderr)
        self.assertEqual(before,self.snapshot())
        self.assertFalse(list(self.mount.rglob('*.part')))
        self.assertFalse(list(self.mount.rglob('*.tar.gz')))
