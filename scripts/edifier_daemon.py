#!/usr/bin/env python3
"""
Persistent background daemon that holds one BLE connection open to the
Edifier MR5 and serves state/commands over a local Unix socket.

A daemon (rather than reconnecting per-command) exists because reconnecting
this speaker's BLE peripheral repeatedly in quick succession was observed to
get flaky (BlueZ/the adapter needed a power-cycle to recover). Holding one
long-lived connection avoids that entirely; only the explicit "hard reconnect"
command power-cycles the adapter, and only when asked.
"""
import asyncio
import base64
import fcntl
import json
import logging
import os
import signal
import sys
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from edifier_protocol import (
    CMD,
    EDIFIER_MANUFACTURER_ID,
    READ_UUID,
    WRITE_UUID,
    build_command,
    build_custom_eq_band_set,
    build_custom_eq_name_set,
    build_eq_set,
    parse_acoustic_tuning,
    parse_custom_eq,
    parse_response,
)

# From Edifier's products_release.json (decrypted from the ConneX APK) at the
# time this was written. Purely informational — we do not implement OTA
# flashing (see set_custom_eq_name/docstrings below for why: no confirmed
# firmware binary source or write-side OTA handshake has been verified).
KNOWN_LATEST_FIRMWARE = "1.0.4"

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "edifier-mr5"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "edifier-mr5"
CONFIG_FILE = CONFIG_DIR / "config.json"
EQ_PROFILES_FILE = CONFIG_DIR / "eq_profiles.json"
LOG_FILE = CACHE_DIR / "daemon.log"
SOCKET_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "edifier-mr5.sock"

DEFAULT_INPUT_INDEX = 4  # observed byte0 of input_source_query on this unit
RECONNECT_DELAYS = [2, 4, 8, 15, 30]

CACHE_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("edifier-daemon")


def load_config():
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg))


