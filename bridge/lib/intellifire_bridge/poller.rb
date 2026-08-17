require 'monitor'

module IntellifireBridge
  # Owns the single background poll loop and the cached view of the fireplace.
  #
  # Savant polls this bridge every few seconds, and other clients may too. The
  # appliance's little Wi-Fi module should not field all of that, so exactly one
  # thread talks to it and everyone else reads the cache.
  #
  # Commands take a moment to show up in /poll, so an accepted command writes an
  # "optimistic overlay" for the field it changed. The overlay is applied on top
  # of cached poll data until either a later poll agrees with it or it expires —
  # which keeps the Pro App from snapping back to the old value for a beat after
  # a tap.
  class Poller
    # Which raw /poll field each command moves, and any companion field that
    # follows from it.
    COMMAND_FIELDS = {
      'power' => ['power'],
      'flame_height' => ['height'],
      'fan_speed' => ['fanspeed'],
      'light' => ['light'],
      'pilot' => ['pilot'],
      'thermostat_setpoint' => %w[setpoint thermostat],
      'time_remaining' => %w[timeremaining timer]
    }.freeze

    def initialize(client:, interval: 5.0, overlay_ttl: 15.0, logger: nil, clock: -> { Time.now })
      @client = client
      @interval = interval
      @overlay_ttl = overlay_ttl
      @logger = logger
      @clock = clock

      @lock = Monitor.new
      @wake = @lock.new_cond
      @poll = nil
      @polled_at = nil
      @online = false
      @poll_errors = 0
      @overlay = {}
      @thread = nil
      @running = false
    end

    def start
      @lock.synchronize do
        return if @running

        @running = true
      end
      @thread = Thread.new { loop_forever }
      @thread.abort_on_exception = false
      self
    end

    def stop
      @lock.synchronize do
        @running = false
        @wake.broadcast
      end
      @thread&.join(2)
      self
    end

    # The flat document the Savant profile parses.
    def status
      @lock.synchronize do
        Status.build(
          poll: merged_poll,
          online: @online,
          age_ms: @polled_at ? ((@clock.call - @polled_at) * 1000).round : 0,
          poll_errors: @poll_errors
        )
      end
    end

    # Current level of a raw poll field, used to implement relative
    # (up/down) commands against the freshest value we have.
    def field(name, default = 0)
      @lock.synchronize do
        raw = merged_poll
        raw.nil? ? default : Status.int(raw.fetch(name, default))
      end
    end

    def record_optimistic(command, value)
      fields = COMMAND_FIELDS[command]
      return if fields.nil?

      expires = @clock.call + @overlay_ttl
      @lock.synchronize do
        fields.each do |name|
          @overlay[name] = { value: companion_value(name, command, value), expires: expires }
        end
      end
    end

    # Ask the poll loop to refresh sooner than its normal cadence — used right
    # after a command so the cache catches up quickly.
    def refresh_soon(delay = 2.0)
      Thread.new do
        sleep(delay)
        poll_once
      rescue StandardError => e
        @logger&.warn(:refresh_failed, error: e.message)
      end
      nil
    end

    def poll_once
      data = @client.poll
      @lock.synchronize do
        @poll = data
        @polled_at = @clock.call
        @online = true
        @poll_errors = 0
        reconcile_overlay(data)
      end
      true
    rescue Client::Unreachable, Client::Error => e
      @lock.synchronize do
        @online = false
        @poll_errors += 1
        # Log the first failure and then every tenth, so a fireplace that is
        # simply powered down overnight does not fill the log.
        @logger&.warn(:poll_failed, error: e.message, consecutive: @poll_errors) \
          if @poll_errors == 1 || (@poll_errors % 10).zero?
      end
      false
    end

    private

    def loop_forever
      while running?
        poll_once
        @lock.synchronize { @wake.wait(@interval) if @running }
      end
    end

    def running?
      @lock.synchronize { @running }
    end

    # Caller must hold the lock.
    def merged_poll
      return nil if @poll.nil?

      now = @clock.call
      active = @overlay.reject { |_, entry| entry[:expires] <= now }
      return @poll if active.empty?

      @poll.merge(active.transform_values { |entry| entry[:value] })
    end

    # Caller must hold the lock. Drop overlay entries the appliance has caught
    # up with, and expire the rest on schedule.
    def reconcile_overlay(data)
      now = @clock.call
      @overlay.reject! do |name, entry|
        entry[:expires] <= now || Status.int(data[name]) == Status.int(entry[:value])
      end
    end

    # `thermostat` and `timer` are on/off flags derived from the value written
    # to their companion field.
    def companion_value(name, command, value)
      case name
      when 'thermostat' then command == 'thermostat_setpoint' && value.positive? ? 1 : 0
      when 'timer' then command == 'time_remaining' && value.positive? ? 1 : 0
      else value
      end
    end
  end
end
