"""
BLE protocol for the Edifier MR5 studio monitor, reverse-engineered from the
Edifier ConneX Android app (com.edifier.edifierconnex), specifically
com.edifier.lib_connect (BLEManager, CommandManager, CommandBean) and the
decrypted assets/products_release.json product table.

Packet format: [0xAA][appCode][commandIndex][lenHi][lenLo][payload...][checksum]
checksum = (sum of all preceding bytes) & 0xFF
"EDIFIER BLE" advertises manufacturer id 0x07E0 (2016), with the classic-BT
MAC + protocol version + encryption flag as manufacturer data.
"""

SEARCH_UUID = "00003a01-0000-1000-8000-00805f9b34fb"
SERVICE_UUID = "48093a01-1a48-11e9-ab14-d663bd873d93"
READ_UUID = "48090001-1a48-11e9-ab14-d663bd873d93"
WRITE_UUID = "48090002-1a48-11e9-ab14-d663bd873d93"

EDIFIER_MANUFACTURER_ID = 2016  # 0x07E0

HEADER_BOX = 0xAA
APP_CODE = 0x06

CMD = {
    "version_query": 198,
    "mac_query": 200,
    "battery_query": 208,
    "device_state_query": 242,
    "device_volume_query": 102,
    "device_volume_set": 103,
    "input_source_query": 97,
    "input_source_set": 98,
    "eq_query": 213,
    "eq_set": 196,
    "name_query": 201,
    "custom_eq_query": 67,
    "custom_eq_set": 68,
    "custom_eq_name_set": 71,
}

# 9-band graphic EQ, octave-spaced (this unit's eqIndex=12 layout, confirmed
# live: custom_eq_query returns [eqIndex][bandCount][9 x (2-byte freq @ +2/+3,
# gain @ +4, 4 bytes/band)][4-byte timestamp][UTF-8 preset name]).
CUSTOM_EQ_BAND_FREQS = [62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

# "Acoustic Tuning" (eq_query/eq_set, 213/196) — this is the app's low-cutoff
# filter + room-compensation screen, distinct from the sound-mode byte and
# distinct from the 9-band custom EQ curve above. Verified live: a real
# ConneX-set value of 30Hz / -24dB/oct / -2dB / Desktop ON decoded as exactly
# `02 02 00 1e 03 02 01`.
ACOUSTIC_TUNING_SLOPES_DB = [-6, -12, -18, -24]  # lowCutoffSlope is an index into this
ACOUSTIC_SPACE_MIN_DB = -4
ACOUSTIC_SPACE_MAX_DB = 0
LOW_CUTOFF_FREQ_MIN = 20
LOW_CUTOFF_FREQ_MAX = 100
LOW_CUTOFF_FREQ_STEP = 5


def parse_acoustic_tuning(payload: bytes):
    """Decode an eq_query (213) response's EqCalibrationBean tail (bytes 1-6):
    [mode][index][byte0][lowCutoffFreq][lowCutoffSlope][acousticSpace][desktopControl].
    mode (byte 0) is handled separately by the caller (it's the Monitor/Music/
    Custom sound mode, always present even with no calibration tail)."""
    if len(payload) < 7:
        return None
    return {
        "mode": payload[0],
        "index": payload[1],
        "byte0": payload[2],
        "low_cutoff_freq": payload[3],
        "low_cutoff_slope": payload[4],
        "acoustic_space": payload[5],
        "desktop_control": bool(payload[6] == 1),
    }


def build_eq_set(mode: int, index: int, byte0: int, low_cutoff_freq: int, low_cutoff_slope: int,
                  acoustic_space: int, desktop_control: bool) -> bytes:
    return bytes([
        mode & 0xFF, index & 0xFF, byte0 & 0xFF, low_cutoff_freq & 0xFF,
        low_cutoff_slope & 0xFF, acoustic_space & 0xFF, 1 if desktop_control else 0,
    ])


def build_command(command_index: int, payload: bytes = b"") -> bytes:
    length = len(payload)
    body = bytes([HEADER_BOX, APP_CODE, command_index, (length >> 8) & 0xFF, length & 0xFF]) + payload
    checksum = sum(body) & 0xFF
    return body + bytes([checksum])


def parse_custom_eq(payload: bytes):
    """Decode a custom_eq_query (67) response. Verified live against this
    unit: [eqIndex][bandCount][9 bands x 4 bytes: _,_,freqHi,freqLo,(gain is
    the *next* band's byte0, i.e. offset+4)][4-byte timestamp][UTF-8 name].
    Only the eqIndex=12 / 9-band layout (this product's) is handled."""
    if len(payload) < 2 or payload[0] != 12:
        return None
    band_count = payload[1]
    total_len = 37
    bytes_per_band = 4
    arr = payload[2:2 + total_len]
    if len(arr) < total_len:
        return None
    bands = []
    for k in range(band_count):
        base = k * bytes_per_band
        freq = (arr[base + 2] << 8) | arr[base + 3]
        gain = arr[min(base + 4, len(arr) - 1)]
        bands.append({"freq": freq, "gain": gain})
    tail = payload[2 + total_len:]
    date_bytes = tail[:4] if len(tail) >= 4 else b"\x00\x00\x00\x00"
    name = tail[4:].decode("utf-8", errors="ignore").strip("\x00 ") if len(tail) > 4 else ""
    return {
        "eq_index": payload[0], "band_count": band_count, "bands": bands, "name": name,
        "byte0": arr[0], "date_bytes": date_bytes,
    }


def build_custom_eq_band_set(byte0: int, band_index: int, freq: int, gain: int) -> bytes:
    return bytes([byte0 & 0xFF, band_index & 0xFF, (freq >> 8) & 0xFF, freq & 0xFF, gain & 0xFF])


def build_custom_eq_name_set(date_bytes: bytes, name: str) -> bytes:
    return date_bytes + name.encode("utf-8")


def parse_response(data: bytes):
    if len(data) < 6:
        return None
    command_index = data[2]
    payload = data[5:-1]
    checksum = data[-1]
    ok = (sum(data[:-1]) & 0xFF) == checksum
    return {
        "command_index": command_index,
        "payload": bytes(payload),
        "checksum_ok": ok,
    }