def load_eq_profiles():
    if EQ_PROFILES_FILE.exists():
        try:
            return json.loads(EQ_PROFILES_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_eq_profiles(profiles):
    log.info("save_eq_profiles: writing %s", profiles)
    EQ_PROFILES_FILE.write_text(json.dumps(profiles))


class EdifierDaemon:
    def __init__(self):
        self.client: BleakClient | None = None
        self.address: str | None = load_config().get("address")
        self.input_index = DEFAULT_INPUT_INDEX
        self.state = {
            "connected": False,
            "address": self.address,
            "mac": None,
            "firmware_version": None,
            "volume_max": None,
            "volume": None,
            "input_index": None,
            "input_value": None,
            "eq_mode": None,
            "low_cutoff_freq": None,
            "low_cutoff_slope": None,
            "acoustic_space": None,
            "desktop_control": None,
            "custom_eq_bands": None,
            "custom_eq_name": "",
            "eq_profiles": sorted(load_eq_profiles().keys()),
            "eq_share_code": "",
            "latest_known_firmware": KNOWN_LATEST_FIRMWARE,
            "last_raw": None,
            "last_error": "",
            "last_update_ts": 0,
        }
        self._custom_eq_byte0 = 0
        self._custom_eq_date_bytes = b"\x00\x00\x00\x00"
        self._eq_index = 2
        self._eq_byte0 = 0
        self._connect_task = None
        self._stop = asyncio.Event()
        self._write_lock = asyncio.Lock()

    # ---------- discovery ----------

    async def discover(self):
        log.info("scanning for Edifier BLE device...")
        devices = await BleakScanner.discover(timeout=10.0, return_adv=True)
        for device, adv in devices.values():
            name = device.name or adv.local_name or ""
            if EDIFIER_MANUFACTURER_ID in (adv.manufacturer_data or {}) or "edifier ble" in name.lower():
                log.info("found %s (%s)", device.address, name)
                self.address = device.address
                save_config({"address": self.address})
                return True
        log.warning("no Edifier BLE device found in scan")
        return False

    # ---------- notifications ----------

    def _on_notify(self, _handle, data: bytearray):
        parsed = parse_response(bytes(data))
        if not parsed or not parsed["checksum_ok"]:
            return
        idx = parsed["command_index"]
        payload = parsed["payload"]
        now = time.time()
        self.state["last_raw"] = {"index": idx, "payload_hex": payload.hex()}
        log.info("notify idx=%s payload=%s", idx, payload.hex())
        if idx == CMD["version_query"] and len(payload) >= 1:
            self.state["firmware_version"] = ".".join(str(b) for b in payload)
        elif idx == CMD["mac_query"] and len(payload) >= 6:
            self.state["mac"] = ":".join(f"{b:02x}" for b in payload)
        elif idx == CMD["device_volume_query"] and len(payload) >= 2:
            self.state["volume_max"] = payload[0]
            self.state["volume"] = payload[1]
        elif idx == CMD["input_source_query"] and len(payload) >= 2:
            self.state["input_index"] = payload[0]
            self.state["input_value"] = payload[1]
            self.input_index = payload[0]
        elif idx == CMD["eq_query"] and len(payload) >= 1:
            self.state["eq_mode"] = payload[0]
            tuning = parse_acoustic_tuning(payload)
            if tuning:
                self._eq_index = tuning["index"]
                self._eq_byte0 = tuning["byte0"]
                self.state["low_cutoff_freq"] = tuning["low_cutoff_freq"]
                self.state["low_cutoff_slope"] = tuning["low_cutoff_slope"]
                self.state["acoustic_space"] = tuning["acoustic_space"]
                self.state["desktop_control"] = tuning["desktop_control"]
        elif idx == CMD["custom_eq_query"]:
            parsed_eq = parse_custom_eq(payload)
            if parsed_eq:
                self.state["custom_eq_bands"] = parsed_eq["bands"]
                self.state["custom_eq_name"] = parsed_eq["name"]
                self._custom_eq_byte0 = parsed_eq["byte0"]
                self._custom_eq_date_bytes = parsed_eq["date_bytes"]
        self.state["last_update_ts"] = now

    # ---------- connection lifecycle ----------

    async def _disconnected_cb(self, _client):
        log.warning("disconnected")
        self.state["connected"] = False
        self.state["last_update_ts"] = time.time()

    async def connect_once(self) -> bool:
        if not self.address:
            if not await self.discover():
                self.state["last_error"] = "device not found (scan)"
                return False
        try:
            client = BleakClient(self.address, disconnected_callback=lambda c: asyncio.create_task(self._disconnected_cb(c)))
            await asyncio.wait_for(client.connect(), timeout=15.0)
            await client.start_notify(READ_UUID, self._on_notify)
            self.client = client
            self.state["connected"] = True
            self.state["address"] = self.address
            self.state["last_error"] = ""
            log.info("connected to %s", self.address)
            await self._query_all()
            return True
        except Exception as e:
            log.warning("connect failed: %s", e)
            self.state["last_error"] = str(e)
            self.client = None
            return False

    async def connection_loop(self):
        delay_idx = 0
        while not self._stop.is_set():
            if not self.state["connected"]:
                ok = await self.connect_once()
                if ok:
                    delay_idx = 0
                    # wait until disconnected
                    while self.state["connected"] and not self._stop.is_set():
                        await asyncio.sleep(1)
                else:
                    delay = RECONNECT_DELAYS[min(delay_idx, len(RECONNECT_DELAYS) - 1)]
                    delay_idx += 1
                    await asyncio.sleep(delay)
            else:
                await asyncio.sleep(1)

    async def hard_reconnect(self):
        log.info("hard reconnect: power-cycling adapter")
        if self.client:
            try:
                await self.client.disconnect()
            except Exception:
                pass
        self.client = None
        self.state["connected"] = False
        proc = await asyncio.create_subprocess_exec("bluetoothctl", "power", "off")
        await proc.wait()
        await asyncio.sleep(2)
        proc = await asyncio.create_subprocess_exec("bluetoothctl", "power", "on")
        await proc.wait()
        await asyncio.sleep(2)
        return await self.connect_once()

    # ---------- device commands ----------

    async def _send(self, name, payload=b""):
        if not self.client or not self.state["connected"]:
            return False
        pkt = build_command(CMD[name], payload)
        async with self._write_lock:
            try:
                await self.client.write_gatt_char(WRITE_UUID, pkt, response=False)
                return True
            except Exception as e:
                log.warning("write failed (%s): %s", name, e)
                self.state["last_error"] = str(e)
                return False

    async def _query_all(self):
        for name in ("version_query", "mac_query", "device_volume_query", "input_source_query", "eq_query", "custom_eq_query"):
            await self._send(name)
            await asyncio.sleep(0.15)

    async def set_volume(self, value: int):
        value = max(0, min(100, int(value)))
        await self._send("device_volume_set", bytes([value]))
        await asyncio.sleep(0.3)
        await self._send("device_volume_query")
        await asyncio.sleep(0.3)

    async def set_eq(self, mode: int):
        # Include the last-known acoustic-tuning tail so switching sound mode
        # doesn't clear/reset it (mode + tuning share one struct on the wire).
        if self.state.get("low_cutoff_freq") is not None:
            payload = build_eq_set(
                mode, self._eq_index, self._eq_byte0,
                self.state["low_cutoff_freq"], self.state["low_cutoff_slope"],
                self.state["acoustic_space"], bool(self.state["desktop_control"]),
            )
        else:
            payload = bytes([int(mode) & 0xFF])
        await self._send("eq_set", payload)
        await asyncio.sleep(0.3)
        await self._send("eq_query")
        await asyncio.sleep(0.3)

    async def set_acoustic_tuning(self, low_cutoff_freq=None, low_cutoff_slope=None,
                                   acoustic_space=None, desktop_control=None):
        mode = self.state.get("eq_mode") or 0
        freq = low_cutoff_freq if low_cutoff_freq is not None else (self.state.get("low_cutoff_freq") or 20)
        slope = low_cutoff_slope if low_cutoff_slope is not None else (self.state.get("low_cutoff_slope") or 0)
        space = acoustic_space if acoustic_space is not None else (self.state.get("acoustic_space") or 0)
        desktop = desktop_control if desktop_control is not None else bool(self.state.get("desktop_control"))
        payload = build_eq_set(mode, self._eq_index, self._eq_byte0, freq, slope, space, desktop)
        await self._send("eq_set", payload)
        await asyncio.sleep(0.3)
        await self._send("eq_query")
        await asyncio.sleep(0.3)

    async def set_custom_eq_band(self, band_index: int, gain: int):
        bands = self.state.get("custom_eq_bands")
        if not bands or not (0 <= band_index < len(bands)):
            return
        freq = bands[band_index]["freq"]
        payload = build_custom_eq_band_set(self._custom_eq_byte0, band_index, freq, gain)
        await self._send("custom_eq_set", payload)
        await asyncio.sleep(0.3)
        await self._send("custom_eq_query")
        await asyncio.sleep(0.3)

    async def set_custom_eq_name(self, name: str):
        name = name[:20]  # keep it sane; device behavior past ~20 UTF-8 bytes is untested
        payload = build_custom_eq_name_set(self._custom_eq_date_bytes, name)
        await self._send("custom_eq_name_set", payload)
        await asyncio.sleep(0.3)
        await self._send("custom_eq_query")
        await asyncio.sleep(0.3)

    async def save_eq_profile(self, name: str):
        name = name[:20].strip()
        if not name:
            return
        bands = self.state.get("custom_eq_bands")
        if not bands:
            return
        profiles = load_eq_profiles()
        profiles[name] = [b["gain"] for b in bands]
        save_eq_profiles(profiles)
        self.state["eq_profiles"] = sorted(profiles.keys())

    async def delete_eq_profile(self, name: str):
        profiles = load_eq_profiles()
        if name in profiles:
            del profiles[name]
            save_eq_profiles(profiles)
            self.state["eq_profiles"] = sorted(profiles.keys())

    def export_eq_profile(self, name: str) -> str:
        profiles = load_eq_profiles()
        gains = profiles.get(name)
        if not gains:
            return ""
        payload = json.dumps({"n": name, "g": gains}).encode("utf-8")
        return "MR5EQ1:" + base64.urlsafe_b64encode(payload).decode("ascii")

    async def import_eq_profile(self, code: str):
        code = code.strip()
        if not code.startswith("MR5EQ1:"):
            self.state["last_error"] = "Not a recognized EQ share code"
            return
        try:
            payload = json.loads(base64.urlsafe_b64decode(code[len("MR5EQ1:"):]).decode("utf-8"))
            name = str(payload["n"])[:20].strip()
            gains = [max(0, min(20, int(g))) for g in payload["g"]][:9]
        except Exception as e:
            self.state["last_error"] = f"Invalid EQ share code: {e}"
            return
        if not name or len(gains) != 9:
            self.state["last_error"] = "Invalid EQ share code"
            return
        profiles = load_eq_profiles()
        profiles[name] = gains
        save_eq_profiles(profiles)
        self.state["eq_profiles"] = sorted(profiles.keys())
        self.state["last_error"] = ""

    async def apply_eq_profile(self, name: str):
        profiles = load_eq_profiles()
        gains = profiles.get(name)
        bands = self.state.get("custom_eq_bands")
        if not gains or not bands:
            return
        for band_index, gain in enumerate(gains):
            if band_index >= len(bands):
                break
            freq = bands[band_index]["freq"]
            payload = build_custom_eq_band_set(self._custom_eq_byte0, band_index, freq, int(gain))
            await self._send("custom_eq_set", payload)
            await asyncio.sleep(0.25)
        await self.set_custom_eq_name(name)

    async def set_input(self, value: int):
        idx = self.input_index if self.input_index is not None else DEFAULT_INPUT_INDEX
        await self._send("input_source_set", bytes([idx, int(value) & 0xFF]))
        await asyncio.sleep(0.3)
        await self._send("input_source_query")
        await asyncio.sleep(0.3)

    # ---------- socket server ----------

    async def handle_client(self, reader, writer):
        try:
            line = await reader.readline()
            if not line:
                return
            req = json.loads(line.decode())
            cmd = req.get("cmd")
            if cmd == "status":
                pass
            elif cmd == "set_volume":
                await self.set_volume(req.get("value", 0))
            elif cmd == "set_eq":
                await self.set_eq(req.get("mode", 0))
            elif cmd == "set_acoustic_tuning":
                await self.set_acoustic_tuning(
                    low_cutoff_freq=req.get("low_cutoff_freq"),
                    low_cutoff_slope=req.get("low_cutoff_slope"),
                    acoustic_space=req.get("acoustic_space"),
                    desktop_control=req.get("desktop_control"),
                )
            elif cmd == "set_input":
                await self.set_input(req.get("value", 0))
            elif cmd == "set_custom_eq_band":
                await self.set_custom_eq_band(req.get("band", 0), req.get("gain", 0))
            elif cmd == "set_custom_eq_name":
                await self.set_custom_eq_name(req.get("name", ""))
            elif cmd == "save_eq_profile":
                await self.save_eq_profile(req.get("name", ""))
            elif cmd == "delete_eq_profile":
                await self.delete_eq_profile(req.get("name", ""))
            elif cmd == "apply_eq_profile":
                await self.apply_eq_profile(req.get("name", ""))
            elif cmd == "export_eq_profile":
                self.state["eq_share_code"] = self.export_eq_profile(req.get("name", ""))
            elif cmd == "import_eq_profile":
                await self.import_eq_profile(req.get("code", ""))
            elif cmd == "reconnect":
                if self.client:
                    try:
                        await self.client.disconnect()
                    except Exception:
                        pass
                self.client = None
                self.state["connected"] = False
                await self.connect_once()
            elif cmd == "hard_reconnect":
                await self.hard_reconnect()
            elif cmd == "raw":
                idx = int(req.get("index"))
                payload = bytes.fromhex(req.get("payload_hex", ""))
                name = None
                for k, v in CMD.items():
                    if v == idx:
                        name = k
                        break
                pkt = build_command(idx, payload)
                async with self._write_lock:
                    if self.client and self.state["connected"]:
                        await self.client.write_gatt_char(WRITE_UUID, pkt, response=False)
                await asyncio.sleep(1.0)
            elif cmd == "rescan":
                self.address = None
                await self.discover()
                await self.connect_once()
            elif cmd == "shutdown":
                writer.write((json.dumps({"ok": True}) + "\n").encode())
                await writer.drain()
                writer.close()
                self._stop.set()
                return
            resp = dict(self.state)
            resp["ok"] = True
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
        except Exception as e:
            log.exception("client error")
            try:
                writer.write((json.dumps({"ok": False, "error": str(e)}) + "\n").encode())
                await writer.drain()
            except Exception:
                pass
        finally:
            writer.close()

    async def run(self):
        if SOCKET_PATH.exists():
            SOCKET_PATH.unlink()
        server = await asyncio.start_unix_server(self.handle_client, path=str(SOCKET_PATH))
        log.info("daemon listening on %s", SOCKET_PATH)

        loop = asyncio.get_event_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, self._stop.set)

        conn_task = asyncio.create_task(self.connection_loop())
        async with server:
            stop_task = asyncio.create_task(self._stop.wait())
            await stop_task
        conn_task.cancel()
        if self.client:
            try:
                await self.client.disconnect()
            except Exception:
                pass
        if SOCKET_PATH.exists():
            SOCKET_PATH.unlink()
        log.info("daemon stopped")


LOCK_FILE = CACHE_DIR / "daemon.lock"


def acquire_singleton_lock():
    """Refuse to start a second daemon. Holds the fd open for process lifetime;
    the OS releases the lock automatically on exit (clean or crash)."""
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log.info("another daemon instance already holds the lock, exiting")
        return None
    lock_fd.write(str(os.getpid()))
    lock_fd.flush()
    return lock_fd


def main():
    lock_fd = acquire_singleton_lock()
    if lock_fd is None:
        return
    daemon = EdifierDaemon()
    try:
        asyncio.run(daemon.run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
