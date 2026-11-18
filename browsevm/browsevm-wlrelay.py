#!/usr/bin/python3 -I
#
# browsevm-wlrelay - Wayland relay for the browsevm viewer (beta, docs/browsevm.md)
#
#   python3 -I browsevm-wlrelay.py [--limit-mib N] -- <command> [args...]
#
# Why: GTK 3 ends a client with _exit(1) when its socket to the compositor is full
# (wl_display_flush() -> EAGAIN, gdk/wayland/gdkeventsource.c, unchanged on gtk-3-24 in
# 2026-10): GNOME Shell busy for a moment = remote-viewer gone. Firefox ships the same
# kind of relay (wayland-proxy, Firefox 121) for the same crash.
#
# - connects to the compositor first ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY); no compositor =
#   exit 69, the command is never started (no fallback to X11)
# - the command gets its end of a socketpair as WAYLAND_SOCKET: no path on disk, no other
#   process can connect. An argument "@WAYLAND_SOCKET@" becomes that fd number (for
#   bwrap --setenv). WAYLAND_DISPLAY and DISPLAY are removed from its environment: its
#   only way to the screen is this relay
# - reads both sides at once and keeps what the other side cannot take yet. Bytes and file
#   descriptors are passed on as they come, never parsed or changed; fds leave with (or
#   before) the bytes they came with, at most 28 per send (libwayland MAX_FDS_OUT: the
#   most its receiver takes at once)
# - limits per direction: 64 MiB (--limit-mib) and 8192 file descriptors waiting (less
#   when the open files limit is low); above one the command is ended, exit 75 and the
#   line "browsevm-wlrelay: queue limit ..." (the launcher then opens the viewer again)
# - at the end one line on stderr: largest queue and longest wait per direction, end
#   reason, exit status. No content, nothing written to disk
# - exit status = the command's (128 + signal number when a signal ended it)
#
import array
import collections
import os
import resource
import selectors
import signal
import socket
import subprocess
import sys
import time

MAX_FDS = 28                    # libwayland MAX_FDS_OUT
CHUNK = 65536                   # bytes per read
BATCH = 262144                  # bytes per send at most
ANC = socket.CMSG_SPACE(253 * array.array('i').itemsize)   # SCM_MAX_FD: see every fd sent
PLACEHOLDER = '@WAYLAND_SOCKET@'
EX_UNAVAILABLE, EX_SOFTWARE, EX_TEMPFAIL = 69, 70, 75
DATA, NONE, EOF = 'data', 'none', 'eof'


class Fatal(Exception):
    """the stream cannot be passed on correctly: end everything"""


class Limit(Exception):
    """a queue grew past the limit"""


def say(msg):
    sys.stderr.write('browsevm-wlrelay: %s\n' % msg)
    sys.stderr.flush()


def close_all(fds):
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


class Way:
    """one direction: read from src, keep, write to dst"""

    def __init__(self, name, src, dst, limit, max_fds):
        self.name = name
        self.src = src
        self.dst = dst
        self.limit = limit
        self.max_fds = max_fds
        self.q = collections.deque()      # [memoryview, [fds not sent yet]]
        self.size = 0
        self.nfds = 0                     # fds waiting in q
        self.peak = 0
        self.since = None                 # when the queue stopped draining
        self.longest = 0.0
        self.eof = False                  # src ended
        self.broken = False               # dst gone

    def read(self):
        """one read from src: DATA, NONE (nothing now) or EOF"""
        try:
            data, anc, flags, _ = self.src.recvmsg(CHUNK, ANC, socket.MSG_CMSG_CLOEXEC)
        except (BlockingIOError, InterruptedError):
            return NONE
        except (ConnectionResetError, BrokenPipeError):
            return EOF
        fds = []
        for level, kind, cdata in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array('i')
                a.frombytes(cdata[:len(cdata) - len(cdata) % a.itemsize])
                fds.extend(a)
        if flags & socket.MSG_CTRUNC:
            close_all(fds)
            raise Fatal('%s: file descriptors cut off' % self.name)
        if not data:
            close_all(fds)
            if fds:
                raise Fatal('%s: file descriptors without data' % self.name)
            return EOF
        if len(fds) > MAX_FDS:
            close_all(fds)
            raise Fatal('%s: %d file descriptors in one message' % (self.name, len(fds)))
        self.q.append([memoryview(data), fds])
        self.size += len(data)
        self.nfds += len(fds)
        self.peak = max(self.peak, self.size)
        if self.size > self.limit:
            raise Limit('%s over %d MiB' % (self.name, self.limit >> 20))
        if self.nfds > self.max_fds:
            raise Limit('%s over %d file descriptors' % (self.name, self.max_fds))
        return DATA

    def write(self):
        """send as much as dst takes now"""
        while self.q and not self.broken:
            bufs, fds, n_items, n_bytes = [], [], 0, 0
            for data, item_fds in self.q:
                if bufs and (len(fds) + len(item_fds) > MAX_FDS or n_bytes >= BATCH):
                    break
                bufs.append(data)
                fds.extend(item_fds)
                n_items += 1
                n_bytes += len(data)
            anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', fds))] if fds else []
            try:
                sent = self.dst.sendmsg(bufs, anc, socket.MSG_NOSIGNAL)
            except (BlockingIOError, InterruptedError):
                self._stalled()
                return
            except (BrokenPipeError, ConnectionResetError):
                self.broken = True
                return
            # every fd of this send went out with its first byte: ours can go
            close_all(fds)
            for i in range(n_items):
                self.q[i][1] = []
            self.nfds -= len(fds)
            self.size -= sent
            left = sent
            while left:
                head = self.q[0][0]
                if left >= len(head):
                    left -= len(head)
                    self.q.popleft()
                else:
                    self.q[0][0] = head[left:]
                    left = 0
            if sent < n_bytes:            # dst took less: full for now
                self._stalled()
                return
        if not self.q:
            self._drained()

    def _stalled(self):
        if self.since is None:
            self.since = time.monotonic()

    def _drained(self):
        if self.since is not None:
            self.longest = max(self.longest, time.monotonic() - self.since)
            self.since = None

    def longest_wait(self):
        if self.since is not None:
            return max(self.longest, time.monotonic() - self.since)
        return self.longest

    def drop(self):
        for _, fds in self.q:
            close_all(fds)
        self.q.clear()
        self.size = 0
        self.nfds = 0


