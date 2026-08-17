require 'digest'
require 'json'
require 'net/http'
require 'uri'

module IntellifireBridge
  # Speaks the IntelliFire Wi-Fi module's local HTTP API.
  #
  #   GET  /poll           -> JSON device state (no authentication)
  #   GET  /get_challenge  -> hex challenge string, valid ~10 seconds
  #   POST /post           -> command, signed against the challenge
  #
  # The signature is a two-round SHA-256 over the raw (hex-decoded) API key:
  #
  #   payload  = "post:command=<cmd>&value=<val>"
  #   inner    = SHA256(api_key_bytes + challenge_bytes + payload_bytes)
  #   response = SHA256(api_key_bytes + inner).hexdigest
  #
  # This is the reason the bridge exists at all: a Savant component profile can
  # append CRC-16/XOR/Fletcher checksums but has no SHA-256 primitive, so it
  # cannot sign these commands itself.
  class Client
    class Error < StandardError; end
    class Unreachable < Error; end
    class InvalidChallenge < Error; end
    class CommandFailed < Error; end

    # command name => inclusive value range, mirroring the ranges the
    # IntelliFire app itself enforces.
    COMMANDS = {
      'power' => (0..1),
      'pilot' => (0..1),
      'beep' => (1..1),
      'light' => (0..3),
      'flame_height' => (0..4),
      'fan_speed' => (0..4),
      'thermostat_setpoint' => (0..3700),
      'time_remaining' => (0..10_800),
      'soft_reset' => (1..1)
    }.freeze

    HEX = /\A[0-9a-fA-F]+\z/.freeze

    # port is configurable only so the bridge can be exercised against a stub;
    # the Wi-Fi module itself always listens on 80.
    def initialize(ip:, api_key: '', user_id: '', timeout: 5.0, retries: 6, logger: nil, port: 80)
      @ip = ip
      @port = port
      @api_key = api_key.to_s.strip
      @user_id = user_id.to_s.strip
      @timeout = timeout
      @retries = retries
      @logger = logger
    end

    # Raw poll data straight from the appliance, as a Hash with string keys.
    def poll
      response = get('/poll')
      unless response.is_a?(Net::HTTPSuccess)
        raise Unreachable, "poll returned HTTP #{response.code}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Unreachable, "poll returned unparseable JSON: #{e.message}"
    end

    # Send one command. Retries because the challenge expires after roughly ten
    # seconds and the module rejects a stale one with 403.
    def send_command(command, value)
      range = COMMANDS[command]
      raise ArgumentError, "unknown command: #{command}" if range.nil?
      unless range.cover?(value)
        raise ArgumentError,
              "#{command} value #{value} out of range #{range.min}-#{range.max}"
      end
      raise CommandFailed, 'api_key and user_id are required to control the fireplace' if credentials_missing?

      last_error = nil

      @retries.times do |attempt|
        begin
          challenge = fetch_challenge
          body = signed_body(command, value, challenge)
          response = post('/post', body)

          return true if response.is_a?(Net::HTTPSuccess)

          # 403 means the challenge went stale between fetch and post; a fresh
          # challenge on the next pass usually fixes it.
          last_error = "HTTP #{response.code}"
          @logger&.warn(:command_rejected, command: command, value: value,
                                           status: response.code, attempt: attempt + 1)
        rescue Unreachable, InvalidChallenge => e
          last_error = e.message
          @logger&.warn(:command_retry, command: command, value: value,
                                        error: e.message, attempt: attempt + 1)
        end
      end

      raise CommandFailed, "#{command}=#{value} failed after #{@retries} attempts (#{last_error})"
    end

    def credentials_missing?
      @api_key.empty? || @user_id.empty?
    end

    # Exposed separately so it can be unit-tested against known vectors.
    def self.signature(api_key:, challenge:, command:, value:)
      unless api_key.to_s.match?(HEX) && challenge.to_s.match?(HEX)
        raise InvalidChallenge, 'api_key and challenge must both be hex strings'
      end

      api_bytes = [api_key].pack('H*')
      challenge_bytes = [challenge].pack('H*')
      payload = "post:command=#{command}&value=#{value}".b

      inner = Digest::SHA256.digest(api_bytes + challenge_bytes + payload)
      Digest::SHA256.hexdigest(api_bytes + inner)
    end

    private

    def fetch_challenge
      response = get('/get_challenge')
      unless response.is_a?(Net::HTTPSuccess)
        raise Unreachable, "get_challenge returned HTTP #{response.code}"
      end

      challenge = response.body.to_s.strip
      raise InvalidChallenge, "challenge is not hex: #{challenge.inspect}" unless challenge.match?(HEX)

      challenge
    end

    def signed_body(command, value, challenge)
      response = self.class.signature(
        api_key: @api_key, challenge: challenge, command: command, value: value
      )
      "command=#{command}&value=#{value}&user=#{@user_id}&response=#{response}"
    end

    def get(path)
      request(Net::HTTP::Get.new(path))
    end

    def post(path, body)
      request = Net::HTTP::Post.new(path)
      request['Content-Type'] = 'application/x-www-form-urlencoded'
      request.body = body
      request(request)
    end

    def request(request)
      http = Net::HTTP.new(@ip, @port)
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.start { |session| session.request(request) }
    rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
           Errno::ENETUNREACH, SocketError, IOError => e
      raise Unreachable, "#{e.class.name}: #{e.message}"
    end
  end
end
