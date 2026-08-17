# intellifire-bridge

A small HTTP gateway that lets a Savant component profile control an IntelliFire-equipped fireplace.

Stdlib-only Ruby. No gems, no framework, ~700 lines. It runs on the Savant host under `launchd` and is the only component that holds your fireplace's API key.

## Why it exists

The IntelliFire Wi-Fi module signs every command with a two-round SHA-256 challenge/response:

```
GET  /get_challenge          -> hex challenge, valid ~10 seconds
payload  = "post:command=<cmd>&value=<val>"
inner    = SHA256(api_key_bytes + challenge_bytes + payload_bytes)
response = SHA256(api_key_bytes + inner)
POST /post   command=<cmd>&value=<val>&user=<user_id>&response=<response>
```

Savant profiles can append CRC-16, XOR, Fletcher and similar checksums, but the schema has no SHA-256 primitive. The bridge does the signing so the profile can stay a plain HTTP client.

Status polling (`GET /poll`) needs no authentication, so the bridge will start and serve read-only status with just an IP address — it just refuses commands until it has a key.

## Install

On the Savant host:

```sh
./install.sh            # per-user LaunchAgent — starts at GUI login
./install.sh --daemon   # system LaunchDaemon — starts at boot, asks for sudo
```

That copies the code to `/Users/Shared/intellifire-bridge`, offers to fetch your credentials, installs the `launchd` job, and waits for the bridge to answer.

Use `--daemon` on a host that has to come back on its own after an unattended reboot: the agent only starts once someone (or auto-login) opens a GUI session, the daemon starts at boot. `--daemon` needs sudo to write `/Library/LaunchDaemons/com.intellifire-bridge.plist`, but the plist carries a `UserName` key so the bridge itself still runs as the installing user — port 4568 needs no privilege and the bridge never shells out.

Managing the job afterwards:

```sh
# agent
launchctl bootout  "gui/$(id -u)/com.intellifire-bridge"
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.intellifire-bridge.plist

# daemon
sudo launchctl bootout  system/com.intellifire-bridge
sudo launchctl bootstrap system /Library/LaunchDaemons/com.intellifire-bridge.plist
```

To fetch credentials separately:

```sh
bin/intellifire-credentials --out /Users/Shared/intellifire-bridge/credentials.json
```

It asks for the email and password you use in the IntelliFire app, logs into `iftapi.net`, lists the fireplaces on the account, and writes the selected one's API key, user id, serial and current IP to a mode-`0600` file. **This is the only time the cloud is involved.**

```json
{
  "ip_address": "10.100.2.50",
  "api_key": "…",
  "user_id": "…",
  "serial": "…"
}
```

## Configuration

Environment always wins over `credentials.json`.

