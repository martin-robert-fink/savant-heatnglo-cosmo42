module IntellifireBridge
  # The seam between the router and the hardware: sends commands through the
  # Client, then keeps the Poller's cache honest about what just happened.
  class Controller
    def initialize(client:, poller:, config:, logger: nil)
      @client = client
      @poller = poller
      @config = config
      @logger = logger
    end

    def status
      @poller.status
    end

    def field(name, default = 0)
      @poller.field(name, default)
    end

    def health
      {
        'online' => status['online'],
        'canControl' => @config.can_control? ? 1 : 0,
        'fireplaceIp' => @config.fireplace_ip,
        'pollInterval' => @config.poll_interval
      }
    end

    def send_command(command, value)
      unless @config.can_control?
        raise Client::CommandFailed,
              "bridge is not configured for control (missing: #{@config.missing_for_control.join(', ')})"
      end

      @client.send_command(command, value)
      @logger&.info(:command, command: command, value: value)

      # Show the new value immediately, then confirm it against the appliance.
      @poller.record_optimistic(command, value)
      @poller.refresh_soon
      true
    end
  end
end
