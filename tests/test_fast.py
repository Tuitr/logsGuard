"""Real Bash/tar/files, mocked OS boundaries only. Python standard library."""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMP = ['auth_service', 'data_process_service', 'system_event_handler_service']

class Guard(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='logs-guard-fast-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.logs = self.base / 'logs'
        self.bin = self.base / 'bin'
        self.bin.mkdir(); self.logs.mkdir()
        for c in COMP:
            d = self.logs / c; d.mkdir()
            for name in ['-old.log', 'middle space\nline.log', 'z-current.log']:
                (d / name).write_bytes((name * 20).encode())
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin', LOGS_DIR=str(self.logs),
                        THRESHOLD='90', USED='90', SIZES='901 0 0')
        self.mock('id', 'echo 0')
        self.mock('mountpoint', 'exit 0')
        self.mock('df', 'printf " Size Use%%\\n 3000 %s%%\\n" "$USED"')
        self.mock('du', '''case "$*" in
*auth_service) n=1;; *data_process_service) n=2;; *) n=3;; esac
read -r -a sizes <<< "$SIZES"
printf '%s\\t%s\\n' "${sizes[n-1]}" "${!#}"''')

    def mock(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\n' + body + '\n'); p.chmod(0o755)

    def run_guard(self, expected, **env):
        result = subprocess.run(['bash', str(ROOT / 'logs_guard.sh')], env=self.env | env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertTrue(result.stdout or result.stderr)
        if expected != 4: self.assertFalse(list(self.logs.rglob('*.part')))
        return result.stdout + result.stderr

    def snapshot(self):
        return {str(p.relative_to(self.logs)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.logs.rglob('*') if p.is_file()}

    def verify_archives(self, before, selected):
        for c in COMP:
            d = self.logs / c
            archives = list(d.glob('*.tar.gz'))
            self.assertEqual(len(archives), int(c in selected))
            if c in selected:
                with tarfile.open(archives[0]) as tf:
                    self.assertEqual(tf.getnames(), ['-old.log', 'middle space\nline.log'])
                    for member in tf.getmembers():
                        self.assertEqual(hashlib.sha256(tf.extractfile(member).read()).hexdigest(),
                                         before[f'{c}/{member.name}'])
                self.assertEqual(sorted(p.name for p in d.glob('*.log')), ['z-current.log'])
            for name, checksum in before.items():
                if name.startswith(c + '/') and (c not in selected or name.endswith('z-current.log')):
                    self.assertEqual(hashlib.sha256((self.logs / name).read_bytes()).hexdigest(), checksum)

    def test_boundaries_and_selection(self):
        for used, sizes, chosen, code in [
            ('89','999 999 999',[],0), ('90','900 900 900',[],5),
            ('90','901 0 0',COMP[:1],5), ('90','901 901 0',COMP[:2],5),
            ('90','901 901 901',COMP,5)]:
            with self.subTest(used=used, sizes=sizes):
                # Each case needs fresh data.
                for c in COMP:
                    for p in (self.logs/c).iterdir(): p.unlink()
                    for name in ['-old.log','middle space\nline.log','z-current.log']:
                        (self.logs/c/name).write_text(name * 20)
                before = self.snapshot()
                self.run_guard(code, USED=used, SIZES=sizes)
                self.verify_archives(before, chosen)

    def test_thresholds(self):
        for value in ['', '0', '-1', '101', '1.5', 'abc', ' ', ' 90', '9'*10000, '0001']:
            with self.subTest(value=value[:20]):
                before = self.snapshot()
                self.assertIn('THRESHOLD', self.run_guard(3, THRESHOLD=value))
                self.assertEqual(before, self.snapshot())
        for value in ['1', '100', '001', '090', '010']:
            self.run_guard(0, THRESHOLD=value, USED='0')
        del self.env['THRESHOLD']
        self.assertIn('порог: 90%', self.run_guard(0, USED='89'))

    def test_empty_single_and_symlink(self):
        for p in (self.logs/COMP[0]).iterdir(): p.unlink()
        self.run_guard(5)
        d=self.logs/COMP[0]; (d/'only.log').write_text('current')
        (d/'zz-link.log').symlink_to(d/'only.log')
        before=self.snapshot(); self.run_guard(5)
        self.assertEqual(before,self.snapshot())

    def test_environment(self):
        for cmd, body, message in [('id','echo 1000','root'), ('mountpoint','exit 1','смонтирован')]:
            self.mock(cmd,body); before=self.snapshot()
            self.assertIn(message,self.run_guard(2)); self.assertEqual(before,self.snapshot())
            self.mock(cmd, 'echo 0' if cmd=='id' else 'exit 0')
        (self.logs/COMP[0]).rename(self.logs/'missing')
        self.assertIn('компонента',self.run_guard(2))

    def test_command_failures(self):
        for cmd, body in [('df','exit 1'),('df','echo invalid'),('du','exit 1'),('du','echo invalid'),
                          ('find','exit 1'),('sort','exit 1'),
                          ('tar','echo partial > "$2"; echo "No space left on device" >&2; exit 2'),
                          ('tar','echo "read error" >&2; exit 2')]:
            with self.subTest(cmd=cmd,body=body):
                self.mock(cmd,body); before=self.snapshot()
                self.assertIn('ОШИБКА', self.run_guard(1)); self.assertEqual(before,self.snapshot())
                (self.bin/cmd).unlink()
                if cmd=='df': self.mock('df','printf " Size Use%%\\n 3000 %s%%\\n" "$USED"')
                if cmd=='du': self.mock('du','printf "901\\t%s\\n" "${!#}"')

    def test_read_failure_and_other_component(self):
        # Fault injection represents a read(2) error on one selected source.
        self.mock('tar', 'if [[ $* == *auth_service* ]]; then echo "tar: -old.log: Read error" >&2; echo partial > "$2"; exit 2; fi\nexec /usr/bin/tar "$@"')
        before=self.snapshot()
        self.assertIn('Read error',self.run_guard(1,SIZES='901 901 0'))
        for name,checksum in before.items():
            if name.startswith(COMP[0]+'/'):
                self.assertEqual(hashlib.sha256((self.logs/name).read_bytes()).hexdigest(),checksum)
        self.assertFalse(list((self.logs/COMP[0]).glob('*.tar.gz')))
        self.assertEqual(len(list((self.logs/COMP[1]).glob('*.tar.gz'))),1)

    def test_delete_error_and_aggregate(self):
        self.mock('rm','for p in "$@"; do [[ $p == *auth_service/*.log ]] && exit 1; done\nexec /usr/bin/rm "$@"')
        before=self.snapshot()
        self.assertIn('удаление исходников',self.run_guard(1,SIZES='901 901 0'))
        self.assertTrue((self.logs/COMP[0]/'-old.log').exists())
        self.assertFalse((self.logs/COMP[1]/'-old.log').exists())
        self.assertEqual(len(list(self.logs.rglob('*.tar.gz'))),2)

    def test_collision(self):
        target=self.logs/COMP[0]/'existing.tar.gz'; target.write_bytes(b'keep')
        part=self.logs/COMP[0]/'existing.part'
        self.mock('mktemp', f'if [[ $* == *archive* ]]; then (set -C; : > "{part}") || exit 1; echo "{part}"; else exec /usr/bin/mktemp "$@"; fi')
        before=self.snapshot(); self.run_guard(1)
        self.assertEqual(before,self.snapshot())

    def test_repeat_and_post_usage(self):
        before=self.snapshot(); self.assertIn('всё ещё',self.run_guard(5))
        after=self.snapshot(); self.run_guard(5); self.assertEqual(after,self.snapshot())
        self.verify_archives(before,COMP[:1])
        self.run_guard(0,USED='1')

    def test_post_check(self):
        counter=self.base/'df-called'
        self.mock('df', f'if [[ -e "{counter}" ]]; then echo " Size Use%"; echo " 3000 10%"; else touch "{counter}"; echo " Size Use%"; echo " 3000 90%"; fi')
        self.run_guard(0)
        counter.unlink()
        self.mock('df', f'if [[ -e "{counter}" ]]; then exit 1; else touch "{counter}"; echo " Size Use%"; echo " 3000 90%"; fi')
        self.assertIn('df',self.run_guard(1))

    def test_access_and_missing_command(self):
        d=self.logs/COMP[0]
        d.chmod(0o500)
        try:
            if os.geteuid()!=0:
                before=self.snapshot(); self.run_guard(2); self.assertEqual(before,self.snapshot())
        finally: d.chmod(0o700)
        # A Bash function models command discovery failure without breaking PATH.
        self.env['BASH_ENV']=str(self.base/'bashenv')
        (self.base/'bashenv').write_text('command() { if [[ $2 == tar ]]; then return 1; else builtin command "$@"; fi; }\n')
        before=self.snapshot(); self.assertIn('нет команды tar',self.run_guard(2))
        self.assertEqual(before,self.snapshot())

    def test_concurrent(self):
        marker=self.base/'ready'
        self.mock('tar', f'touch "{marker}"\nsleep 1\nexec /usr/bin/tar "$@"')
        first=subprocess.Popen(['bash',str(ROOT/'logs_guard.sh')],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            import time
            deadline=time.monotonic()+5
            while not marker.exists() and time.monotonic()<deadline: time.sleep(.02)
            self.assertTrue(marker.exists())
            self.assertIn('другой запуск',self.run_guard(4))
        finally:
            out,err=first.communicate(timeout=10)
        self.assertEqual(first.returncode,5,(out,err))
        self.assertEqual(len(list(self.logs.rglob('*.tar.gz'))),1)

if __name__ == '__main__': unittest.main()
