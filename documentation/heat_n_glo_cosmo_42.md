# Heat &amp; Glo Cosmo 42 — Savant Integrator Setup Guide

Profile version 0.1 · bridge 0.1.0 · written against SavantOS / da Vinci 11.2.1

---

## 1. Before you start

Confirm all of the following. Each one is a place the integration silently fails if it is not true.

| Check | How |
|---|---|
| The IntelliFire Wi-Fi module is installed | There is an `IFT-WFM` board stabbed onto the IntelliFire Touch control module in the appliance's control cavity |
| The module is on your network | The fireplace appears and responds in the IntelliFire phone app |
| It is on 2.4 GHz | The module does not join 5 GHz-only SSIDs |
| You know its IP | IntelliFire app → device settings, or your router's client list |
| The IP is reserved | Add a DHCP reservation; the profile addresses the bridge, but the bridge addresses the fireplace by IP |
| Ruby is present on the Savant host | `ruby -v` over SSH; the macOS system Ruby is sufficient |

You will also need the **email and password for your IntelliFire account** — used once, in step 2.

---

## 2. Install the bridge on the Savant host

The profile cannot sign IntelliFire commands itself (see [why](../README.md#why-there-is-a-bridge)), so a small Ruby helper does it.

Copy the `bridge/` directory to the Savant host, then:

```sh
cd bridge
./install.sh            # LaunchAgent — starts at GUI login
./install.sh --daemon   # LaunchDaemon — starts at boot (recommended on a host)
```

The installer:

1. copies the code to `/Users/Shared/intellifire-bridge`
2. offers to run `bin/intellifire-credentials`, which logs into `iftapi.net`, lists the fireplaces on your account, and writes the selected one's API key + user id to `credentials.json` (mode `0600`)
3. installs and bootstraps the `launchd` job `com.intellifire-bridge` — a per-user agent, or with `--daemon` a system daemon in `/Library/LaunchDaemons` that still runs as the installing user
4. waits for the bridge to answer, then prints its health and status

### Verify before touching Blueprint

```sh
curl http://127.0.0.1:4568/health
curl http://127.0.0.1:4568/status
```

`/health` should show `"canControl": 1`. `/status` should show `"online": 1` and a real `serial`.

Then prove the signing works end to end — this is the step that separates "the bridge is running" from "the bridge can actually drive the appliance":

```sh
curl http://127.0.0.1:4568/beep      # the fireplace should chirp
curl http://127.0.0.1:4568/power/on  # it should ignite
curl http://127.0.0.1:4568/power/off
```

If `/beep` chirps, everything downstream is a Savant configuration problem, not a protocol problem.

---

## 3. Import the profile into Blueprint

1. RacePoint Blueprint → **Preferences → Libraries**
2. **+** to add a User Library (or select your existing custom library)
3. With the library selected, **Import…** and choose `componentProfiles/heat_n_glo_cosmo_42.xml`
4. Drop `images/heat_n_glo_cosmo_42.png` into the library's `images/` folder — the basename must match the XML filename — and restart Blueprint to pick it up
5. Optionally place this guide in the library's `documentation/` folder for in-Inspector access

---

## 4. Place and address the component

1. **Show Library**, search **Cosmo** (or **Heat &amp; Glo**, or **IntelliFire**), drag the component into the room with the fireplace
2. Wire its **Ethernet** port to the network switch or host
3. Double-click to open the Inspector and set the component's **IP address** to **the host running the bridge** — the Savant host itself, if you followed the default install

> The component's IP is the **bridge's** address, not the fireplace's. The fireplace address lives in `credentials.json`. This trips people up: if you point the component at the fireplace directly, polling returns JSON the profile cannot parse and nothing works.

The port is **4568**, matching the bridge default. If you changed `INTELLIFIRE_BRIDGE_PORT`, change the `port` attribute in the profile's `<control_interfaces>` and `<control>` elements to match and re-import.

---

## 5. Generate services

Click **Generate Services**. You should get a **Trigger Controlled Device** service for the fireplace in that room.

Then **Update All UI Screens → Sync to Services**, save, and upload to the host.

At this point the Pro App gives you **On / Off** and all the status feedback. Everything else is a custom action you place on a UI screen, bind to a keypad button, or call from a scene or workflow.

---

## 6. Optional — sliders for flame, light and blower

Savant has no fireplace service with a level control, so the three continuously-variable functions borrow the **Lighting** service to get a 0–100 slider.

Add entities to the **Lighting** data table:

| `Address1` | Controls | Device range | Add it? |
|---|---|---|---|
| `1` | **Flame height** | 0–4 | ⚠️ read the warning below |
| `2` | **Accent light** | 0–3 | Only if `has_light` is `1` in `/status` |
| `3` | **Blower** | 0–4 | Only if `has_fan` is `1` in `/status` |

Give each a friendly name — "Fireplace Flame", "Fireplace Ember Light", "Fireplace Blower". The bridge maps 0–100 onto each channel's own step count, so the slider lands on real device levels rather than interpolating.

> ### ⚠️ Adding entity `1` puts a gas burner on a Lighting service
>
> That means whole-house lighting scenes, "all lights off", and "turn on the lights" voice commands can reach the flame — including igniting it. If that is not what you want, skip `Address1 = 1` and use the flame **custom actions** instead (`FlameOff`, `FlameLow` … `FlameHigh`, `FlameUp`, `FlameDown`, `SetFlameHeight`), which live on the fireplace's own service and are not swept up by lighting control.
>
> Entities `2` and `3` control accessories and carry no such risk.

Only add entities for accessories your appliance actually has. `curl http://127.0.0.1:4568/status` reports `has_fan`, `has_light` and `has_thermostat` straight from the appliance.

---

## 7. Custom actions reference

All available on the fireplace's logical component.

### Flame
`FlameOff` · `FlameLow` · `FlameMediumLow` · `FlameMediumHigh` · `FlameHigh` · `FlameUp` · `FlameDown` · `SetFlameHeight(FlameHeight 0–4)`

### Blower
`BlowerOff` · `BlowerLow` · `BlowerMedium` · `BlowerHigh` · `BlowerUp` · `BlowerDown` · `SetBlowerSpeed(BlowerSpeed 0–4)`

### Accent light
`AccentLightOff` · `AccentLightLow` · `AccentLightMedium` · `AccentLightHigh` · `SetAccentLightLevel(AccentLightLevel 0–3)`

### Thermostat
`ThermostatOff` · `ThermostatUp` · `ThermostatDown` · `SetThermostatF(Temperature °F)` · `SetThermostatC(Temperature °C, 0–37)`

`ThermostatUp` / `ThermostatDown` step by 1 °F. Turning the thermostat on hands flame control to the appliance, which modulates to hold the setpoint.

### Timer
`TimerOff` · `Timer30Minutes` · `Timer60Minutes` · `Timer120Minutes` · `SetTimerMinutes(Minutes 0–180)`

### Pilot and diagnostics
`PilotOn` · `PilotOff` · `Beep` · `SoftReset`

Leaving the standing pilot on lets the appliance relight instantly but burns gas continuously; off is the efficient setting at the cost of a slower start. `SoftReset` clears a soft lockout after a failed ignition attempt.

### Status
`GetFireplaceStatus` — runs automatically on connect, every 5 seconds, and 1.5 seconds after each command. You should not need to call it by hand.

---

## 8. State variables

Visible in the Inspector and System Monitor, and usable as conditions in workflows.

| Variable | Type | Notes |
|---|---|---|
| `CurrentPowerStatus` | string | `ON` / `OFF` — what the service's On/Off tile reads |
| `IsFireplaceOn` | integer | `0` / `1` |
| `FlameHeight` / `FlameHeightPercent` | integer | 0–4 / 0–100 |
| `BlowerSpeed` / `BlowerSpeedPercent` | integer | 0–4 / 0–100 |
| `AccentLightLevel` / `AccentLightPercent` | integer | 0–3 / 0–100 |
| `PilotOn` | integer | standing pilot lit |
| `IsHot` | integer | appliance still hot after shutdown |
| `ThermostatEnabled` | integer | thermostat mode active |
| `ThermostatSetPointC` / `ThermostatSetPointF` | integer | whole degrees |
| `CurrentTemperatureC` / `CurrentTemperatureF` | integer | measured at the appliance |
| `TimerEnabled` / `TimeRemainingMinutes` | integer | auto-off timer |
| `HasBlower` / `HasAccentLight` / `HasThermostat` | integer | appliance's own accessory report |
| `ErrorCount` / `ErrorText` | integer / string | e.g. `Pilot Flame, Lights` |
| `FireplaceOnline` | integer | `0` when the bridge cannot reach the fireplace |
| `FireplaceSerial` / `FirmwareVersion` | string | |

`IsHot` is worth a workflow: it stays `1` for a while after shutdown, which is exactly when you do not want a "fireplace is off, safe to close up" notification firing.

---

## 9. Troubleshooting

**Everything is blank / no feedback at all**

Check the bridge first, from the Savant host:

```sh
curl http://127.0.0.1:4568/status
tail -n 50 /Users/Shared/intellifire-bridge/log/intellifire-bridge.log
```

The log is JSON lines. Look for `poll_failed` (bridge cannot reach the fireplace) versus no `started` line at all (bridge is not running).

```sh
launchctl print "gui/$(id -u)/com.intellifire-bridge" | head -20   # agent install
sudo launchctl print system/com.intellifire-bridge | head -20      # --daemon install
```

**`/status` shows `"online": 0`**

The bridge is running but cannot reach the fireplace. Confirm the address, and test the unauthenticated poll directly:

```sh
curl http://<fireplace-ip>/poll
```

If that fails too, it is a network or appliance problem, not a bridge problem. If the IP changed, fix `ip_address` in `credentials.json` and add the DHCP reservation you meant to add.

**`/status` works but commands do nothing**

`"canControl": 0` in `/health` means the API key or user id is missing — re-run `bin/intellifire-credentials`.

If `canControl` is `1` and commands still fail, watch for `command_rejected` in the log. A persistent `403` means the API key does not match this appliance — easy to do if your account has more than one fireplace and the wrong one was selected.

```sh
curl -v http://127.0.0.1:4568/power/on
```

**Commands work over curl but not from Savant**

A Savant-side problem. In System Monitor, watch `CurrentPowerStatus` and `FlameHeight` while you tap the app. If they never change, the profile is not polling — confirm the component's IP is the **bridge**, not the fireplace, and that the port matches.

**The slider does nothing / moves the wrong thing**

Check `Address1` in the Lighting data table: `1` flame, `2` accent light, `3` blower. Each entity needs a distinct value.

**The appliance will not light**

Check `ErrorText`. `Soft Lock Out` means a failed ignition attempt — call `SoftReset`, then try again. `Pilot Flame` or `Disabled` mean the appliance has safely disabled itself and wants a dealer, not a software fix.

**Feedback lags or flickers after a tap**

Expected briefly: the bridge holds an optimistic value for up to 15 seconds while the appliance catches up. Flickering that persists past that suggests something else is also driving the fireplace — the IntelliFire app, a schedule set in it, or the appliance's own panel.
