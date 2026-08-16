#!/usr/bin/env python3
"""
Thin CLI client for the Edifier MR5 daemon. Ensures the daemon is running,
sends one command over its Unix socket, prints the JSON response to stdout.
Used by the Omarchy shell plugin's Service.qml (called via Quickshell Process).
"""
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SOCKET_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "edifier-mr5.sock"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "edifier-mr5"


def daemon_alive() -> bool:
    if not SOCKET_PATH.exists():
        return False
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(str(SOCKET_PATH))
        s.close()
        return True
    except OSError:
        return False


def spawn_daemon():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = CACHE_DIR / "daemon.spawn.log"
    with open(log_path, "a") as log_f:
        subprocess.Popen(
            [sys.executable, str(SCRIPT_DIR / "edifier_daemon.py")],
            stdout=log_f,
            stderr=log_f,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    for _ in range(40):  # up to ~10s
        if daemon_alive():
            return True
        time.sleep(0.25)
    return daemon_alive()


def send(cmd: dict, timeout=20.0) -> dict:
    if not daemon_alive():
        if not spawn_daemon():
            return {"ok": False, "error": "daemon did not start", "connected": False}
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(str(SOCKET_PATH))
        s.sendall((json.dumps(cmd) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
        s.close()
        raw = b"".join(chunks).decode().strip()
        return json.loads(raw) if raw else {"ok": False, "error": "empty response"}
    except Exception as e:
        return {"ok": False, "error": str(e), "connected": False}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "usage: edifier_ctl.py <status|set-volume N|set-eq N|reconnect|hard-reconnect|rescan>"}))
        return

    action = sys.argv[1]
    if action == "status":
        result = send({"cmd": "status"})
    elif action == "set-volume" and len(sys.argv) == 3:
        result = send({"cmd": "set_volume", "value": int(sys.argv[2])})
    elif action == "set-eq" and len(sys.argv) == 3:
        result = send({"cmd": "set_eq", "mode": int(sys.argv[2])})
    elif action == "set-acoustic-tuning":
        payload = {"cmd": "set_acoustic_tuning"}
        for arg in sys.argv[2:]:
            key, _, value = arg.partition("=")
            if key == "desktop_control":
                payload[key] = value in ("1", "true", "True")
            else:
                payload[key] = int(value)
        result = send(payload)
    elif action == "set-custom-eq-band" and len(sys.argv) == 4:
        result = send({"cmd": "set_custom_eq_band", "band": int(sys.argv[2]), "gain": int(sys.argv[3])})
    elif action == "set-custom-eq-name" and len(sys.argv) == 3:
        result = send({"cmd": "set_custom_eq_name", "name": sys.argv[2]})
    elif action == "save-eq-profile" and len(sys.argv) == 3:
        result = send({"cmd": "save_eq_profile", "name": sys.argv[2]})
    elif action == "delete-eq-profile" and len(sys.argv) == 3:
        result = send({"cmd": "delete_eq_profile", "name": sys.argv[2]})
    elif action == "apply-eq-profile" and len(sys.argv) == 3:
        result = send({"cmd": "apply_eq_profile", "name": sys.argv[2]}, timeout=15.0)
    elif action == "export-eq-profile" and len(sys.argv) == 3:
        result = send({"cmd": "export_eq_profile", "name": sys.argv[2]})
    elif action == "import-eq-profile" and len(sys.argv) == 3:
        result = send({"cmd": "import_eq_profile", "code": sys.argv[2]})
    elif action == "reconnect":
        result = send({"cmd": "reconnect"}, timeout=20.0)
    elif action == "hard-reconnect":
        result = send({"cmd": "hard_reconnect"}, timeout=25.0)
    elif action == "rescan":
        result = send({"cmd": "rescan"}, timeout=15.0)
    else:
        result = {"ok": False, "error": f"unknown action: {action}"}

    print(json.dumps(result))


if __name__ == "__main__":
    main()
