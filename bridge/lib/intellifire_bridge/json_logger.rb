require 'json'
require 'time'

module IntellifireBridge
  # Structured (JSON lines) logger. launchd redirects stdout to a file, so a
  # line-oriented machine-parseable format keeps the log greppable.
  class JsonLogger
    LEVELS = %i[debug info warn error].freeze

    def initialize(io = $stdout, level: :info)
      @io = io
      @mutex = Mutex.new
      @level = LEVELS.index(level) || 1
    end

    LEVELS.each do |level|
      define_method(level) do |event, fields = {}|
        log(level, event, fields)
      end
    end

    private

    def log(level, event, fields)
      return if LEVELS.index(level) < @level

      line = { ts: Time.now.utc.iso8601(3), level: level, event: event }.merge(fields).to_json
      @mutex.synchronize { @io.puts(line) }
    rescue IOError
      # Logging must never take the bridge down.
    end
  end
end