def compositor_path():
    disp = os.environ.get('WAYLAND_DISPLAY', '')
    if not disp:
        return None
    if disp.startswith('/'):
        return disp
    rt = os.environ.get('XDG_RUNTIME_DIR', '')
    return os.path.join(rt, disp) if rt.startswith('/') else None


def parse(argv):
    usage = 'usage: browsevm-wlrelay [--limit-mib N] -- <command> [args...]'
    limit = 64
    args = list(argv)
    while args and args[0] != '--':
        a = args.pop(0)
        if a == '--limit-mib' and args:
            v = args.pop(0)
            if not v.isdigit() or not 1 <= int(v) <= 4096:
                raise SystemExit('browsevm-wlrelay: --limit-mib takes 1..4096')
            limit = int(v)
        else:
            raise SystemExit(usage)
    if len(args) < 2:
        raise SystemExit(usage)
    return limit << 20, args[1:]


def relay(up, down, child):
    """pass both directions on until one side ends; returns the reason"""
    sel = selectors.DefaultSelector()
    socks = {up.src: (up, down), down.src: (down, up)}    # socket -> (way it feeds, way it drains)
    registered = {}
    try:
        while True:
            if up.eof or down.broken:
                up.write()                                 # the viewer's last words, best effort
                return 'viewer closed'
            if down.eof or up.broken:
                # the compositor ended, maybe after a protocol error event: read what is
                # left, hand it to the viewer, then close the viewer's side
                while not down.eof and down.read() == DATA:
                    pass
                deadline = time.monotonic() + 2
                while down.q and not down.broken and time.monotonic() < deadline:
                    down.write()
                    if down.q:
                        time.sleep(0.01)
                try:
                    up.src.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return 'desktop closed the connection'
            for sock, (feeds, drains) in socks.items():
                ev = selectors.EVENT_READ
                if drains.q:
                    ev |= selectors.EVENT_WRITE
                if sock not in registered:
                    sel.register(sock, ev)
                elif registered[sock] != ev:
                    sel.modify(sock, ev)
                registered[sock] = ev
            for key, mask in sel.select(timeout=1.0):
                feeds, drains = socks[key.fileobj]
                if mask & selectors.EVENT_READ:
                    got = feeds.read()
                    if got == DATA:
                        feeds.write()
                    elif got == EOF:
                        feeds.eof = True
                if mask & selectors.EVENT_WRITE:
                    drains.write()
            if child.poll() is not None and not up.eof:
                # the command ended; its end of the pair is closed: take what is left
                while up.read() == DATA:
                    pass
                up.eof = True
    except Limit as e:
        return 'queue limit (%s)' % e
    except Fatal as e:
        return 'error: %s' % e
    finally:
        sel.close()


def main(argv):
    limit, cmd = parse(argv)
    path = compositor_path()
    if path is None:
        say('no Wayland compositor (WAYLAND_DISPLAY / XDG_RUNTIME_DIR): not started')
        return EX_UNAVAILABLE
    comp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        comp.connect(path)
    except OSError as e:
        say('cannot connect to %s: %s: not started' % (path, e.strerror))
        return EX_UNAVAILABLE

    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    fd = theirs.fileno()
    args = [str(fd) if a == PLACEHOLDER else a for a in cmd]
    env = {k: v for k, v in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'DISPLAY')}
    env['WAYLAND_SOCKET'] = str(fd)
    try:
        child = subprocess.Popen(args, env=env, pass_fds=(fd,))
    except OSError as e:
        say('cannot start %s: %s' % (args[0], e.strerror))
        return EX_UNAVAILABLE
    theirs.close()
    ours.setblocking(False)
    comp.setblocking(False)

    # file descriptors may wait here while the compositor is busy (the command keeps
    # its own limit: raised after the start)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 65536 if hard == resource.RLIM_INFINITY else min(hard, 65536)
    if want > soft:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
            soft = want
        except (ValueError, OSError):
            pass
    max_fds = max(16, min(8192, (soft - 512) // 2))   # both directions + room

    def forward(signum, _frame):
        try:
            child.send_signal(signum)
        except OSError:
            pass
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, forward)

    up = Way('viewer->desktop', ours, comp, limit, max_fds)
    down = Way('desktop->viewer', comp, ours, limit, max_fds)
    end = relay(up, down, child)
    forced = None
    if end.startswith('queue limit'):
        forced = EX_TEMPFAIL
        say(end)
    elif end.startswith('error'):
        forced = EX_SOFTWARE
    if forced is not None and child.poll() is None:
        child.terminate()
    for s in (ours, comp):
        s.close()
    up.drop()
    down.drop()
    try:
        rc = child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
        rc = child.wait()
    if rc < 0:
        rc = 128 - rc
    if forced is not None:
        rc = forced
    say('%s max %d KiB, longest wait %.2f s; %s max %d KiB, longest wait %.2f s; end: %s; exit %d'
        % (up.name, up.peak >> 10, up.longest_wait(), down.name, down.peak >> 10,
           down.longest_wait(), end, rc))
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
