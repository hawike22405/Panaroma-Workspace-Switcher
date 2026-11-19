#!/usr/bin/env python3
"""Private screenshot helper and isolated Panorama session controller.

No shell evaluation, downloads, config edits, or global animation changes.
Requires Python 3.10+, grim, Hyprland, Quickshell and a private XDG_RUNTIME_DIR.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

TIMEOUT = 2.0
MAX_BYTES = 128 * 1024 * 1024


class PanoramaError(Exception):
    pass


def run(args: list[str], timeout: float = TIMEOUT) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                          check=False, stdin=subprocess.DEVNULL)


def private_dir(path: Path, create: bool = False) -> Path:
    if not path.is_absolute():
        raise PanoramaError("Private directories must use absolute paths")
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid():
        raise PanoramaError(f"Not an owned, real directory: {path}")
    if stat.S_IMODE(s.st_mode) & 0o077:
        raise PanoramaError(f"Directory must be private (mode 700): {path}")
    return path.resolve(strict=True)


def runtime_root() -> Path:
    value = os.environ.get("XDG_RUNTIME_DIR", "")
    if not value:
        raise PanoramaError("XDG_RUNTIME_DIR is missing; refusing shared /tmp storage")
    parent = private_dir(Path(value))
    return private_dir(parent / "ryoku-panorama-private", create=True)


def session_key() -> str:
    identity = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not identity:
        raise PanoramaError("Run this inside a Hyprland session")
    identity += ":" + os.environ.get("WAYLAND_DISPLAY", "")
    return hashlib.sha256(identity.encode()).hexdigest()[:16]


def monitors() -> list[dict]:
    p = run(["hyprctl", "monitors", "-j"])
    if p.returncode:
        raise PanoramaError("Hyprland monitor query failed: " + p.stderr.strip())
    data = json.loads(p.stdout)
    if not isinstance(data, list) or not data:
        raise PanoramaError("No usable Hyprland monitors")
    return data


def detect_api() -> str:
    # A read-only feature probe, not a version-number guess or a workspace action.
    p = run(["hyprctl", "eval",
             "assert(hl and hl.dsp and hl.dsp.focus, 'panorama: missing Lua focus API')"])
    if p.returncode == 0 and p.stdout.strip().lower() == "ok":
        return "lua"
    reply = (p.stdout + p.stderr).lower()
    if any(x in reply for x in ("unknown request", "unknown command", "unrecognized command")):
        monitors()  # Don't mistake a disconnected compositor for an old API.
        return "legacy"
    raise PanoramaError("Cannot identify Hyprland's workspace API: " + reply.strip()[:300])


def destination(value: str) -> str:
    # Restrict legacy dispatchers to one argument, and safely quote names for Lua.
    if (not value or len(value.encode()) > 256 or
            any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise PanoramaError("Invalid workspace destination")
    if re.fullmatch(r"[1-9][0-9]*|(?:e|m|r)?[+-][0-9]+|previous(?:_per_monitor)?|empty", value):
        return value
    if value.startswith("name:") and value[5:].strip():
        return value
    raise PanoramaError("Use a positive ID, name:NAME, previous, empty, or relative selector such as e+1")


def lua_string(value: str) -> str:
    # Decimal byte escapes avoid Lua quoting/injection and support UTF-8 names.
    return '"' + ''.join('\\%03d' % b for b in value.encode('utf-8')) + '"'


def dispatch(dest: str, mode: str | None = None) -> None:
    dest = destination(dest)
    mode = mode or detect_api()
    command = ("hl.dsp.focus({ workspace = " + lua_string(dest) + " })"
               if mode == "lua" else "workspace")
    args = ["hyprctl", "dispatch", command]
    if mode == "legacy":
        args.append(dest)
    p = run(args)
    if p.returncode or p.stdout.strip().lower() != "ok":
        raise PanoramaError("Workspace switch failed: " + (p.stdout + p.stderr).strip()[:300])
    # Do not retry a mutating command: an ambiguous timeout may already have switched.


def cache_dir() -> Path:
    root = runtime_root()
    value = os.environ.get("RYOKU_PANORAMA_CACHE", "")
    path = Path(value)
    if not value or path.parent != root or not path.name.startswith("shots-" + session_key() + "-"):
        raise PanoramaError("Capture must run inside a private Panorama session")
    return private_dir(path)


def monitor_state(name: str, expected: int) -> dict:
    mon = next((m for m in monitors() if m.get("name") == name), None)
    if not mon or mon.get("activeWorkspace", {}).get("id") != expected:
        raise PanoramaError("Workspace changed; discarded capture")
    if mon.get("activeSpecialWorkspace", {}).get("id", 0) != 0:
        raise PanoramaError("Special workspace is visible; skipped capture")
    if mon.get("dpmsStatus") is False:
        raise PanoramaError("Monitor is asleep; skipped capture")
    return mon


def geometry(mon: dict, insets: list[int], max_width: int) -> tuple[str, float, tuple]:
    if len(insets) != 4 or any(v < 0 or v > 16384 for v in insets):
        raise PanoramaError("Invalid capture insets")
    scale = float(mon.get("scale", 1))
    w, h = float(mon["width"]), float(mon["height"])
    if not all(math.isfinite(v) and v > 0 for v in (scale, w, h)):
        raise PanoramaError("Invalid monitor dimensions")
    transform = int(mon.get("transform", 0))
    if transform % 2:
        w, h = h, w
    l, t, r, b = insets
    gw, gh = round(w / scale - l - r), round(h / scale - t - b)
    if gw <= 0 or gh <= 0:
        raise PanoramaError("Insets leave no usable display area")
    x, y = int(mon["x"]) + l, int(mon["y"]) + t
    out_scale = min(scale, max(320, min(max_width, 1920)) / gw, 1080 / gh)
    return f"{x},{y} {gw}x{gh}", out_scale, (x, y, gw, gh, scale, transform, tuple(mon.get("reserved", [])))


def prune(cache: Path, keep: Path, per_ws_limit: int = 2) -> None:
    # Retain the most recent snapshots per workspace so idle refreshes on one workspace
    # never purge cached previews of other workspaces.
    files = [p for p in cache.glob("s-*.ppm") if p.is_file() and not p.is_symlink()]
    files.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
    counts = {}
    total = 0
    for p in files:
        total += p.stat().st_size
        parts = p.name.split("-")
        ws_key = (parts[1], parts[2]) if len(parts) >= 3 else p.name
        counts[ws_key] = counts.get(ws_key, 0) + 1
        if p != keep and (total > MAX_BYTES or counts[ws_key] > per_ws_limit):
            p.unlink(missing_ok=True)


def capture(name: str, expected: int, max_width: int, insets: list[int], cards: int) -> dict:
    cache = cache_dir()
    # Serialize helpers across monitors; cap disk use and avoid overlapping grim jobs.
    lockfd = os.open(cache / "capture.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lockfd, "w") as lock:
        deadline = time.monotonic() + .75
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise PanoramaError("Capture helper is busy; skipped capture")
                time.sleep(.03)
        before = monitor_state(name, expected)
        region, scale, signature = geometry(before, insets, max_width)
        fd, tmpname = tempfile.mkstemp(prefix="pending-", dir=cache)
        tmp = Path(tmpname)
        try:
            # Write through an already-open private descriptor, not a predictable pathname.
            with os.fdopen(fd, "wb") as image:
                p = subprocess.run(["grim", "-g", region, "-s", f"{scale:.6f}", "-t", "ppm", "-"],
                                   stdout=image, stderr=subprocess.PIPE, timeout=3,
                                   stdin=subprocess.DEVNULL, check=False)
            if p.returncode:
                raise PanoramaError("grim could not capture this display")
            after = monitor_state(name, expected)
            if geometry(after, insets, max_width)[2] != signature:
                raise PanoramaError("Monitor geometry changed; discarded capture")
            if not 12 <= tmp.stat().st_size <= 8 * 1024 * 1024:
                raise PanoramaError("Unexpected screenshot size")
            with tmp.open("rb") as image:
                if image.read(2) != b"P6":
                    raise PanoramaError("Unexpected screenshot format")
            prefix = "s-" + hashlib.sha256(name.encode()).hexdigest()[:16] + "-"
            out = cache / (prefix + str(expected) + "-" + tmp.name[8:] + ".ppm")
            os.replace(tmp, out)
            prune(cache, out)
            return {"url": out.as_uri(), "workspace": expected}
        finally:
            tmp.unlink(missing_ok=True)


def config_dir() -> Path:
    # Resolve the installed helper, not Ryoku's managed Quickshell config tree.
    return Path(__file__).resolve().parent


def paths() -> tuple[Path, Path, Path]:
    root = runtime_root()
    key = session_key()
    return root / (key + ".lock"), root / (key + ".json"), root / (key + ".log")


def start_time(pid: int) -> str:
    # Field 22; process names may themselves contain spaces or parentheses.
    return Path(f"/proc/{pid}/stat").read_text().rsplit(')', 1)[1].split()[19]


def running_state() -> dict | None:
    _, statefile, _ = paths()
    try:
        s = statefile.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
            raise PanoramaError("Unsafe session state file")
        data = json.loads(statefile.read_text())
        pid = int(data["pid"])
        args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b'\0')
        helper = Path(data.get("helper", ""))
        current = Path(__file__).resolve()
        sibling_release = (helper.name == "capture.py" and helper.parent.parent.name == "releases"
                           and current.parent.parent.name == "releases"
                           and helper.parent.parent == current.parent.parent)
        if (data["start"] != start_time(pid) or b"serve" not in args or
                str(helper).encode() not in args or not (helper == current or sibling_release)):
            return None
        return data
    except (FileNotFoundError, ProcessLookupError, KeyError, ValueError):
        return None


def atomic_json(path: Path, data: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="state-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def serve() -> int:
    lockfile, statefile, logfile = paths()
    fd = os.open(lockfile, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        mode = detect_api()
        root = runtime_root()
        # Reclaim this session's leftovers after a previous crash/SIGKILL.
        for old in root.glob("shots-" + session_key() + "-*"):
            if old.is_dir() and not old.is_symlink() and old.stat().st_uid == os.getuid():
                shutil.rmtree(old)
        cache = Path(tempfile.mkdtemp(prefix="shots-" + session_key() + "-", dir=root))
        env = dict(os.environ, RYOKU_PANORAMA_CACHE=str(cache), RYOKU_PANORAMA_DIR=str(config_dir()),
                   RYOKU_PANORAMA_API=mode)
        child = None
        stopping = False
        def stop_signal(signum, frame):
            nonlocal stopping
            stopping = True
        signal.signal(signal.SIGTERM, stop_signal)
        signal.signal(signal.SIGINT, stop_signal)
        try:
            atomic_json(statefile, {"pid": os.getpid(), "start": start_time(os.getpid()), "helper": str(Path(__file__).resolve()), "ready": False})
            logfd = os.open(logfile, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(logfd, "wb", buffering=0) as log:
                child = subprocess.Popen(["qs", "-p", str(config_dir() / "shell.qml")],
                                         env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
                ready = False
                deadline = time.monotonic() + 6
                while child.poll() is None and not stopping:
                    if not ready:
                        try:
                            p = run(["qs", "-p", str(config_dir() / "shell.qml"), "ipc", "call", "panorama", "ping"], .5)
                        except subprocess.TimeoutExpired:
                            p = subprocess.CompletedProcess([], 1, "", "")
                        if p.returncode == 0 and "ready" in p.stdout:
                            ready = True
                            atomic_json(statefile, {"pid": os.getpid(), "start": start_time(os.getpid()), "helper": str(Path(__file__).resolve()), "ready": True})
                        elif time.monotonic() > deadline:
                            raise PanoramaError("Panorama did not become ready; see ryoku-panorama log")
                    if logfile.stat().st_size > 2 * 1024 * 1024:
                        log.truncate(0)
                        log.seek(0)
                    time.sleep(.15)
                return 0 if stopping else (child.returncode or 0)
        except Exception as exc:
            logfd = os.open(logfile, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(logfd, "w") as log:
                log.write("Panorama supervisor: " + str(exc) + "\n")
            raise
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
            statefile.unlink(missing_ok=True)
            shutil.rmtree(cache)


def start() -> int:
    data = running_state()
    if data and data.get("ready"):
        print("Panorama is already running" + ("; restart to use the newly installed release"
              if data.get("helper") != str(Path(__file__).resolve()) else ""))
        return 0
    if not data:
        for command in ("qs", "hyprctl", "grim"):
            if not shutil.which(command):
                raise PanoramaError("Missing dependency: " + command)
        if not (config_dir() / "panorama.frag.qsb").is_file():
            raise PanoramaError("Compiled shader is missing; rerun the installer")
        p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "serve"],
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    else:
        p = None
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        data = running_state()
        if data and data.get("ready"):
            print("Panorama started (independent Quickshell process)")
            return 0
        if p is not None and p.poll() is not None:
            break
        time.sleep(.1)
    raise PanoramaError("Panorama could not start. Run ryoku-panorama log; native workspace switching is unchanged")


def stop() -> int:
    data = running_state()
    if not data:
        print("Panorama is stopped")
        return 0
    os.kill(int(data["pid"]), signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not running_state():
            print("Panorama stopped; private snapshots removed")
            return 0
        time.sleep(.1)
    raise PanoramaError("Panorama is still shutting down; no other desktop process was signalled")


GESTURE_BEGIN = "-- BEGIN RYOKU PANORAMA LIVE GESTURES v2"
GESTURE_END = "-- END RYOKU PANORAMA LIVE GESTURES v2"


def config_errors() -> list:
    p = run(["hyprctl", "configerrors", "-j"])
    if p.returncode:
        raise PanoramaError("Could not validate Hyprland configuration")
    errors = json.loads(p.stdout)
    if not isinstance(errors, list):
        raise PanoramaError("Unexpected configerrors response; refusing configuration edits")
    return [e for e in errors if (isinstance(e, str) and e.strip()) or (isinstance(e, dict) and e)]


def write_private_atomic(path: Path, body: bytes, mode: int) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".panorama-config-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(body)
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def configure_gestures(enable: bool) -> None:
    if detect_api() != "lua":
        raise PanoramaError("Live gestures require current Lua Hyprland")
    # This is the user extension shown in the supplied Ryoku log. Never patch
    # settings.lua, animation presets or other packaged modules.
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home()/".config")
    requested = base/"hypr"/"user.lua"
    if not requested.exists():
        raise PanoramaError("No existing Ryoku user configuration at " + str(requested))
    path = requested.resolve(strict=True)
    if not path.is_relative_to(Path.home().resolve()) or path.stat().st_uid != os.getuid():
        raise PanoramaError("Refusing to modify a user.lua target outside your owned home directory")
    previous = path.read_bytes()
    text = previous.decode("utf-8")
    if text.count(GESTURE_BEGIN) != text.count(GESTURE_END) or text.count(GESTURE_BEGIN) > 1:
        raise PanoramaError("Unexpected integration markers; your configuration was not changed")
    expression = re.compile(re.escape(GESTURE_BEGIN) + r".*?" + re.escape(GESTURE_END) + r"\n?", re.S)
    clean = expression.sub("", text)
    module = config_dir()/"panorama-gestures.lua"
    if config_dir().parent.name == "releases":
        module = config_dir().parent.parent/"current"/"panorama-gestures.lua"
    if enable and not module.is_file():
        raise PanoramaError("Live gesture module missing; rerun the revised installer")
    baseline = config_errors()
    if enable and baseline:
        raise PanoramaError("Resolve existing Hyprland configuration errors before enabling gestures")
    updated = clean
    if enable:
        updated = clean.rstrip() + "\n\n" + GESTURE_BEGIN + "\n" + "dofile(" + lua_string(str(module)) + ")\n" + GESTURE_END + "\n"
    backup = path.with_name(path.name + ".panorama-backup-" + str(time.time_ns()))
    write_private_atomic(backup, previous, 0o600)
    mode = stat.S_IMODE(path.stat().st_mode)
    try:
        write_private_atomic(path, updated.encode(), mode)
        reply = run(["hyprctl", "reload"])
        if reply.returncode:
            raise PanoramaError("Hyprland reload failed")
        errors = config_errors()
        if errors and errors != baseline:
            raise PanoramaError("Hyprland rejected the integration: " + str(errors)[:1000])
    except Exception:
        write_private_atomic(path, previous, mode)
        try:
            run(["hyprctl", "reload"])
        except (OSError, subprocess.SubprocessError):
            pass
        raise
    print("Live gestures " + ("enabled" if enable else "disabled") + "; backup: " + str(backup))
    if enable:
        print("Workspace slides are disabled by the optional module. Disable it with ryoku-panorama disable-gestures to restore your configured native gestures/animations.")


def main() -> int:
    os.umask(0o077)
    if os.geteuid() == 0:
        raise PanoramaError("Run as your desktop user, without sudo")
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("start", "stop", "restart", "serve", "log", "doctor", "status", "enable-gestures", "disable-gestures"):
        sub.add_parser(name)
    go = sub.add_parser("go")
    go.add_argument("destination")
    cap = sub.add_parser("capture")
    cap.add_argument("monitor")
    cap.add_argument("workspace", type=int)
    cap.add_argument("max_width", type=int)
    cap.add_argument("insets", nargs=4, type=int)
    cap.add_argument("cards", type=int)
    args = parser.parse_args()
    if args.action in ("enable-gestures", "disable-gestures"):
        configure_gestures(args.action == "enable-gestures")
    elif args.action == "capture":
        print(json.dumps(capture(args.monitor, args.workspace, args.max_width, args.insets, args.cards)))
    elif args.action == "go":
        dest = destination(args.destination)
        # IPC only prepares a visual. The actual workspace switch happens exactly once here.
        try:
            state = running_state()
        except (PanoramaError, OSError, ValueError):
            state = None  # Workspace switching does not depend on snapshot storage.
        if state:
            try:
                run(["qs", "-p", str(config_dir() / "shell.qml"), "ipc", "call", "panorama", "prepare"], .35)
                time.sleep(.04)
            except (subprocess.TimeoutExpired, OSError):
                pass
        dispatch(dest)
    elif args.action == "serve":
        return serve()
    elif args.action == "start":
        return start()
    elif args.action == "stop":
        return stop()
    elif args.action == "restart":
        stop()
        return start()
    elif args.action == "status":
        print("running" if running_state() else "stopped")
    elif args.action == "log":
        _, _, log = paths()
        print(log.read_text(errors="replace")[-32768:] if log.exists() else "No Panorama log yet")
    elif args.action == "doctor":
        print("Config:", config_dir())
        print("Runtime:", runtime_root())
        print("Workspace API:", detect_api())
        for cmd in (["qs", "--version"], ["hyprctl", "version"], ["grim", "-h"]):
            p = run(cmd)
            print((p.stdout + p.stderr).strip()[:2000])
        print("Shader installed:", (config_dir() / "panorama.frag.qsb").is_file())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (PanoramaError, OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print("ryoku-panorama: " + str(exc), file=sys.stderr)
        sys.exit(1)
