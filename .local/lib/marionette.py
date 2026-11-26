"""marionette: drive a headless scratch Firefox over raw Marionette, no geckodriver or packages.

    sys.path.insert(0, <this dir>); from marionette import scratch_firefox
    with scratch_firefox("my-tool", width=1280, height=800) as m:
        m.cmd("WebDriver:Navigate", url="https://example.org")

The profile is a new one under ~/.cache/<tool>/, removed on exit, and only the Firefox this
started is stopped, by its process group. Never point this at the live Firefox profile: it holds
logins, and the remote flag lets anything on the machine control the browser.
Used by agent-web-shot and binks-demo check.
"""
import contextlib
import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time

# Marionette has no readiness event: the port is tried at this cadence until Firefox listens.
CONNECT_EVERY_S, CONNECT_TRIES = 0.25, 240


class Marionette:
    def __init__(self, port, tool, reply_timeout_s, proc=None):
        self.tool = tool
        for _ in range(CONNECT_TRIES):
            if proc and proc.poll() is not None:
                raise SystemExit(f"{tool}: Firefox exited ({proc.returncode}) before its Marionette port opened")
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=reply_timeout_s)
                break
            except OSError:
                time.sleep(CONNECT_EVERY_S)
        else:
            raise SystemExit(f"{tool}: Firefox never opened its Marionette port")
        self.buf, self.id = b"", 0
        self._read()

    def _recv(self):
        chunk = self.s.recv(65536)
        if not chunk:
            raise SystemExit(f"{self.tool}: Firefox closed its Marionette connection")
        return chunk

    def _read(self):
        while b":" not in self.buf:
            self.buf += self._recv()
        n, rest = self.buf.split(b":", 1)
        while len(rest) < int(n):
            rest += self._recv()
        self.buf = rest[int(n):]
        return json.loads(rest[: int(n)])

    def cmd(self, name, **params):
        self.id += 1
        msg = json.dumps([0, self.id, name, params]).encode()
        self.s.sendall(str(len(msg)).encode() + b":" + msg)
        r = self._read()
        if r[2]:
            raise RuntimeError(f"{name}: {r[2].get('message')}")
        return r[3]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def scratch_firefox(tool, width=1400, height=900, prefs=None, script_timeout_ms=20000):
    """A Marionette session on a new headless Firefox with a scratch profile (m.profile); both go on exit."""
    root = os.path.expanduser(f"~/.cache/{tool}")
    os.makedirs(root, exist_ok=True)
    prof = tempfile.mkdtemp(prefix="profile-", dir=root)
    ff = None
    try:
        port = free_port()
        # The toolbars' min-width holds even a headless window at 500 CSS px or more, so a phone width
        # needs them unclamped; Firefox reads userChrome.css only with the legacy stylesheets pref.
        os.makedirs(f"{prof}/chrome")
        with open(f"{prof}/chrome/userChrome.css", "w") as f:
            f.write("#main-window, #navigator-toolbox, toolbar, #nav-bar, #TabsToolbar, #urlbar-container, #urlbar"
                    " { min-width: 0 !important; }\n")
        with open(f"{prof}/user.js", "w") as f:
            base = {"marionette.port": port, "browser.shell.checkDefaultBrowser": False,
                    "datareporting.policy.dataSubmissionEnabled": False, "browser.aboutwelcome.enabled": False,
                    "toolkit.legacyUserProfileCustomizations.stylesheets": True}
            for k, v in {**base, **(prefs or {})}.items():
                f.write(f'user_pref("{k}", {json.dumps(v)});\n')
        with open(f"{prof}/firefox.log", "w") as log:
            ff = subprocess.Popen(["firefox", "--headless", "--no-remote", "--marionette", "--profile", prof],
                                  stdout=log, stderr=log, start_new_session=True)
        # A guard on one reply, past the longest script a caller lets a page run.
        m = Marionette(port, tool, script_timeout_ms / 1000 + 30, proc=ff)
        m.profile = prof  # scratch space a caller can write into; removed with the profile
        m.cmd("WebDriver:NewSession", capabilities={})
        m.cmd("WebDriver:SetTimeouts", script=script_timeout_ms)
        m.cmd("WebDriver:SetWindowRect", width=width, height=height)
        # A clamped window draws every shot at the wrong width with no error, so check it once here.
        m.cmd("WebDriver:Navigate", url="about:blank")
        drawn = m.cmd("WebDriver:ExecuteScript", script="return window.innerWidth", args=[])["value"]
        if drawn != width:
            raise SystemExit(f"{tool}: asked for a {width} px window, Firefox draws {drawn}")
        yield m
    finally:
        if ff:
            stop(ff)
        shutil.rmtree(prof, ignore_errors=True)


def stop(ff):
    """Stop the Firefox this started and every process in its group; one already gone is fine."""
    try:
        os.killpg(ff.pid, signal.SIGTERM)
        ff.wait(timeout=10)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        try:
            os.killpg(ff.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