| Variable | Default | Meaning |
|---|---|---|
| `INTELLIFIRE_CREDENTIALS` | `/Users/Shared/intellifire-bridge/credentials.json` | Credentials file path |
| `INTELLIFIRE_IP` | from credentials | Fireplace address |
| `INTELLIFIRE_API_KEY` | from credentials | Per-fireplace API key |
| `INTELLIFIRE_USER_ID` | from credentials | Account user id |
| `INTELLIFIRE_BRIDGE_PORT` | `4568` | Port the bridge listens on — must match the profile |
| `INTELLIFIRE_BRIDGE_BIND` | `0.0.0.0` | Bind address; use `127.0.0.1` for loopback only |
| `INTELLIFIRE_POLL_INTERVAL` | `5.0` | Seconds between polls of the appliance |
| `INTELLIFIRE_HTTP_TIMEOUT` | `5.0` | Per-request timeout to the appliance |
| `INTELLIFIRE_COMMAND_RETRIES` | `6` | Retries when a challenge expires mid-flight |
| `INTELLIFIRE_OVERLAY_TTL` | `15.0` | How long an optimistic value may mask stale poll data |
| `INTELLIFIRE_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

## API

Every endpoint answers `200` with the same flat status document, so the Savant profile needs one parser for both polling and command acknowledgement. Failures return `4xx`/`5xx` with `ok: 0`, an `error` string, and the status fields still present.

| Endpoint | Effect |
|---|---|
| `GET /` `GET /status` | Full status document |
| `GET /health` | Version, liveness, whether control is configured |
| `GET /power/on\|off\|toggle` | Ignite / extinguish |
| `GET /flame/<0-4>` | Absolute flame height |
| `GET /flame/up\|down\|off\|max` | Relative and shorthand |
| `GET /flame/percent/<0-100>` | Percent, mapped onto 0–4 |
| `GET /fan/…` | Same forms, blower speed 0–4 |
| `GET /light/…` | Same forms, accent light 0–3 |
| `GET /dimmer/<channel>/<0-100>` | Channel `1`/`flame`, `2`/`light`, `3`/`fan` |
| `GET /thermostat/f/<°F>` | Setpoint in whole Fahrenheit degrees |
| `GET /thermostat/c/<°C>` | Setpoint in whole Celsius degrees (0–37) |
| `GET /thermostat/raw/<0-3700>` | Setpoint in the device's own hundredths-of-°C |
| `GET /thermostat/up\|down\|off` | Nudge by 1 °F, or disable |
| `GET /hvac/off\|heat\|auto` | Climate mode: extinguish / burn now / burn to setpoint |
| `GET /timer/<0-180>` | Auto-off timer in minutes |
| `GET /timer/off` | Cancel the timer |
| `GET /pilot/on\|off` | Standing pilot |
| `GET /beep` | Locate chirp |
| `GET /soft_reset` | Clear a soft lockout after failed ignition |

`POST` is accepted on all of them. Commands are reachable by `GET` because Savant's HTTP control interface builds a URL far more readily than a form body, and this is a LAN-local appliance gateway.

### The status document

Deliberately dull: one flat level, integers and strings only. No nesting, no arrays, no JSON booleans — Savant's `root_object format="json"` parser addresses values by simple path, so flags are `0`/`1` and the error list arrives pre-collapsed.

```json
{
  "ok": 1, "online": 1,
  "power": 1, "power_status": "ON",
  "flame_height": 3, "flame_percent": 75,
  "fan_speed": 2, "fan_percent": 50,
  "light_level": 1, "light_percent": 33,
  "pilot": 1, "hot": 1, "prepurge": 0,
  "thermostat": 1, "setpoint_raw": 2200, "setpoint_c": 22, "setpoint_f": 72,
  "temperature_c": 21, "temperature_f": 70,
  "timer": 0, "time_remaining_s": 0, "time_remaining_min": 0,
  "has_fan": 1, "has_light": 1, "has_thermostat": 1, "has_power_vent": 0,
  "error_count": 0, "error_codes": "", "error_text": "None",
  "serial": "…", "firmware": "1.3.0", "ip": "10.100.2.50", "uptime": 3362,
  "age_ms": 431, "poll_errors": 0
}
```

`age_ms` is how stale the underlying poll is; `online` is `0` when the last poll failed. Before the first successful poll the same keys are returned with `ok: 0`, so the profile's state variables always initialize.

`has_fan` / `has_light` / `has_thermostat` are the appliance's own report of which accessories it has — check these before adding the matching Savant entities.

## Design notes

**One poller.** The appliance's Wi-Fi module is small, so exactly one thread polls it and everyone else reads a cache. Savant can poll the bridge as fast as it likes.

**Optimistic overlay.** A command takes a moment to appear in `/poll`. An accepted command records the value it set; that value masks stale poll data until either a later poll agrees with it or `INTELLIFIRE_OVERLAY_TTL` elapses. Without it the Pro App would snap back to the old value for a beat after every tap. Because the overlay clears as soon as the device agrees, a change made at the fireplace's own panel is never masked for long.

**Relative commands resolve server-side.** `/flame/up` is computed against the freshest value the bridge has, overlay included, so two quick taps step 2→3→4 rather than both reading a stale 2.

**Range checking before transmission.** The client enforces the same ranges the IntelliFire app does; an out-of-range value is a `400` and never reaches the appliance.

## Testing

```sh
rake test
```

58 tests. Notably:

- `client_test.rb` checks the signature against an independently computed reference vector, and that it is sensitive to every input.
- `status_test.rb` asserts the document really is flat scalars only — that shape is a contract with the Savant JSON parser, not a stylistic preference.
- `poller_test.rb` drives the overlay with an injected clock, including the case where a stale overlay would otherwise mask a real change.
- `profile_contract_test.rb` parses `../componentProfiles/heat_n_glo_cosmo_42.xml` and asserts every endpoint it calls is routable and every JSON path it reads is emitted.

No hardware is required; a `FakeClient` stands in for the appliance.
