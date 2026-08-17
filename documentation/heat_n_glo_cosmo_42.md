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

## 3. Add the profile to a Blueprint custom library

A Blueprint custom library is not a file you import — it is a **folder on disk** holding three subfolders:

```
MyCustomLibrary/
├── componentProfiles/     the profile XMLs
├── images/                one image per profile, matching basename
└── documentation/         optional, surfaced in the Inspector
```

This repository is laid out the same way, so adding the profile is a copy:

1. RacePoint Blueprint → **Settings → Libraries** (older builds: **Preferences → Libraries**). Either note the path of a custom library you already have, or **+** to add a new folder — Blueprint creates the three subfolders inside it.
2. Copy `componentProfiles/heat_n_glo_cosmo_42.xml` into the library's `componentProfiles/`.
3. Copy `images/heat_n_glo_cosmo_42.png` into the library's `images/`. The basename **must** match the XML, or the component shows a placeholder icon.
4. Optionally copy this guide into `documentation/`.
5. **Restart Blueprint** — libraries are scanned at launch, so a running instance will not see the new profile.

One library can hold any number of profiles, so an existing custom library is the path of least resistance — no new registration needed.

---

## 4. Place and address the component

1. **Show Library**, search **Cosmo** (or **Heat &amp; Glo**, or **IntelliFire**), drag the component into the room with the fireplace
2. Wire its **Ethernet** port to the network switch or host
3. Double-click to open the Inspector and set the component's **IP address** to **the host running the bridge** — the Savant host itself, if you followed the default install

> The component's IP is the **bridge's** address, not the fireplace's. The fireplace address lives in `credentials.json`. This trips people up: if you point the component at the fireplace directly, polling returns JSON the profile cannot parse and nothing works.

The port is **4568**, matching the bridge default. If you changed `INTELLIFIRE_BRIDGE_PORT`, change the `port` attribute in the profile's `<control_interfaces>` and `<control>` elements to match and re-import.

---

## 5. Generate services

Click **Generate Services**. The profile declares three resources, so you get up to three services for the fireplace in that room:

| Service | What it gives you | Needs a data table entity? |
|---|---|---|
| **HVAC / Climate** | Ambient temperature, heat setpoint, Off / Heat / Auto | yes — one thermostat entity |
| **Trigger Controlled Device** | Plain On / Off tile | no |
| **Lighting Control** | 0–100 sliders for flame, accent light, blower | yes — one entity per channel |

> ### The `Show` checkbox is not the same as `Use`
>
> In **View Services**, pick the fireplace's **room** in the `Services for:` dropdown — services are listed per zone, and looking at the wrong zone shows you nothing. Each row then has **Use** *and* **Show**. `Use` realizes the service; **`Show` is what puts it in the Pro App**. Blueprint does not reliably default `Show` on for a newly generated service, and a service with `Use` ticked but `Show` clear is invisible in the app while looking completely healthy in Blueprint.

Then **Update All UI Screens → Sync to Services**, save, and upload to the host. Force-quit the Pro App and reopen it — it caches the configuration.

---

## 5a. The Climate tile

This is the service most people want: the fireplace as a heater with a thermostat.

Add **one thermostat entity** to the HVAC data table, addressed:

| Field | Value |
|---|---|
| `ThermostatAddress` | `1` |
| `ThermostatAddress2` | `1` |

Those two values must be `1`/`1` — the profile's status parser publishes its climate states under the matching `_1_1` suffix (`ThermostatCurrentTemperature_1_1`, `CurrentHVACMode_1_1`, and so on), which is the vocabulary Savant's Climate tile binds to.

The three modes, and what each does to the appliance:

| App mode | Bridge call | Appliance |
|---|---|---|
| **Off** | `GET /hvac/off` | Clears the setpoint, extinguishes |
| **Heat** | `GET /hvac/heat` | Clears the setpoint, ignites — burns at the current flame height regardless of temperature |
| **Auto** | `GET /hvac/auto` | Ignites and restores the setpoint — burns until the room reaches it |

Savant's HVAC vocabulary has no "On", so **Heat is the plain-on mode**. Cool never appears; the appliance cannot cool. Fan modes and humidity are deliberately not modelled.

