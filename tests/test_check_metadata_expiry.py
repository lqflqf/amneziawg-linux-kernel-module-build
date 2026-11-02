"""Tests of the Valid-Until parser in scripts/check-metadata-expiry.py."""

from __future__ import annotations

import datetime

from conftest import load_script

expiry = load_script("check-metadata-expiry.py")

INRELEASE = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Origin: AmneziaWG
Date: Mon, 02 Nov 2026 04:41:00 UTC
Valid-Until: Wed, 02 Dec 2026 04:41:00 UTC
Suite: trixie
-----BEGIN PGP SIGNATURE-----
"""


def test_valid_until() -> None:
    until = expiry.valid_until(INRELEASE)
    assert until == datetime.datetime(2026, 12, 2, 4, 41, tzinfo=datetime.timezone.utc)
    assert expiry.valid_until("Origin: x\n") is None


def test_days_left_rounds_down() -> None:
    until = datetime.datetime(2026, 12, 2, 4, 41, tzinfo=datetime.timezone.utc)
    assert expiry.days_left(until, until - datetime.timedelta(days=13, hours=23)) == 13
    assert expiry.days_left(until, until + datetime.timedelta(hours=1)) == -1
