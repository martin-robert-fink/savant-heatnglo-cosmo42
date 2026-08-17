require 'test_helper'

class PollerTest < Minitest::Test
  def setup
    @now = Time.at(1_700_000_000)
    @client = FakeClient.new
    @poller = IntellifireBridge::Poller.new(
      client: @client, overlay_ttl: 15.0, clock: -> { @now }
    )
  end

  def advance(seconds)
    @now += seconds
  end

  def test_status_before_any_poll_is_the_offline_document
    status = @poller.status
    assert_equal 0, status['ok']
    assert_equal 0, status['online']
  end

  def test_poll_failure_marks_offline_and_counts
    @client.poll_error = IntellifireBridge::Client::Unreachable.new('boom')
    refute @poller.poll_once
    refute @poller.poll_once

    status = @poller.status
    assert_equal 0, status['online']
    assert_equal 2, status['poll_errors']
  end

  # The appliance takes a beat to reflect a command in /poll. Without the
  # overlay the Pro App would snap back to the old value between the tap and
  # the next poll.
  def test_optimistic_overlay_masks_stale_poll_data
    @poller.poll_once
    assert_equal 0, @poller.status['power']

    @poller.record_optimistic('power', 1)
    assert_equal 1, @poller.status['power']
    assert_equal 'ON', @poller.status['power_status']
  end

  def test_overlay_expires_so_a_failed_command_cannot_lie_forever
    @poller.poll_once
    @poller.record_optimistic('power', 1)
    assert_equal 1, @poller.status['power']

    advance(16)
    assert_equal 0, @poller.status['power']
  end

  # Once the device agrees, the overlay must be dropped — otherwise a later
  # change made at the fireplace's own control panel would stay masked.
  def test_overlay_clears_once_the_device_agrees
    @poller.poll_once
    @poller.record_optimistic('power', 1)

    @client.poll_data = FakeClient.default_poll.merge('power' => 1)
    @poller.poll_once
    assert_equal 1, @poller.status['power']

    @client.poll_data = FakeClient.default_poll.merge('power' => 0)
    @poller.poll_once
    assert_equal 0, @poller.status['power'], 'stale overlay masked a real change'
  end

  def test_setpoint_overlay_also_flips_the_thermostat_flag
    @poller.poll_once
    @poller.record_optimistic('thermostat_setpoint', 0)
    assert_equal 0, @poller.status['thermostat']

    @poller.record_optimistic('thermostat_setpoint', 2100)
    assert_equal 1, @poller.status['thermostat']
    assert_equal 21, @poller.status['setpoint_c']
  end

  def test_timer_overlay_also_flips_the_timer_flag
    @poller.poll_once
    @poller.record_optimistic('time_remaining', 1800)
    assert_equal 1, @poller.status['timer']
    assert_equal 30, @poller.status['time_remaining_min']
  end

  def test_commands_without_a_poll_field_are_not_overlaid
    @poller.poll_once
    before = @poller.status
    @poller.record_optimistic('beep', 1)
    assert_equal before, @poller.status
  end

  def test_field_reads_through_the_overlay
    @poller.poll_once
    assert_equal 4, @poller.field('height')

    @poller.record_optimistic('flame_height', 1)
    assert_equal 1, @poller.field('height')
  end

  def test_background_thread_starts_and_stops_cleanly
    poller = IntellifireBridge::Poller.new(client: @client, interval: 0.05)
    poller.start
    sleep 0.15
    assert_equal 1, poller.status['ok']
    poller.stop
  end
end
