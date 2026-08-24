#!/usr/bin/env python3
"""Self-check for the value guards on the write path. Run: python3 scripts/test_edifier.py"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from edifier_daemon import _clamp
from edifier_protocol import build_eq_set


def test_clamp_catches_the_unread_sentinel():
    # -1 is "the device hasn't reported this field yet". build_eq_set masks
    # with & 0xFF, so an unclamped -1 reaches the speaker's DSP as 255.
    assert build_eq_set(0, 0, 0, -1, -1, -1, False)[3] == 255
    assert _clamp(-1, 20, 100, 20) == 20
    assert _clamp(-1, 0, 3, 0) == 0
    assert _clamp(-1, 0, 4, 0) == 0


def test_clamp_keeps_valid_values_and_bounds_the_rest():
    assert _clamp(30, 20, 100, 20) == 30
    assert _clamp(500, 20, 100, 20) == 100
    assert _clamp(None, 20, 100, 20) == 20
    assert _clamp("garbage", 20, 100, 20) == 20


if __name__ == "__main__":
    test_clamp_catches_the_unread_sentinel()
    test_clamp_keeps_valid_values_and_bounds_the_rest()
    print("ok")
