require 'test_helper'

class ClientTest < Minitest::Test
  Client = IntellifireBridge::Client

  # Independently computed with the reference construction from
  # intellifire4py's IntelliFireAPILocal#_construct_payload:
  #   sha256(key + sha256(key + challenge + "post:command=power&value=1"))
  def test_signature_matches_reference_vector
    api_key = '12345BDB2D97B3DC7CEE8A8B05DD5FFA'
    challenge = 'ABCD1234'

    api_bytes = [api_key].pack('H*')
    challenge_bytes = [challenge].pack('H*')
    payload = 'post:command=power&value=1'.b
    expected = Digest::SHA256.hexdigest(
      api_bytes + Digest::SHA256.digest(api_bytes + challenge_bytes + payload)
    )

    actual = Client.signature(
      api_key: api_key, challenge: challenge, command: 'power', value: 1
    )

    assert_equal expected, actual
    assert_equal 64, actual.length
  end

  def test_signature_is_sensitive_to_every_input
    base = { api_key: 'AABBCCDD', challenge: '11223344', command: 'power', value: 1 }
    signature = Client.signature(**base)

    refute_equal signature, Client.signature(**base.merge(api_key: 'AABBCCDE'))
    refute_equal signature, Client.signature(**base.merge(challenge: '11223345'))
    refute_equal signature, Client.signature(**base.merge(command: 'pilot'))
    refute_equal signature, Client.signature(**base.merge(value: 0))
  end

  # A non-hex challenge would be silently truncated by pack('H*'), producing a
  # signature the appliance rejects with no useful diagnosis.
  def test_signature_rejects_non_hex_inputs
    assert_raises(Client::InvalidChallenge) do
      Client.signature(api_key: 'AABB', challenge: 'not-hex', command: 'power', value: 1)
    end

    assert_raises(Client::InvalidChallenge) do
      Client.signature(api_key: 'zzz', challenge: 'AABB', command: 'power', value: 1)
    end
  end

  def test_send_command_rejects_unknown_command
    client = Client.new(ip: '10.0.0.9', api_key: 'AABB', user_id: '1')
    assert_raises(ArgumentError) { client.send_command('explode', 1) }
  end

  def test_send_command_enforces_documented_ranges
    client = Client.new(ip: '10.0.0.9', api_key: 'AABB', user_id: '1')

    assert_raises(ArgumentError) { client.send_command('flame_height', 5) }
    assert_raises(ArgumentError) { client.send_command('light', 4) }
    assert_raises(ArgumentError) { client.send_command('thermostat_setpoint', 3701) }
    assert_raises(ArgumentError) { client.send_command('power', -1) }
  end

  def test_send_command_without_credentials_fails_fast
    client = Client.new(ip: '10.0.0.9')
    assert client.credentials_missing?
    assert_raises(Client::CommandFailed) { client.send_command('power', 1) }
  end
end