> **Why the bridge remembers your setpoint.** Turning the appliance's thermostat off means writing a setpoint of `0` — there is no separate disable. So leaving Auto would otherwise discard the temperature you chose. The bridge keeps a copy and restores it when you return to Auto; only if it has never seen one does it fall back to 68 °F.

Mode changes confirm about 1.5 s after you tap, when the follow-up status fetch lands. That lag is deliberate — the appliance's own report is authoritative, rather than the tile asserting a state it only hopes is true.

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

## 6a. A custom UI screen (recommended over the stock Climate tile)

The stock Climate tile has two flaws for a fireplace, and neither can be fixed from the profile:

- **A Cool button that cannot be removed.** In Blueprint's **HVAC Settings** table, `Cool` shows ticked *and greyed out* for this component. Savant's `Auto` means auto-**changeover**, which by definition implies a cool side, so declaring `SetHVACModeAuto` forces cooling capability on. (Drop Auto and use Heat as the thermostatic mode and it should release — at the cost of a mode.)
- **A Fan On/Auto row** drawn by the Climate screen template even though the service declares no `SetFanMode*` requests at all.

A custom screen sidesteps both: you place exactly the controls you want. Everything below is verified against a live system — states read back through `sclibridge`, and the request syntax accepted by the host.

### Buttons

Every HVAC request takes the entity's address, `ThermostatAddress = 1` and `ThermostatAddress2 = 1`:

| Control | Service request | Highlight when |
|---|---|---|
| **Off** | `SetHVACModeOff` | `IsCurrentHVACModeOff_1_1` = 1 |
| **On** | `SetHVACModeHeat` | `IsCurrentHVACModeHeat_1_1` = 1 |
| **Auto** | `SetHVACModeAuto` | `IsCurrentHVACModeAuto_1_1` = 1 |
| **Setpoint ▲** | `IncreaseHeatPointTemperature` | — |
| **Setpoint ▼** | `DecreaseHeatPointTemperature` | — |
| **Setpoint (absolute)** | `SetHeatPointTemperature`, arg `HeatPointTemperature` | — |

The full request string, as accepted by the host:

```
servicerequest "Living Room" "Living Room Fireplace" "Living Room Fireplace" 1 \
  SVC_ENV_HVAC SetHVACModeOff ThermostatAddress 1 ThermostatAddress2 1
```

Zone, component and service alias are all quoted because they contain spaces. Useful for testing a binding from a shell before wiring it to a button.

### Readouts

State names are `<Component>.<LogicalComponent>.<State>`, e.g. `Living Room Fireplace.Fireplace.CurrentTemperatureF`:

| Shows | State | Note |
|---|---|---|
| Room temperature | `CurrentTemperatureF` | also as `ThermostatCurrentTemperature_1_1` |
| Setpoint | `ThermostatCurrentHeatPoint_1_1` | `32` means the thermostat is off |
| Mode | `CurrentHVACMode_1_1` | `Off`, `Heat` or `Auto` |
| Burner | `IsFireplaceOn` | 1 when lit |
| Flame | `FlameHeightPercent` / `DimmerLevel_1` | 0–100 |
| Still hot | `IsHot` | 1 while cooling down — worth showing |
| Faults | `ErrorText` | `None` when healthy |
| Reachable | `FireplaceOnline` | 0 means the bridge lost the fireplace |

### The flame control

Two ways, and the choice is about safety, not looks:

1. **Slider** — bind to the Lighting service's `DimmerSet` with `Address1 = 1` and the slider's value as `DimmerLevel`; read back `DimmerLevel_1`. You get a true 0–100 slider. The entity must exist in the Lighting data table (`Use` ticked), but you can leave `Show` clear so it never appears as its own tile under Lights. **It remains reachable by lighting scenes and "all lights off" regardless**, because the service exists.
2. **Buttons** — `FlameOff`, `FlameLow`, `FlameMediumLow`, `FlameMediumHigh`, `FlameHigh` as custom component actions, or `FlameUp`/`FlameDown` for nudges. No Lighting service, so nothing in the lighting system can ever reach the burner. Five taps instead of a slider.

Pick 2 unless you specifically want the slider feel.

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
