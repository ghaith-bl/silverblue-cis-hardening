#
# tests for netprivacy/nm-dispatcher/50-netprivacy (stdlib + /bin/sh, no NetworkManager)
#
#   python3 -I -m unittest discover -s tests -t .
#
# A fake nmcli (and logger) first in PATH keeps one profile in a json file: the hook
# reads it, changes it, reapplies the device. What the hook ran is logged per call.
#
import json
import os
import subprocess
import sys
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    'netprivacy', 'nm-dispatcher', '50-netprivacy')
UUID = '-'.join(('a' * 8, 'b' * 4, '4' + 'c' * 3, '8' + 'd' * 3, 'e' * 12))   # made up

FAKE_NMCLI = r'''
import json, os, sys
st_path = os.environ['FAKE_STATE']
st = json.load(open(st_path))
a = sys.argv[1:]
st['calls'].append(a)
def save():
    json.dump(st, open(st_path, 'w'))
rc = 0
if a[:1] == ['-g'] and a[2:4] == ['connection', 'show']:
    if a[4] != st['uuid']:
        rc = 10
    else:
        print('\n'.join(st['type'] if f == 'connection.type' else st['props'][f]
                        for f in a[1].split(',')))
elif a[:2] == ['connection', 'modify']:
    if st.get('fail_modify'):
        rc = 1
    else:
        kv = a[3:]
        for k, v in zip(kv[0::2], kv[1::2]):
            st['props'][k] = {'no': '0'}.get(v, v) if 'send-hostname' in k else v
elif a[:2] == ['device', 'reapply']:
    rc = 1 if st.get('fail_reapply') else 0
save()
sys.exit(rc)
'''

NEW_WIFI = {   # a profile GNOME just made for a new network (NetworkManager 1.56 output)
    'ipv4.dns': '', 'ipv4.ignore-auto-dns': 'no', 'ipv6.dns': '',
    'ipv6.ignore-auto-dns': 'no', 'ipv4.dhcp-send-hostname': '-1',
    'ipv6.dhcp-send-hostname': '-1', 'ipv6.method': 'auto',
}
CLEAN = dict(NEW_WIFI, **{'ipv4.ignore-auto-dns': 'yes', 'ipv6.ignore-auto-dns': 'yes',
                          'ipv4.dhcp-send-hostname': '0', 'ipv6.dhcp-send-hostname': '0',
                          'ipv6.method': 'disabled'})


class Hook(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        with open(os.path.join(d, 'nmcli'), 'w') as f:
            f.write(f'#!{sys.executable} -I\n' + FAKE_NMCLI)
        with open(os.path.join(d, 'logger'), 'w') as f:
            f.write('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_LOG"\n')
        for n in ('nmcli', 'logger'):
            os.chmod(os.path.join(d, n), 0o755)
        self.state = os.path.join(d, 'state.json')
        self.log = os.path.join(d, 'log')
        open(self.log, 'w').close()

    def tearDown(self):
        self.dir.cleanup()

    def run_hook(self, props, action='up', uuid=UUID, typ='802-11-wireless', hook=HOOK, **st):
        json.dump(dict(uuid=UUID, type=typ, props=dict(props), calls=[], **st),
                  open(self.state, 'w'))
        env = {'PATH': self.dir.name + ':/usr/bin:/bin', 'FAKE_STATE': self.state,
               'FAKE_LOG': self.log, 'CONNECTION_UUID': uuid}
        r = subprocess.run(['/bin/sh', hook, 'wlp0s20f3', action], env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stderr), (0, ''))
        out = json.load(open(self.state))
        return out, open(self.log).read()

    def verbs(self, out):
        return [c[:2] if c[0] != '-g' else ['show', c[1]] for c in out['calls']]

    def test_new_wifi_fixed_and_reapplied(self):
        out, log = self.run_hook(NEW_WIFI)
        self.assertEqual(out['props'], CLEAN)
        self.assertIn(['device', 'reapply', 'wlp0s20f3'], out['calls'])
        self.assertIn(f'profile {UUID}: no DNS, no hostname in DHCP, IPv6 disabled; reapplied', log)

    def test_cable_too(self):
        out, _ = self.run_hook(NEW_WIFI, typ='802-3-ethernet')
        self.assertEqual(out['props'], CLEAN)

    def test_clean_profile_no_reapply(self):
        out, log = self.run_hook(CLEAN)
        self.assertEqual(out['props'], CLEAN)
        self.assertNotIn(['device', 'reapply', 'wlp0s20f3'], out['calls'])
        self.assertEqual(log, '')

    def test_static_dns_removed(self):
        out, _ = self.run_hook(dict(CLEAN, **{'ipv4.dns': '192.0.2.53'}))
        self.assertEqual(out['props']['ipv4.dns'], '')

    def test_other_actions_and_types_untouched(self):
        for kw in (dict(action='down'), dict(action='reapply'), dict(action='pre-up'),
                   dict(typ='wireguard'), dict(typ='tun'), dict(typ='bridge')):
            out, log = self.run_hook(NEW_WIFI, **kw)
            self.assertEqual(out['props'], NEW_WIFI, kw)
            self.assertEqual(log, '', kw)
            self.assertFalse([c for c in out['calls'] if c[0] != '-g'], kw)

    def test_bad_uuid_no_call(self):
        for u in ('', 'x; reboot', '../../etc', UUID.upper()):
            out, _ = self.run_hook(NEW_WIFI, uuid=u)
            self.assertEqual(out['calls'], [], u)

    def test_modify_fails_logged(self):
        out, log = self.run_hook(NEW_WIFI, fail_modify=True)
        self.assertEqual(out['props'], NEW_WIFI)
        self.assertIn('not changed (nmcli modify failed)', log)

    def test_reapply_fails_logged(self):
        _, log = self.run_hook(NEW_WIFI, fail_reapply=True)
        self.assertIn('reapply on wlp0s20f3 failed: reconnect it', log)

    def test_keep_ipv6(self):
        # what netprivacy installs with UPLINK_IPV6=keep (same sed as the section)
        keep = os.path.join(self.dir.name, '50-netprivacy')
        with open(HOOK) as f, open(keep, 'w') as g:
            g.write(subprocess.run(['sed', 's/^IPV6_METHOD=[a-z]*/IPV6_METHOD=/'], stdin=f,
                                   capture_output=True, text=True, check=True).stdout)
        out, log = self.run_hook(NEW_WIFI, hook=keep)
        self.assertEqual(out['props']['ipv6.method'], 'auto')
        self.assertEqual(out['props']['ipv4.ignore-auto-dns'], 'yes')
        self.assertIn('no DNS, no hostname in DHCP; reapplied', log)

    def test_installed_line(self):
        with open(HOOK) as f:
            self.assertEqual(sum(1 for ln in f if ln.startswith('IPV6_METHOD=disabled ')), 1)


if __name__ == '__main__':
    unittest.main()
