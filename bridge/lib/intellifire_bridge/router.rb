require 'uri'

module IntellifireBridge
  # Pure request router: (method, path) in, [status, hash] out. No sockets, so
  # it is fully testable off-host; Server is a thin shell around it.
  #
  # Every route answers with the same flat status document (plus `ok`), so the
  # Savant profile needs exactly one JSON parser for both polling and command
  # acknowledgements. Commands are reachable by GET on purpose: Savant's HTTP
  # control interface builds a URL far more readily than a form body, and the
  # bridge is a LAN-local appliance gateway, not a public API.
  class Router
    # Savant data-table Address1 -> which 0..N channel a DimmerSet drives.
    DIMMER_CHANNELS = {
      '1' => :flame, 'flame' => :flame,
      '2' => :light, 'light' => :light,
      '3' => :fan,   'fan' => :fan
    }.freeze

    CHANNELS = {
      flame: { command: 'flame_height', field: 'height', steps: Status::FLAME_STEPS },
      fan: { command: 'fan_speed', field: 'fanspeed', steps: Status::FLAME_STEPS },
      light: { command: 'light', field: 'light', steps: Status::LIGHT_STEPS }
    }.freeze

    ON_WORDS = %w[1 on true yes].freeze
    OFF_WORDS = %w[0 off false no].freeze

    MAX_TIMER_MINUTES = 180
    SETPOINT_MIN_C = 0
    SETPOINT_MAX_C = 37
    DEFAULT_SETPOINT_F = 68 # used when the thermostat has never been set

    def initialize(controller:, version: IntellifireBridge::VERSION, logger: nil)
      @controller = controller
      @version = version
      @logger = logger
    end

    def call(method, path)
      return [405, error_payload('method not allowed')] unless %w[GET POST].include?(method)

      segments = decode_path(path)
      head = segments.first
      rest = segments[1..] || []

      case head
      when nil, 'status' then ok(@controller.status)
      when 'health' then [200, { 'ok' => 1, 'version' => @version }.merge(@controller.health)]
      when 'power' then power(rest)
      when 'flame' then channel(:flame, rest)
      when 'fan' then channel(:fan, rest)
      when 'light' then channel(:light, rest)
      when 'dimmer' then dimmer(rest)
      when 'thermostat' then thermostat(rest)
      when 'hvac' then hvac(rest)
      when 'timer' then timer(rest)
      when 'pilot' then pilot(rest)
      when 'beep' then send_simple('beep', 1)
      when 'soft_reset' then send_simple('soft_reset', 1)
      else [404, error_payload("no route: #{method} #{path}")]
      end
    rescue ArgumentError => e
      [400, error_payload(e.message)]
    rescue Client::CommandFailed => e
      [502, error_payload(e.message)]
    rescue Client::Unreachable => e
      [504, error_payload(e.message)]
    rescue StandardError => e
      @logger&.error(:router_error, error: e.class.name, message: e.message)
      [500, error_payload("#{e.class.name}: #{e.message}")]
    end

    private

    def power(rest)
      word = rest.first.to_s.downcase
      value =
        if ON_WORDS.include?(word) then 1
        elsif OFF_WORDS.include?(word) then 0
        elsif word == 'toggle' then @controller.field('power').zero? ? 1 : 0
        else raise ArgumentError, "power expects on/off/toggle, got #{word.inspect}"
        end

      send_simple('power', value)
    end

    def pilot(rest)
      word = rest.first.to_s.downcase
      value =
        if ON_WORDS.include?(word) then 1
        elsif OFF_WORDS.include?(word) then 0
        else raise ArgumentError, "pilot expects on/off, got #{word.inspect}"
        end

      send_simple('pilot', value)
    end

    # /flame/3  /flame/up  /flame/down  /flame/off  /flame/percent/60
    def channel(name, rest)
      spec = CHANNELS.fetch(name)
      word = rest.first.to_s.downcase

      value =
        case word
        when 'percent' then Status.from_percent(integer(rest[1], "#{name} percent"), spec[:steps])
        when 'up' then Status.clamp(@controller.field(spec[:field]) + 1, 0, spec[:steps])
        when 'down' then Status.clamp(@controller.field(spec[:field]) - 1, 0, spec[:steps])
        when 'off' then 0
        when 'max' then spec[:steps]
        else
          level = integer(word, "#{name} level")
          unless (0..spec[:steps]).cover?(level)
            raise ArgumentError, "#{name} level must be 0-#{spec[:steps]}, got #{level}"
          end

          level
        end

      send_simple(spec[:command], value)
    end

    # /dimmer/<Address1>/<0-100> — the shape Savant's DimmerSet action posts.
    def dimmer(rest)
      channel_name = DIMMER_CHANNELS[rest.first.to_s.downcase]
      raise ArgumentError, "unknown dimmer channel: #{rest.first.inspect}" if channel_name.nil?

      spec = CHANNELS.fetch(channel_name)
      percent = integer(rest[1], 'dimmer level')
      send_simple(spec[:command], Status.from_percent(percent, spec[:steps]))
    end

    # /thermostat/off  /thermostat/up  /thermostat/down
    # /thermostat/c/22  /thermostat/f/72  /thermostat/raw/2200
    def thermostat(rest)
      word = rest.first.to_s.downcase

      raw =
        case word
        when 'off', '0' then 0
        when 'raw' then integer(rest[1], 'setpoint')
        when 'c' then c_to_raw(integer(rest[1], 'setpoint C'))
        when 'f' then f_to_raw(integer(rest[1], 'setpoint F'))
        when 'up' then step_setpoint(1)
        when 'down' then step_setpoint(-1)
        else raise ArgumentError, "thermostat expects off/up/down/c/f/raw, got #{word.inspect}"
        end

      unless (0..3700).cover?(raw)
        raise ArgumentError, "setpoint #{raw} out of range 0-3700 (hundredths of a degree C)"
      end

      send_simple('thermostat_setpoint', raw)
    end

    # /hvac/off  /hvac/heat  /hvac/auto
    #
    # The three modes Savant's Climate tile drives:
    #
    #   off   clear the setpoint, extinguish
    #   heat  burn now at whatever flame height is set, no thermostat
    #   auto  burn until the setpoint is met, at whatever setpoint the
    #         appliance already holds (68 F if it has never been set)
    #
    # Each mode is two appliance commands, because the appliance models power
    # and thermostat separately. The first goes through the controller
    # directly and the second through send_simple, so the status document
    # returned to Savant reflects both.
    def hvac(rest)
      word = rest.first.to_s.downcase

      case word
      when 'off'
        remember_setpoint
        @controller.send_command('thermostat_setpoint', 0)
        send_simple('power', 0)
      when 'heat'
        remember_setpoint
        @controller.send_command('thermostat_setpoint', 0)
        send_simple('power', 1)
      when 'auto'
        @controller.send_command('power', 1)
        send_simple('thermostat_setpoint', auto_setpoint)
      else raise ArgumentError, "hvac expects off/heat/auto, got #{word.inspect}"
      end
    end

    # Turning the thermostat off means zeroing its setpoint on the appliance,
    # which loses the number. Keep a copy so returning to Auto returns to the
    # temperature the user actually chose rather than a default.
    def remember_setpoint
      current = @controller.status['setpoint_f'].to_i
      @remembered_setpoint_f = current if current > 32
    end

    def auto_setpoint
      current = @controller.status['setpoint_f'].to_i
      return f_to_raw(current) if current > 32
      return f_to_raw(@remembered_setpoint_f) if @remembered_setpoint_f

      f_to_raw(DEFAULT_SETPOINT_F)
    end

    # /timer/45 (minutes)  /timer/off
    def timer(rest)
      word = rest.first.to_s.downcase
      minutes = OFF_WORDS.include?(word) ? 0 : integer(word, 'timer minutes')
      unless (0..MAX_TIMER_MINUTES).cover?(minutes)
        raise ArgumentError, "timer must be 0-#{MAX_TIMER_MINUTES} minutes, got #{minutes}"
      end

      send_simple('time_remaining', minutes * 60)
    end

    def send_simple(command, value)
      @controller.send_command(command, value)
      ok(@controller.status)
    end

    # One degree Fahrenheit at a time, which is what the app's arrows do.
    def step_setpoint(direction)
      current_f = @controller.status['setpoint_f'].to_i
      current_f = DEFAULT_SETPOINT_F if current_f <= 32 # thermostat was off; start somewhere sane
      f_to_raw(current_f + direction)
    end

    def c_to_raw(celsius)
      unless (SETPOINT_MIN_C..SETPOINT_MAX_C).cover?(celsius)
        raise ArgumentError, "setpoint must be #{SETPOINT_MIN_C}-#{SETPOINT_MAX_C} C, got #{celsius}"
      end

      celsius * 100
    end

    def f_to_raw(fahrenheit)
      celsius = ((fahrenheit - 32) * 5.0 / 9).round
      c_to_raw(Status.clamp(celsius, SETPOINT_MIN_C, SETPOINT_MAX_C))
    end

    def integer(token, label)
      Integer(token.to_s, 10)
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{label} must be an integer, got #{token.inspect}"
    end

    def ok(status)
      [200, status]
    end

    def error_payload(message)
      @controller.status.merge('ok' => 0, 'error' => message)
    rescue StandardError
      { 'ok' => 0, 'error' => message }
    end

    def decode_path(path)
      path.to_s.split('/')
          .reject(&:empty?)
          .map { |segment| URI.decode_www_form_component(segment) }
    end
  end
end
