require 'test_helper'

class StatusTest < Minitest::Test
  Status = IntellifireBridge::Status

  def build(overrides = {})
    Status.build(poll: FakeClient.default_poll.merge(overrides), online: true, age_ms: 100)
  end

  # The Savant JSON parser addresses scalars by path. Anything nested, any
  # array, or any JSON boolean in this document would be unreachable from the
  # profile — so the shape itself is part of the contract.
  def test_document_is_flat_scalars_only
    build.each do |key, value|
      assert_kind_of String, key
      assert(value.is_a?(Integer) || value.is_a?(String),
             "#{key} is #{value.class}, must be Integer or String")
    end
  end

  def test_power_is_mirrored_as_integer_and_savant_binding_string
    assert_equal 1, build('power' => 1)['power']
    assert_equal 'ON', build('power' => 1)['power_status']
    assert_equal 0, build('power' => 0)['power']
    assert_equal 'OFF', build('power' => 0)['power_status']
  end

  def test_levels_convert_to_slider_percentages
    assert_equal 0, build('height' => 0)['flame_percent']
    assert_equal 50, build('height' => 2)['flame_percent']
    assert_equal 100, build('height' => 4)['flame_percent']

    assert_equal 0, build('light' => 0)['light_percent']
    assert_equal 33, build('light' => 1)['light_percent']
    assert_equal 100, build('light' => 3)['light_percent']
  end

  def test_percentages_round_trip_back_to_levels
    (0..4).each { |level| assert_equal level, Status.from_percent(Status.to_percent(level, 4), 4) }
    (0..3).each { |level| assert_equal level, Status.from_percent(Status.to_percent(level, 3), 3) }
  end

  def test_from_percent_clamps_out_of_range_input
    assert_equal 0, Status.from_percent(-20, 4)
    assert_equal 4, Status.from_percent(150, 4)
  end

  def test_out_of_range_levels_are_clamped_not_propagated
    assert_equal 4, build('height' => 9)['flame_height']
    assert_equal 0, build('light' => -3)['light_level']
  end

  # The module reports setpoint in hundredths of a degree Celsius.
  def test_setpoint_scales_from_hundredths_of_a_degree
    status = build('setpoint' => 2200)
    assert_equal 2200, status['setpoint_raw']
    assert_equal 22, status['setpoint_c']
    assert_equal 72, status['setpoint_f']
  end

  # Some units report a nonsense sub-degree setpoint when the thermostat has
  # never been used; 0 reads better than 0.17 C.
  def test_unset_setpoint_reads_as_zero
    status = build('setpoint' => 17)
    assert_equal 0, status['setpoint_c']
    assert_equal 32, status['setpoint_f']
  end

  def test_errors_collapse_to_string_and_count
    status = build('errors' => [2, 133])
    assert_equal 2, status['error_count']
    assert_equal '2,133', status['error_codes']
    assert_equal 'Pilot Flame, Lights', status['error_text']
  end

  def test_no_errors_reads_as_none
    status = build('errors' => [])
    assert_equal 0, status['error_count']
    assert_equal 'None', status['error_text']
  end

  def test_unknown_error_codes_are_reported_not_dropped
    assert_equal 'Unknown (999)', build('errors' => [999])['error_text']
  end

  # Cloud-shaped payloads deliver every field as a string; the same profile
  # paths must still yield integers.
  def test_string_valued_fields_are_coerced
    status = build('power' => '1', 'height' => '3', 'setpoint' => '2100')
    assert_equal 1, status['power']
    assert_equal 3, status['flame_height']
    assert_equal 21, status['setpoint_c']
  end

  # The Climate tile has one mode where the appliance has two flags.
  def test_hvac_mode_collapses_power_and_thermostat
    off = build('power' => 0, 'thermostat' => 0)
    assert_equal 'Off', off['hvac_mode']
    assert_equal [1, 0, 0], off.values_at('hvac_mode_off', 'hvac_mode_heat', 'hvac_mode_auto')

    heat = build('power' => 1, 'thermostat' => 0)
    assert_equal 'Heat', heat['hvac_mode']
    assert_equal [0, 1, 0], heat.values_at('hvac_mode_off', 'hvac_mode_heat', 'hvac_mode_auto')

    # Thermostat wins: burning under thermostat control is Auto, not Heat.
    auto = build('power' => 1, 'thermostat' => 1)
    assert_equal 'Auto', auto['hvac_mode']
    assert_equal [0, 0, 1], auto.values_at('hvac_mode_off', 'hvac_mode_heat', 'hvac_mode_auto')
  end

  # Before the first successful poll the profile still needs every path to
  # exist, or its state variables never initialize.
  def test_offline_document_has_the_same_keys_as_a_live_one
    assert_equal build.keys.sort, Status.offline.keys.sort
    assert_equal 0, Status.offline['ok']
    assert_equal 'Fireplace unreachable', Status.offline['error_text']
  end
end
