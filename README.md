# Heat &amp; Glo Cosmo 42 — Savant Component Profile

A custom [Savant](https://www.savant.com) component profile for the [Heat &amp; Glo Cosmo 42](https://www.heatnglo.com) gas fireplace fitted with the **IntelliFire Wi-Fi module (IFT-WFM)**. It brings the fireplace into the Savant Pro App with power, flame height, blower, accent light, thermostat, auto-off timer and live status — all over your LAN, with the cloud touched exactly once during setup.

<p align="center">
  <img src="images/heat_n_glo_cosmo_42.png" alt="Heat &amp; Glo Cosmo 42" width="180"/>
</p>

> This is a community-authored integration. It is not an official Savant, Heat &amp; Glo, or Hearth &amp; Home Technologies product, and is provided as-is. Gas appliances are not toys — read the safety notes before wiring the flame to a Lighting service or a voice assistant.

## Why there is a bridge

The IntelliFire module will happily tell anyone on the LAN what it is doing — `GET /poll` needs no authentication. But every **command** must be signed with a two-round SHA-256 challenge/response:

```
payload  = "post:command=<cmd>&value=<val>"
inner    = SHA256(api_key_bytes + challenge_bytes + payload_bytes)
response = SHA256(api_key_bytes + inner)
```

Savant component profiles can append CRC-16, XOR, Fletcher and a dozen similar checksums, but there is no SHA-256 primitive in the schema — so a profile cannot sign these commands, and a profile-only integration would be read-only.

So this repo ships two halves:

```
┌───────────────┐  HTTP GET   ┌────────────────────┐  HTTP + SHA-256   ┌──────────────┐
│ Savant host   │ ──────────▶ │ intellifire-bridge │ ────────────────▶ │  IntelliFire │
│ (the profile) │ ◀────────── │  (Ruby, launchd)   │ ◀──────────────── │  Wi-Fi module│
└───────────────┘   JSON      └────────────────────┘   challenge/resp  └──────────────┘
```

The bridge is stdlib-only Ruby (~700 lines), runs on the Savant host under `launchd`, and is the only thing that holds your API key. It follows the same shape as the [`savant-bridge`](https://github.com/martin-robert-fink/homebridge-savant-scli) gateway: dumb, allowlisted, structured-logging, no business logic beyond unit conversion.

## What you get

- **Climate tile** — the fireplace as a heater: ambient temperature, heat setpoint, and three modes. **Off** extinguishes, **Heat** burns now regardless of temperature, **Auto** burns until the setpoint is met. Savant's HVAC vocabulary has no "on", so Heat is the plain-on mode; cooling, fan modes and humidity are not modelled because the appliance has none
- **On / Off** — the fireplace also appears as a Trigger Controlled Device service, the same service Savant's own Escea profile uses
- **Flame height** — 5 discrete levels, as preset actions or as a 0–100 slider
- **Blower** — 5 speeds, preset actions or slider
- **Accent light** — 4 levels, preset actions or slider
- **Thermostat** — setpoint in whole °F or °C, plus up/down nudges and off. Disabling it means writing a zero setpoint to the appliance, so the bridge keeps a copy of your temperature and restores it when you return to Auto
- **Auto-off timer** — 30/60/120-minute presets or any value up to 3 hours
- **Standing pilot** on/off, **locate chirp**, and **soft-reset** after a failed ignition
- **Live status** — burner state, flame/blower/light levels, room temperature, setpoint, timer remaining, pilot, still-hot flag, appliance error text, firmware and serial. Polled every 5 seconds, so the app tracks changes made at the fireplace's own panel or in the IntelliFire app
- **Optimistic feedback** — a tap updates the UI immediately; the bridge holds the new value over stale poll data until the appliance catches up, then lets the real state through

## Tested with

| Item | Version |
|---|---|
| Heat &amp; Glo Cosmo 42 | IntelliFire Wi-Fi module (IFT-WFM) |
| intellifire-bridge | 0.1.0 |
| Savant da Vinci | 11.2.1 |
| Profile version | 0.1 |

Should work unchanged on any IntelliFire-equipped appliance — Cosmo 32/36, and other Heat &amp; Glo, Quadra-Fire, Vermont Castings and Majestic models — since they all speak the same local API. Only the Cosmo 42 has been exercised here.

## Requirements

- **Heat &amp; Glo Cosmo 42** with the **IntelliFire Wi-Fi module (IFT-WFM)** installed, joined to a 2.4 GHz network, and working in the IntelliFire phone app
- A **static IP** for the fireplace (DHCP reservation recommended)
- **Savant host** running SavantOS 11.2 or later, reachable on the same LAN
- **Ruby** on the Savant host — the system Ruby is fine, no gems required
- Your **IntelliFire app credentials**, used once to fetch the fireplace's API key

## Repository layout

```
componentProfiles/heat_n_glo_cosmo_42.xml   ← the Savant component profile
images/heat_n_glo_cosmo_42.png              ← Library / Inspector icon
documentation/heat_n_glo_cosmo_42.md        ← full integrator setup guide
bridge/                                     ← the intellifire-bridge helper
```

The first three mirror a Savant User Library, so their contents can be copied straight in.

> The icon is a generic fireplace glyph, not a product photo — swap in a real one if you'd like; the basename just has to keep matching the XML.

## Quick start

```sh
# 1. On the Savant host, install and start the bridge.
#    It will offer to fetch your API key from iftapi.net.
cd bridge && ./install.sh

# 2. Confirm it can see the fireplace.
curl http://127.0.0.1:4568/status

# 3. Light it, to prove the signing works.
curl http://127.0.0.1:4568/power/on
```

Then import `componentProfiles/heat_n_glo_cosmo_42.xml` into a Blueprint User Library, drop the component into the room, set its IP address to the Savant host, and Generate Services.

The [full setup guide](documentation/heat_n_glo_cosmo_42.md) covers each step, the data-table entries for the optional sliders, and troubleshooting.

## The bridge API

Every endpoint — polls and commands alike — returns the same flat JSON status document, which is why the profile needs only one parser. See [`bridge/README.md`](bridge/README.md) for the full reference.

| Endpoint | Effect |
|---|---|
| `GET /status` | Full status document |
| `GET /health` | Bridge liveness and whether it is configured for control |
| `GET /power/on\|off\|toggle` | Ignite / extinguish |
| `GET /flame/0..4\|up\|down\|off\|max` | Flame height |
| `GET /fan/0..4\|up\|down` | Blower speed |
| `GET /light/0..3\|up\|down` | Accent light |
| `GET /dimmer/<1\|2\|3>/<0-100>` | Percent control — the shape Savant's `DimmerSet` produces |
| `GET /thermostat/f/<°F>` | Setpoint (also `c/`, `raw/`, `up`, `down`, `off`) |
| `GET /timer/<minutes>` | Auto-off timer, 0–180 (also `/timer/off`) |
| `GET /pilot/on\|off` | Standing pilot |
| `GET /beep`, `GET /soft_reset` | Locate chirp, clear soft lockout |

Commands are reachable by `GET` on purpose: Savant's HTTP control interface builds a URL far more readily than a form body, and this is a LAN-local appliance gateway rather than a public API.

## Safety notes

**The flame slider is opt-in.** Savant has no fireplace service with a level control, so flame height borrows the Lighting service to get a slider. That means adding the flame entity puts a gas burner on a Lighting service, where whole-house scenes and "turn on the lights" voice commands can reach it. Add data-table entity `Address1 = 1` only if you want that. The accent light (`2`) and blower (`3`) are accessories and carry no such risk.

**The bridge holds real credentials.** `credentials.json` is written mode `0600` and contains your fireplace's API key and your account user id. It is not in this repository and should not be committed. The bridge binds to `0.0.0.0:4568` by default so the Savant host can reach it across the LAN; set `INTELLIFIRE_BRIDGE_BIND=127.0.0.1` if you install it on the Savant host itself and want it strictly loopback.

**Nothing here overrides the appliance's own safeties.** The module rejects out-of-range values, enforces its own ignition interlocks, and will refuse commands while in a hard lockout. The bridge range-checks before sending, but it is a convenience, not a safety layer.

## Development

```sh
cd bridge && rake test
```

58 tests cover the signing algorithm against a reference vector, the status document's shape, range checking, the optimistic overlay, and every route.

Seven of them are **contract tests** that parse the shipped `heat_n_glo_cosmo_42.xml` and assert that every endpoint the profile calls is routable, and every JSON path it reads is actually emitted — in both the live and the offline status document. Rename a field on either side of the bridge and the suite fails locally instead of silently on the Savant host.

## Credits

The local IntelliFire protocol was reverse-engineered by the Home Assistant community. This integration owes its protocol knowledge to [`jeeftor/intellifire4py`](https://github.com/jeeftor/intellifire4py) and [`corinuss/Hubitat_IntelliFire`](https://github.com/corinuss/Hubitat_IntelliFire); the signing construction and error-code table were verified against both.

## Changelog

- **0.1** — Initial release: power, flame height, blower, accent light, thermostat, timer, pilot, diagnostics, and full status feedback via the `intellifire-bridge` helper.

## License

MIT — see [LICENSE](LICENSE).
