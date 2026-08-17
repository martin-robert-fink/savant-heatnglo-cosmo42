$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'minitest/autorun'
require 'intellifire_bridge'

# A stand-in for the fireplace: records what was sent and replays canned poll
# data, so the router and poller can be exercised without hardware.
class FakeClient
  attr_reader :sent
  attr_accessor :poll_data, :poll_error

  def initialize(poll_data: FakeClient.default_poll)
    @poll_data = poll_data
    @sent = []
    @poll_error = nil
  end

  def poll
    raise @poll_error if @poll_error

    @poll_data
  end

  def send_command(command, value)
    @sent << [command, value]
    true
  end

  def credentials_missing?
    false
  end

  def self.default_poll
    {
      'battery' => 0, 'connection_quality' => 995_871, 'downtime' => 3,
      'ecm_latency' => 0, 'errors' => [], 'fanspeed' => 1,
      'feature_fan' => 1, 'feature_light' => 1, 'feature_thermostat' => 1,
      'fw_ver_str' => '1.3.0', 'fw_version' => '0x01030000',
      'height' => 4, 'hot' => 0, 'ipv4_address' => '192.168.1.69',
      'light' => 3, 'name' => '', 'pilot' => 0, 'power' => 0,
      'power_vent' => 0, 'prepurge' => 0,
      'serial' => 'BD0E054B5D6DF7AFBC8F9B28C9011111',
      'setpoint' => 2200, 'temperature' => 17, 'thermostat' => 1,
      'timer' => 0, 'timeremaining' => 0, 'uptime' => 3362
    }
  end
end

def build_stack(poll_data: FakeClient.default_poll, can_control: true, clock: -> { Time.now })
  client = FakeClient.new(poll_data: poll_data)
  config = IntellifireBridge::Config.new(
    fireplace_ip: '10.0.0.9',
    api_key: can_control ? 'AABB' : '',
    user_id: can_control ? '1234' : '',
    port: 4568, bind: '127.0.0.1', poll_interval: 5.0, http_timeout: 5.0,
    command_retries: 3, overlay_ttl: 15.0, log_level: :error
  )
  poller = IntellifireBridge::Poller.new(client: client, clock: clock)
  poller.poll_once
  controller = IntellifireBridge::Controller.new(client: client, poller: poller, config: config)
  [IntellifireBridge::Router.new(controller: controller), client, poller]
end
