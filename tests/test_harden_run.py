#
# tests for harden-workstation.sh run behavior (stdlib + bash, no root, nothing outside a
# temp dir): file helpers change a file only when its content differs, backups only of
# what changed, a failed command stops the run with section / line / command, a summary
# at every end, no backup folder when nothing changed.
#
#   python3 -I -m unittest discover -s tests -t .
#
# The script is sourced (main runs only when executed); sections are replaced by test
# functions, so no real section runs here.
#
import os
import re
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      'harden-workstation.sh')
ANSI = re.compile(r'\x1b\[[0-9;]*m')


def read(path):
    with open(path) as f:
        return f.read()


def write(path, text):
    with open(path, 'w') as f:
        f.write(text)


class Run(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.d = self.dir.name
        self.bk = os.path.join(self.d, 'backup')

    def tearDown(self):
        self.dir.cleanup()

    def bash(self, body):
        """source the script, BACKUP_ROOT in the temp dir, then body; (rc, output)"""
        code = f'source "$1"; BACKUP_ROOT="{self.bk}"; cd "{self.d}"\n{body}'
        r = subprocess.run(['bash', '-c', code, 'test', SCRIPT], capture_output=True,
                           text=True, timeout=60,
                           env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': self.d})
        return r.returncode, ANSI.sub('', r.stdout + r.stderr)

    def backups(self):
        out = []
        for root, _, files in os.walk(self.bk):
            out += [os.path.relpath(os.path.join(root, f), self.bk) for f in files]
        return sorted(out)

    def test_write_file_only_when_content_differs(self):
        f = os.path.join(self.d, 'etc', 'a.conf')
        rc, out = self.bash(f'''
            sec_sysctl()   {{ echo one | write_file "{f}" 0644; }}
            sec_modules()  {{ echo one | write_file "{f}" 0644; }}
            sec_coredump() {{ echo two | write_file "{f}" 0644; }}
            sec_journald() {{ echo two | write_file "{f}" 0600; }}
            run_sections sysctl modules coredump journald
            ''')
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r'sysctl +1 change')
        self.assertRegex(out, r'modules +no change')
        self.assertRegex(out, r'coredump +1 change')
        self.assertRegex(out, r'journald +1 change')
        self.assertIn('mode 0600', out)
        self.assertEqual(read(f), 'two\n')
        self.assertEqual(os.stat(f).st_mode & 0o777, 0o600)
        # the original of the run (content "one"), not a later state
        self.assertEqual(self.backups(), [os.path.relpath(f, '/')])
        self.assertEqual(read(os.path.join(self.bk, os.path.relpath(f, '/'))), 'one\n')

    def test_second_run_no_change_no_backup_folder(self):
        f = os.path.join(self.d, 'b.conf')
        write(f, '# deny = 3\nother = 1\n')
        body = f'''
            sec_pam() {{ set_kv "{f}" deny 5; set_kv "{f}" unlock_time 900; }}
            run_sections pam
            '''
        rc, out = self.bash(body)
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r'pam +1 change')     # two keys, one file: one change
        self.assertEqual(read(f), 'deny = 5\nother = 1\nunlock_time = 900\n')
        self.assertEqual(read(os.path.join(self.bk, os.path.relpath(f, '/'))),
                         '# deny = 3\nother = 1\n')
        self.bk = os.path.join(self.d, 'backup2')
        rc, out = self.bash(body)
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r'pam +no change')
        self.assertIn('Backups: none', out)
        self.assertNotIn('Reboot recommended', out)
        self.assertFalse(os.path.exists(self.bk))

    def test_failed_command_in_substitution_stops_with_place(self):
        # the H3 case: a missing command inside $(...) with 2>/dev/null used to end the
        # run without a word
        rc, out = self.bash('''
            sec_sysctl()  { log first; }
            sec_modules() { local have; have=$(no-such-command-x 2>/dev/null | awk '{print}'); log "not reached $have"; }
            sec_kargs()   { log never; }
            run_sections sysctl modules kargs
            ''')
        self.assertEqual(rc, 127, out)
        self.assertRegex(out, r'STOP: section modules, sec_modules line \d+, exit 127: '
                              r'have=\$\(no-such-command-x')
        self.assertEqual(out.count('STOP:'), 1, out)            # not again from the subshell
        self.assertNotIn('not reached', out)
        self.assertNotIn('never', out)
        self.assertRegex(out, r'sysctl +no change')
        self.assertRegex(out, r'modules +STOPPED \(exit 127\)')
        self.assertIn('not run: kargs', out)
        self.assertIn('Backups: none', out)

    def test_failed_function_in_pipeline_stops(self):
        write(os.path.join(self.d, 'plain'), '')      # a file, not a folder
        rc, out = self.bash(f'''
            sec_sysctl() {{ echo x | write_file "{self.d}/plain/sub/y.conf" 0644; log after; }}
            run_sections sysctl
            ''')
        self.assertNotEqual(rc, 0, out)
        self.assertRegex(out, r'STOP: section sysctl, sec_sysctl line \d+')
        self.assertNotIn('after', out)

    def test_die_shows_stopped_section(self):
        rc, out = self.bash('''
            sec_sysctl() { die "PTRACE_SCOPE must be 1, 2 or 3"; }
            sec_modules() { :; }
            run_sections sysctl modules
            ''')
        self.assertEqual(rc, 1, out)
        self.assertIn('PTRACE_SCOPE must be', out)
        self.assertRegex(out, r'sysctl +STOPPED \(exit 1\)')
        self.assertIn('not run: modules', out)

    def test_handled_failures_do_not_stop(self):
        rc, out = self.bash('''
            sec_sysctl() {
              if false; then :; fi
              false || true
              x=$(false || true)
              [[ $(false | cat) == y ]] || log "condition ok"
              if ! command -v no-such-command-x >/dev/null; then log "missing tool: skipped"; fi
            }
            run_sections sysctl
            ''')
        self.assertEqual(rc, 0, out)
        self.assertNotIn('STOP', out)
        self.assertIn('condition ok', out)
        self.assertRegex(out, r'sysctl +no change')


if __name__ == '__main__':
    unittest.main()
