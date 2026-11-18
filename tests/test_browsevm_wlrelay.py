#
# tests for browsevm/browsevm-wlrelay.py (stdlib only, no compositor needed)
#
#   python3 -I -m unittest discover -s tests -t .
#
# A fake compositor (listening socket in a temp dir, thread in this process) and a fake
# client (python child that uses WAYLAND_SOCKET) around the real relay. Messages are
# 8 bytes: sequence number + "has fd"; an fd holds its sequence number. The receiver
# hands the fds that arrived to the messages in order, like libwayland does.
#
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

RELAY = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     'browsevm', 'browsevm-wlrelay.py')

# shared by the test and the child: send / receive messages with fds
PROTO = r'''
import array, os, socket, struct

def make_fd(seq):
    fd = os.memfd_create('t')
    os.write(fd, struct.pack('<I', seq))
    return fd

def send_msgs(sock, first, count, fd_every):
    for seq in range(first, first + count):
        has = seq % fd_every == 0
        data = struct.pack('<II', seq, 1 if has else 0)
        if has:
            fd = make_fd(seq)
            sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))])
            os.close(fd)
        else:
            sock.sendall(data)

def recv_all(sock, want_msgs):
    buf, fds = b'', []
    while len(buf) < want_msgs * 8:
        data, anc, flags, _ = sock.recvmsg(65536, socket.CMSG_SPACE(253 * 4))
        if not data:
            break
        buf += data
        for level, kind, cdata in anc:
            a = array.array('i')
            a.frombytes(cdata[:len(cdata) - len(cdata) % 4])
            fds.extend(a)
    return buf, fds

def check(buf, fds, want_msgs):
    bad, it = 0, iter(fds)
    for i in range(len(buf) // 8):
        seq, has = struct.unpack_from('<II', buf, i * 8)
        if has:
            fd = next(it, None)
            if fd is None or struct.unpack('<I', os.pread(fd, 4, 0))[0] != seq:
                bad += 1
            if fd is not None:
                os.close(fd)
    return len(buf) // 8 == want_msgs and bad == 0 and next(it, None) is None
'''
exec(PROTO)   # the same helpers here, for the fake compositor


class FakeCompositor(threading.Thread):
    """accepts one client, then runs behave(conn)"""

    def __init__(self, path, behave):
        super().__init__(daemon=True)
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(1)
        self.behave = behave
        self.result = None

    def run(self):
        self.srv.settimeout(20)
        try:
            conn, _ = self.srv.accept()
        except OSError:
            return
        conn.settimeout(20)
        try:
            self.result = self.behave(conn)
        finally:
            conn.close()
            self.srv.close()


class RelayTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = dict(os.environ, XDG_RUNTIME_DIR=self.tmp.name, WAYLAND_DISPLAY='wl-x',
                        DISPLAY=':9')
        self.path = os.path.join(self.tmp.name, 'wl-x')

    def tearDown(self):
        self.tmp.cleanup()

    def relay(self, child_code, *extra, timeout=60):
        cmd = [sys.executable, '-I', RELAY] + list(extra) + \
              ['--', sys.executable, '-I', '-c', PROTO + child_code]
        return subprocess.run(cmd, env=self.env, capture_output=True, text=True, timeout=timeout)

    def test_bytes_and_fds_both_ways_in_order(self):
        def behave(conn):
            buf, fds = recv_all(conn, 3000)
            ok = check(buf, fds, 3000)
            send_msgs(conn, 1, 500, 3)
            conn.shutdown(socket.SHUT_WR)
            return ok
        comp = FakeCompositor(self.path, behave)
        comp.start()
        child = '''
import sys
s = socket.socket(fileno=int(os.environ['WAYLAND_SOCKET']))
send_msgs(s, 1, 3000, 7)
buf, fds = recv_all(s, 500)
sys.exit(0 if check(buf, fds, 500) else 9)
'''
        r = self.relay(child)
        comp.join(30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(comp.result, 'compositor saw wrong bytes / fds')
        self.assertIn('end: ', r.stderr)

    def test_busy_compositor_does_not_block_the_client(self):
        size = 2 << 20

        def behave(conn):
            time.sleep(1.5)                      # busy: reads nothing
            got = 0
            while got < size:
                d = conn.recv(65536)
                if not d:
                    break
                got += len(d)
            return got
        comp = FakeCompositor(self.path, behave)
        comp.start()
        child = '''
import sys, time
s = socket.socket(fileno=int(os.environ['WAYLAND_SOCKET']))
t = time.monotonic()
s.sendall(b'x' * (2 << 20))
print('%.3f' % (time.monotonic() - t))
time.sleep(2)
'''
        r = self.relay(child)
        comp.join(30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(comp.result, size)
        self.assertLess(float(r.stdout.strip()), 1.0, 'client waited for the busy compositor')
        wait = float(r.stderr.split('viewer->desktop max')[1].split('longest wait ')[1].split(' s')[0])
        self.assertGreater(wait, 1.0, r.stderr)

    def test_queue_limit_ends_the_command(self):
        def behave(conn):
            time.sleep(5)                        # never reads in time
        comp = FakeCompositor(self.path, behave)
        comp.start()
        child = '''
s = socket.socket(fileno=int(os.environ['WAYLAND_SOCKET']))
try:
    s.sendall(b'y' * (3 << 20))
except OSError:
    pass
import time; time.sleep(30)
'''
        r = self.relay(child, '--limit-mib', '1')
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertIn('browsevm-wlrelay: queue limit', r.stderr)

    def test_no_compositor_no_start(self):
        marker = os.path.join(self.tmp.name, 'started')
        r = self.relay('open(%r, "w").close()' % marker)
        self.assertEqual(r.returncode, 69, r.stderr)
        self.assertFalse(os.path.exists(marker))
        env = dict(self.env)
        del env['WAYLAND_DISPLAY']
        r = subprocess.run([sys.executable, '-I', RELAY, '--', 'true'], env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 69, r.stderr)

    def test_environment_and_placeholder(self):
        comp = FakeCompositor(self.path, lambda conn: conn.recv(1))
        comp.start()
        cmd = [sys.executable, '-I', RELAY, '--', sys.executable, '-I', '-c',
               'import os, sys; print(sys.argv[1], os.environ.get("WAYLAND_SOCKET"), '
               'os.environ.get("WAYLAND_DISPLAY"), os.environ.get("DISPLAY"))',
               '@WAYLAND_SOCKET@']
        r = subprocess.run(cmd, env=self.env, capture_output=True, text=True, timeout=30)
        comp.join(10)
        self.assertEqual(r.returncode, 0, r.stderr)
        arg, ws, wd, disp = r.stdout.split()
        self.assertEqual(arg, ws)
        self.assertTrue(ws.isdigit())
        self.assertEqual((wd, disp), ('None', 'None'))

    def test_exit_status(self):
        for code, want in (('import sys; sys.exit(3)', 3),
                           ('import os, signal; os.kill(os.getpid(), signal.SIGKILL)', 137)):
            if os.path.exists(self.path):
                os.unlink(self.path)
            comp = FakeCompositor(self.path, lambda conn: conn.recv(1))
            comp.start()
            r = self.relay(code)
            comp.join(10)
            self.assertEqual(r.returncode, want, r.stderr)

    def test_compositor_close_reaches_the_client(self):
        def behave(conn):
            conn.sendall(b'bye')                 # like a protocol error event, then close
        comp = FakeCompositor(self.path, behave)
        comp.start()
        child = '''
import sys
s = socket.socket(fileno=int(os.environ['WAYLAND_SOCKET']))
got = b''
while True:
    d = s.recv(10)
    if not d:
        break
    got += d
sys.exit(0 if got == b'bye' else 8)
'''
        r = self.relay(child)
        comp.join(10)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('end: desktop closed the connection', r.stderr)


if __name__ == '__main__':
    unittest.main()
