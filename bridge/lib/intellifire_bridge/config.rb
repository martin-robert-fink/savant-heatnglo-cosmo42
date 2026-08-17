require 'json'

module IntellifireBridge
  # Configuration comes from environment variables (so the launchd plist is the
  # single place operational settings live) plus an optional credentials file
  # (so the API key never has to sit in the plist).
  #
  # Environment always wins over the credentials file.
  Config = Struct.new(
    :fireplace_ip,
    :fireplace_port,
    :api_key,
    :user_id,
    :serial,
    :port,
    :bind,
    :poll_interval,
    :http_timeout,
    :command_retries,
    :overlay_ttl,
    :log_level,
    keyword_init: true
  ) do
    DEFAULT_CREDENTIALS_PATH = '/Users/Shared/intellifire-bridge/credentials.json'.freeze

    class << self
      def from_env(env = ENV)
        creds = load_credentials(env['INTELLIFIRE_CREDENTIALS'] || DEFAULT_CREDENTIALS_PATH)

        new(
          fireplace_ip: pick(env, 'INTELLIFIRE_IP', creds, 'ip_address').to_s.strip,
          fireplace_port: Integer(env.fetch('INTELLIFIRE_PORT', '80')),
          api_key: pick(env, 'INTELLIFIRE_API_KEY', creds, 'api_key').to_s.strip,
          user_id: pick(env, 'INTELLIFIRE_USER_ID', creds, 'user_id').to_s.strip,
          serial: pick(env, 'INTELLIFIRE_SERIAL', creds, 'serial').to_s.strip,
          port: Integer(env.fetch('INTELLIFIRE_BRIDGE_PORT', '4568')),
          bind: env.fetch('INTELLIFIRE_BRIDGE_BIND', '0.0.0.0'),
          poll_interval: Float(env.fetch('INTELLIFIRE_POLL_INTERVAL', '5.0')),
          http_timeout: Float(env.fetch('INTELLIFIRE_HTTP_TIMEOUT', '5.0')),
          command_retries: Integer(env.fetch('INTELLIFIRE_COMMAND_RETRIES', '6')),
          overlay_ttl: Float(env.fetch('INTELLIFIRE_OVERLAY_TTL', '15.0')),
          log_level: env.fetch('INTELLIFIRE_LOG_LEVEL', 'info').downcase.to_sym
        )
      end

      # A missing or unreadable credentials file is not an error — the values
      # may all be supplied through the environment instead.
      def load_credentials(path)
        return {} if path.nil? || path.empty? || !File.readable?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      private

      def pick(env, env_key, creds, creds_key)
        value = env[env_key]
        return value unless value.nil? || value.empty?

        creds[creds_key]
      end
    end

    # Polling only needs the IP; control additionally needs the key and user id.
    def missing_for_polling
      fireplace_ip.to_s.empty? ? ['fireplace IP (INTELLIFIRE_IP)'] : []
    end

    def missing_for_control
      missing = missing_for_polling
      missing << 'API key (INTELLIFIRE_API_KEY)' if api_key.to_s.empty?
      missing << 'user id (INTELLIFIRE_USER_ID)' if user_id.to_s.empty?
      missing
    end

    def can_control?
      missing_for_control.empty?
    end
  end
end
