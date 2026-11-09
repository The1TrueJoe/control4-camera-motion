# control4-camera-motion

A Control4 DriverWorks driver that turns an **ONVIF NVR/DVR's motion detection** into standard
Control4 **contact (motion) sensors** — one per camera channel. A Homebridge plugin
([homebridge-control4](https://github.com/The1TrueJoe/homebridge-control4)) then reads those
sensors by name and forwards them to HomeKit Secure Video.

All the device-specific motion logic lives **here**, so the plugin stays vendor-agnostic: it only
ever reads a generic Control4 contact sensor's `ContactState`.

| File | Proxy | What it exposes |
|---|---|---|
| `camera_motion.c4z` | `contactsingle` × N | one motion/contact sensor per camera channel, fed by the NVR's ONVIF motion events |

## How motion is detected (ONVIF, not ISAPI)

This driver talks to the NVR over **ONVIF**, which every modern NVR (Hikvision/ISAPI OEMs like
Luma/SnapAV, Dahua, Uniview, Axis, …) exposes on its HTTP port.

On the Luma/SnapAV test unit (Hikvision OEM) the legacy ISAPI event interface is **gone** — every
`/ISAPI/Event/notification/*` path returns 404, and ISAPI accepts only Basic auth with
streaming-only rights — so ONVIF is both the working path and the portable one. The driver:

1. `CreatePullPointSubscription` on `/onvif/events_service`.
2. Long-polls `PullMessages` against the returned subscription URL, back to back.
3. Parses `tns1:VideoSource/MotionAlarm` notifications (`Source=VideoSourceToken00N`,
   `State=true|false`) — also accepts `tns1:RuleEngine/CellMotionDetector/Motion` (`IsMotion`).
4. Maps the token's trailing number to a channel and drives that channel's contact sensor.

Each `PullMessages` is one HTTP POST with an async callback, so nothing blocks the controller and
no socket is held open. Continuous polling also keeps the subscription's termination time renewed;
any failure drops the subscription and re-subscribes with backoff.

**Auth** is ONVIF WS-Security `UsernameToken` with `PasswordDigest = Base64(SHA1(nonce + created +
password))`, built in Lua with `C4:Hash` + `C4:Base64Encode`. (Control4's `C4:url` only does Basic
auth natively, which the NVR's ISAPI needs but ONVIF does not — ONVIF carries its own auth in the
SOAP header, so no digest HTTP client is required.)

## The contract for the Homebridge plugin

Precise, so the plugin side can match it:

- **Proxy:** each channel is a Control4 `contactsingle` sub-device (control `control4_contactsingle`,
  a type-2 `CONTACT_SENSOR` connection). The plugin discovers items whose `proxy` is `contactsingle`.
- **State variable:** the proxy exposes **`ContactState`** (boolean). The driver sets it via the
  contact proxy notifications:
  - `OPENED` → motion (ContactState true), also fires the stock "senses motion" event;
  - `CLOSED` → no motion (ContactState false), fires "stops sensing motion";
  - `STATE_OPENED` / `STATE_CLOSED` set the state without firing events (initial sync, and the
    answer to the proxy's `GET_STATE`).
  The plugin reads `ContactState` and treats `true`/`1`/`open`/`opened`/`motion`/`active` as motion.
- **Naming / matching:** the plugin matches a sensor to a camera by **device name**. Set each
  `Camera N Name` property and name the matching sub-device in Composer to the camera's name (e.g.
  `Front Door`). Channels default to `Camera 1` … `Camera 8`; set each to match your
  camera so the HomeKit plugin can link them automatically.

## Properties

- **DVR Address**, **HTTP Port** (default 80), **Username**, **Password** — the NVR account (needs
  an ONVIF/operator role).
- **Camera Channel Count** (1–8, default 8) — channels above this are left inert.
- **Motion Hold (seconds)** — keep a sensor open this long after motion ends (debounce / HKSV hold).
- **Pull Timeout (seconds)** — the ONVIF long-poll window per request.
- **Camera 1–8 Name** — per-channel names.
- **Test Connection** / **Restart Motion Monitor** actions; **Connection Status** / **Last Event**
  read-outs.

## Caveats

- **Static channel count.** The driver ships with eight `contactsingle` proxies (the test NVR has
  eight channels). `Camera Channel Count` limits how many are driven; to go above eight, add
  matching `<proxy>` / `<connection>` pairs in `driver.xml` and rebuild.
- **Polling, not a push stream.** ONVIF PullPoint is request/response, which is exactly what
  `C4:url` supports. Latency is one poll round-trip (sub-second with a short Pull Timeout).
- **ISAPI digest in Lua is avoided entirely** — ONVIF carries its own WS-Security auth, so the
  driver never needs an HTTP digest client.

## Build

```sh
./build.sh          # -> dist/camera_motion.c4z
```

Concatenates `src/*.lua` (in filename order) into `driver/driver.lua`, syntax-checks it as Lua
5.1, stamps the version/date, and zips it with `driver.xml` and `www/`. A `.c4z` is a plain zip.
Requires `zip` and, for the syntax check, `luajit` or `luac`.

## Test

```sh
./build.sh && python3 test/run_tests.py
```

Runs the built `driver.lua` against a fake ONVIF NVR (`test/fake_dvr.py`) in the `c4mock.py`
harness ([control4-test-harness](https://github.com/The1TrueJoe/control4-test-harness), checked out
next to this repo or at `C4_TEST_HARNESS`). Needs `lupa` and `cryptography`. Tests cover
subscribe/pull bring-up, per-channel motion mapping, open/close, the debounce hold, `GET_STATE`,
the Test Connection action and inactive-channel suppression.

## License

MIT © The1TrueJoe
