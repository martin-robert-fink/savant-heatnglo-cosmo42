module IntellifireBridge
  # Translates a raw /poll payload into the flat document the Savant profile
  # parses.
  #
  # Savant's `root_object format="json"` construct addresses values by simple
  # path and expects scalars, so the output here is deliberately dull: one flat
  # level, integers and strings only. No nested objects, no arrays, and no JSON
  # booleans — flags are emitted as 0/1 integers, and the error list is
  # collapsed into a string.
  module Status
    # Decoded from the IntelliFire Android app; the same table the Home
    # Assistant integration uses.
    ERROR_CODES = {
      2 => 'Pilot Flame',
      4 => 'Flame',
      6 => 'Fan Delay',
      64 => 'Maintenance',
      129 => 'Disabled',
      130 => 'Pilot Flame',
      132 => 'Fan',
      133 => 'Lights',
      134 => 'Accessory',
      144 => 'Soft Lock Out',
      145 => 'Disabled',
      642 => 'Offline',
      3269 => 'ECM Offline'
    }.freeze

    FLAME_STEPS = 4  # flame height and fan speed are both 0-4
    LIGHT_STEPS = 3  # accent light is 0-3

    module_function

    # poll:      raw Hash from Client#poll, or nil if never polled
    # online:    whether the last poll attempt succeeded
    # age_ms:    milliseconds since that poll
    def build(poll:, online:, age_ms:, poll_errors: 0)
      return offline(poll_errors) if poll.nil?

      errors = Array(poll['errors']).map(&:to_i)
      power = int(poll['power'])
      flame = clamp(int(poll['height']), 0, FLAME_STEPS)
      fan = clamp(int(poll['fanspeed']), 0, FLAME_STEPS)
      light = clamp(int(poll['light']), 0, LIGHT_STEPS)
      setpoint_raw = int(poll['setpoint'])
      temperature_c = int(poll['temperature'])
      remaining = int(poll['timeremaining'])

      {
        'ok' => 1,
        'online' => online ? 1 : 0,

        'power' => power,
        'power_status' => power == 1 ? 'ON' : 'OFF',

        'flame_height' => flame,
        'flame_percent' => to_percent(flame, FLAME_STEPS),
        'fan_speed' => fan,
        'fan_percent' => to_percent(fan, FLAME_STEPS),
        'light_level' => light,
        'light_percent' => to_percent(light, LIGHT_STEPS),

        'pilot' => int(poll['pilot']),
        'hot' => int(poll['hot']),
        'prepurge' => int(poll['prepurge']),

        'thermostat' => int(poll['thermostat']),
        'setpoint_raw' => setpoint_raw,
        'setpoint_c' => centi_to_c(setpoint_raw),
        'setpoint_f' => centi_to_f(setpoint_raw),
        'temperature_c' => temperature_c,
        'temperature_f' => c_to_f(temperature_c),

        'timer' => int(poll['timer']),
        'time_remaining_s' => remaining,
        'time_remaining_min' => (remaining / 60.0).round,

        'has_fan' => int(poll['feature_fan']),
        'has_light' => int(poll['feature_light']),
        'has_thermostat' => int(poll['feature_thermostat']),
        'has_power_vent' => int(poll['power_vent']),

        'error_count' => errors.length,
        'error_codes' => errors.join(','),
        'error_text' => describe_errors(errors),

        'serial' => poll['serial'].to_s,
        'firmware' => poll['fw_ver_str'].to_s,
        'ip' => poll['ipv4_address'].to_s,
        'uptime' => int(poll['uptime']),

        'age_ms' => age_ms.to_i,
        'poll_errors' => poll_errors.to_i
      }
    end

    # Shape-compatible with a real status so the Savant profile always has every
    # path available, even before the first successful poll.
    def offline(poll_errors = 0)
      {
        'ok' => 0,
        'online' => 0,
        'power' => 0, 'power_status' => 'OFF',
        'flame_height' => 0, 'flame_percent' => 0,
        'fan_speed' => 0, 'fan_percent' => 0,
        'light_level' => 0, 'light_percent' => 0,
        'pilot' => 0, 'hot' => 0, 'prepurge' => 0,
        'thermostat' => 0,
        'setpoint_raw' => 0, 'setpoint_c' => 0, 'setpoint_f' => 32,
        'temperature_c' => 0, 'temperature_f' => 32,
        'timer' => 0, 'time_remaining_s' => 0, 'time_remaining_min' => 0,
        'has_fan' => 0, 'has_light' => 0, 'has_thermostat' => 0, 'has_power_vent' => 0,
        'error_count' => 0, 'error_codes' => '', 'error_text' => 'Fireplace unreachable',
        'serial' => '', 'firmware' => '', 'ip' => '', 'uptime' => 0,
        'age_ms' => 0, 'poll_errors' => poll_errors.to_i
      }
    end

    # A 0..steps level as a 0-100 percentage, for Savant's dimmer slider.
    def to_percent(level, steps)
      return 0 if steps.zero?

      (clamp(level, 0, steps) * 100.0 / steps).round
    end

    # Inverse of to_percent: a 0-100 slider position back to a 0..steps level.
    def from_percent(percent, steps)
      clamp((clamp(percent, 0, 100) * steps / 100.0).round, 0, steps)
    end

    def describe_errors(codes)
      return 'None' if codes.empty?

      codes.map { |code| ERROR_CODES.fetch(code, "Unknown (#{code})") }.uniq.join(', ')
    end

    # The module reports setpoint in hundredths of a degree Celsius (2200 =
    # 22.00 C). A value below one whole degree means the thermostat is off or
    # has never been set, which reads better as 0 than as 0.17 C.
    def centi_to_c(raw)
      raw < 100 ? 0 : (raw / 100.0).round
    end

    def centi_to_f(raw)
      raw < 100 ? 32 : (raw / 100.0 * 9 / 5 + 32).round
    end

    def c_to_f(celsius)
      (celsius * 9.0 / 5 + 32).round
    end

    def int(value)
      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      0
    end

    def clamp(value, low, high)
      [[value, low].max, high].min
    end
  end
end
