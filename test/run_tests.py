"""Tests for the NVR Camera Motion driver, against a fake ONVIF NVR.

    ./build.sh && python3 test/run_tests.py

Needs: lupa, cryptography (pip install lupa cryptography), and control4-test-harness checked out
next to this repo (or C4_TEST_HARNESS set).
"""

import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(__file__))

from harness import Director  # noqa: E402
from fake_dvr import FakeDvr  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER = os.path.join(ROOT, "driver", "driver.lua")

RESULTS = []


def test(fn):
    RESULTS.append(fn)
    return fn


def start(fake, **props):
    """Build a driver instance wired to `fake`, with a SendToProxy recorder, and bring it up."""
    base = {
        "DVR Address": fake.host,
        "HTTP Port": str(fake.port),
        "Username": "control4",
        "Password": "testpass",
        "Camera Channel Count": "8",
        "Motion Hold (seconds)": "5",
        "Pull Timeout (seconds)": "1",
        "Debug Mode": "Off",
    }
    base.update(props)
    d = Director(web=fake)
    h = d.add(DRIVER, base, "camera_motion.c4z")

    h.proxy_calls = []  # [(binding:int, command:str)]

    def rec(_c4, binding, command, params=None, kind=None):
        cmd = command.decode() if isinstance(command, bytes) else str(command)
        h.proxy_calls.append((int(binding), cmd))

    h.lua.globals().C4[b"SendToProxy"] = rec
    h.init()
    return h


def cmds(h, binding=None):
    return [c for (b, c) in h.proxy_calls if binding is None or b == binding]


def saw(h, binding, command):
    return (binding, command) in h.proxy_calls


def status(h):
    return h.properties.get("Connection Status")


# --- tests -----------------------------------------------------------------------------------

@test
def test_comes_online():
    fake = FakeDvr()
    h = start(fake)
    assert h.run(3, lambda: status(h) == "Monitoring motion"), f"status={status(h)!r}"
    assert fake.subscriptions >= 1, "never subscribed"
    assert fake.pulls >= 1, "never pulled"


@test
def test_startup_reports_closed():
    fake = FakeDvr()
    h = start(fake)
    h.run(1, lambda: status(h) == "Monitoring motion")
    for ch in range(1, 9):
        assert saw(h, 5000 + ch, "STATE_CLOSED"), f"channel {ch} not initialised closed"


@test
def test_motion_opens_and_closes():
    fake = FakeDvr()
    h = start(fake, **{"Motion Hold (seconds)": "0"})  # close immediately
    assert h.run(3, lambda: status(h) == "Monitoring motion")
    fake.queue_motion(3, True)
    assert h.run(3, lambda: saw(h, 5003, "OPENED")), "channel 3 never opened"
    fake.queue_motion(3, False)
    assert h.run(3, lambda: saw(h, 5003, "CLOSED")), "channel 3 never closed"


@test
def test_channel_mapping():
    fake = FakeDvr()
    h = start(fake)
    assert h.run(3, lambda: status(h) == "Monitoring motion")
    fake.queue_motion(8, True)  # VideoSourceToken008 -> channel 8 (Backyard)
    assert h.run(3, lambda: saw(h, 5008, "OPENED")), "channel 8 never opened"
    assert not saw(h, 5001, "OPENED"), "channel 1 opened by mistake"
    assert not saw(h, 5007, "OPENED"), "channel 7 opened by mistake"


@test
def test_inactive_channel_ignored():
    fake = FakeDvr()
    h = start(fake, **{"Camera Channel Count": "4"})
    assert h.run(3, lambda: status(h) == "Monitoring motion")
    fake.queue_motion(6, True)  # above the configured count
    h.run(1)
    assert not saw(h, 5006, "OPENED"), "inactive channel 6 should be ignored"
    assert not saw(h, 5006, "STATE_CLOSED"), "inactive channel 6 should not be initialised"


@test
def test_debounce_holds_open():
    fake = FakeDvr()
    h = start(fake, **{"Motion Hold (seconds)": "1"})
    assert h.run(3, lambda: status(h) == "Monitoring motion")
    fake.queue_motion(2, True)
    assert h.run(3, lambda: saw(h, 5002, "OPENED"))
    before = len(cmds(h, 5002))
    fake.queue_motion(2, False)
    h.run(0.4)  # within the 1s hold
    assert not saw(h, 5002, "CLOSED"), "closed before the hold elapsed"
    assert h.run(2, lambda: saw(h, 5002, "CLOSED")), "never closed after the hold"
    assert before >= 1


@test
def test_get_state_answered():
    fake = FakeDvr()
    h = start(fake, **{"Motion Hold (seconds)": "0"})
    assert h.run(3, lambda: status(h) == "Monitoring motion")
    fake.queue_motion(1, True)
    assert h.run(3, lambda: saw(h, 5001, "OPENED"))
    h.proxy_calls.clear()
    h.g("ReceivedFromProxy")(5001, b"GET_STATE", h.to_lua({}))
    assert saw(h, 5001, "STATE_OPENED"), "GET_STATE not answered with current (open) state"


@test
def test_test_connection_action():
    fake = FakeDvr()
    h = start(fake)
    h.run(0.5)
    h.g("ExecuteCommand")(b"TEST_CONNECTION", h.to_lua({}))
    assert h.run(3, lambda: status(h) == "OK: ONVIF events available"), f"status={status(h)!r}"
    assert "datetime" in fake.calls and "subscribe" in fake.calls


@test
def test_no_address():
    fake = FakeDvr()
    h = start(fake, **{"DVR Address": ""})
    h.run(1)
    assert status(h) == "No DVR address set", f"status={status(h)!r}"
    assert fake.subscriptions == 0


def main():
    passed = 0
    for fn in RESULTS:
        try:
            fn()
            print(f"ok   {fn.__name__}")
            passed += 1
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {fn.__name__}: {e}")
            traceback.print_exc()
    print(f"\n{passed}/{len(RESULTS)} passed")
    sys.exit(0 if passed == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
