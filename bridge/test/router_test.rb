require 'test_helper'

class RouterTest < Minitest::Test
  def setup
    @router, @client, @poller = build_stack
  end

  def get(path)
    @router.call('GET', path)
  end

  def test_status_and_root_both_return_the_status_document
    status, body = get('/status')
    assert_equal 200, status
    assert_equal 1, body['ok']
    assert_equal 'BD0E054B5D6DF7AFBC8F9B28C9011111', body['serial']
    assert_equal body, get('/')[1]
  end

  def test_health_reports_control_readiness
    status, body = get('/health')
    assert_equal 200, status
    assert_equal 1, body['canControl']
    assert_equal IntellifireBridge::VERSION, body['version']
  end

  def test_power_accepts_words_and_digits
    get('/power/on')
    get('/power/1')
    get('/power/off')
    get('/power/false')
    assert_equal [['power', 1], ['power', 1], ['power', 0], ['power', 0]], @client.sent
  end

  def test_power_toggle_uses_current_state
    get('/power/toggle')
    assert_equal [['power', 1]], @client.sent # fixture is off

    @client.poll_data = FakeClient.default_poll.merge('power' => 1)
    @poller.poll_once
    get('/power/toggle')
    assert_equal ['power', 0], @client.sent.last
  end

  def test_flame_absolute_levels
    get('/flame/2')
    assert_equal ['flame_height', 2], @client.sent.last

    get('/flame/off')
    assert_equal ['flame_height', 0], @client.sent.last

    get('/flame/max')
    assert_equal ['flame_height', 4], @client.sent.last
  end

  def test_relative_steps_clamp_at_the_ends
    # Fixture height is 4, so up clamps rather than overflowing.
    get('/flame/up')
    assert_equal ['flame_height', 4], @client.sent.last

    get('/light/percent/0') # light -> 0
    get('/light/down')
    assert_equal ['light', 0], @client.sent.last
  end

  def test_relative_steps_follow_the_optimistic_overlay
    get('/flame/down') # 4 -> 3, recorded optimistically
    get('/flame/down') # must see 3, not the still-stale polled 4
    assert_equal [['flame_height', 3], ['flame_height', 2]], @client.sent
  end

  def test_percent_routes_map_onto_device_levels
    get('/flame/percent/60')
    assert_equal ['flame_height', 2], @client.sent.last

    get('/light/percent/100')
    assert_equal ['light', 3], @client.sent.last
  end

  # The shape Savant's DimmerSet action produces: /dimmer/<Address1>/<0-100>.
  def test_dimmer_channels_by_savant_address
    get('/dimmer/1/50')
    assert_equal ['flame_height', 2], @client.sent.last

    get('/dimmer/2/100')
    assert_equal ['light', 3], @client.sent.last

    get('/dimmer/flame/0')
    assert_equal ['flame_height', 0], @client.sent.last
  end

  def test_unknown_dimmer_channel_is_a_client_error
    status, body = get('/dimmer/9/50')
    assert_equal 400, status
    assert_equal 0, body['ok']
    assert_empty @client.sent
  end

  def test_thermostat_units
    get('/thermostat/c/22')
    assert_equal ['thermostat_setpoint', 2200], @client.sent.last

    get('/thermostat/f/72')
    assert_equal ['thermostat_setpoint', 2200], @client.sent.last

    get('/thermostat/raw/1850')
    assert_equal ['thermostat_setpoint', 1850], @client.sent.last

    get('/thermostat/off')
    assert_equal ['thermostat_setpoint', 0], @client.sent.last
  end

  def test_thermostat_steps_by_one_fahrenheit_degree
    get('/thermostat/up') # fixture setpoint 2200 == 72 F
    assert_equal ['thermostat_setpoint', 2300], @client.sent.last
  end

  def test_thermostat_rejects_values_outside_the_safe_range
    status, = get('/thermostat/c/95')
    assert_equal 400, status
    assert_empty @client.sent
  end

  # Savant's Climate tile sends one mode; the appliance needs two commands for
  # it, because power and thermostat are independent there.
  def test_hvac_modes_map_onto_power_and_thermostat
    get('/hvac/off')
    assert_equal ['thermostat_setpoint', 0], @client.sent[-2]
    assert_equal %w[power].push(0), @client.sent.last

    @client.sent.clear
    get('/hvac/heat') # ignite and hold the setpoint already on the appliance
    assert_equal %w[power].push(1), @client.sent[-2]
    assert_equal ['thermostat_setpoint', 2200], @client.sent.last
  end

  # Savant's Auto implies cooling, so the profile no longer sends it — but any
  # button bound to it before the change must keep working.
  def test_auto_is_an_alias_for_heat
    get('/hvac/auto')
    assert_equal %w[power].push(1), @client.sent[-2]
    assert_equal ['thermostat_setpoint', 2200], @client.sent.last
  end

  # Off zeroes the setpoint on the appliance, so the bridge keeps a copy.
  # Returning to Heat must restore the chosen temperature, not a default.
  def test_heat_restores_the_setpoint_that_off_cleared
    get('/hvac/off') # fixture setpoint 2200 == 72 F, now zeroed
    @client.sent.clear

    get('/hvac/heat')
    assert_equal ['thermostat_setpoint', 2200], @client.sent.last
  end

  def test_hvac_rejects_an_unknown_mode
    status, = get('/hvac/cool')
    assert_equal 400, status
    assert_empty @client.sent
  end

  def test_timer_is_specified_in_minutes
    get('/timer/45')
    assert_equal ['time_remaining', 2700], @client.sent.last

    get('/timer/off')
    assert_equal ['time_remaining', 0], @client.sent.last
  end

  def test_timer_rejects_more_than_three_hours
    status, = get('/timer/240')
    assert_equal 400, status
    assert_empty @client.sent
  end

  def test_pilot_beep_and_soft_reset
    get('/pilot/on')
    get('/beep')
    get('/soft_reset')
    assert_equal [['pilot', 1], ['beep', 1], ['soft_reset', 1]], @client.sent
  end

  def test_unknown_route_is_404
    status, body = get('/nope')
    assert_equal 404, status
    assert_equal 0, body['ok']
  end

  def test_non_integer_level_is_rejected
    status, = get('/flame/hot')
    assert_equal 400, status
    assert_empty @client.sent
  end

  def test_out_of_range_level_is_rejected_before_reaching_the_device
    status, = get('/light/7')
    assert_equal 400, status
    assert_empty @client.sent
  end

  # An error response still carries the full status document, so the Savant
  # profile's single parser keeps working even when a command fails.
  def test_error_responses_still_carry_status_fields
    _, body = get('/flame/hot')
    assert body.key?('power_status')
    assert body.key?('error')
  end

  def test_read_only_bridge_refuses_commands
    router, client, = build_stack(can_control: false)
    status, body = router.call('GET', '/power/on')
    assert_equal 502, status
    assert_equal 0, body['ok']
    assert_empty client.sent
  end

  def test_delete_is_not_allowed
    assert_equal 405, @router.call('DELETE', '/power/on').first
  end
end
