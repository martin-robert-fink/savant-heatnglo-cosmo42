require 'webrick'
require 'json'

module IntellifireBridge
  # Thin WEBrick shell around Router. All routing logic lives in Router so it
  # can be tested without sockets.
  class Server
    def initialize(config, logger: nil)
      @config = config
      @logger = logger || JsonLogger.new(level: config.log_level)

      @client = Client.new(
        ip: config.fireplace_ip,
        port: config.fireplace_port || 80,
        api_key: config.api_key,
        user_id: config.user_id,
        timeout: config.http_timeout,
        retries: config.command_retries,
        logger: @logger
      )
      @poller = Poller.new(
        client: @client,
        interval: config.poll_interval,
        overlay_ttl: config.overlay_ttl,
        logger: @logger
      )
      controller = Controller.new(
        client: @client, poller: @poller, config: config, logger: @logger
      )
      @router = Router.new(controller: controller, logger: @logger)
    end

    def start
      @poller.start

      server = WEBrick::HTTPServer.new(
        BindAddress: @config.bind,
        Port: @config.port,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )

      router = @router
      logger = @logger
      server.mount_proc('/') do |req, res|
        status, payload = router.call(req.request_method, req.path)
        res.status = status
        res['Content-Type'] = 'application/json'
        # Savant re-reads this on every poll; nothing here should ever be cached.
        res['Cache-Control'] = 'no-store'
        res.body = JSON.generate(payload)
        logger.debug(:request, method: req.request_method, path: req.path, status: status)
      end

      %w[INT TERM].each { |sig| trap(sig) { server.shutdown } }

      @logger.info(:started,
                   port: @config.port,
                   bind: @config.bind,
                   fireplace: @config.fireplace_ip,
                   canControl: @config.can_control?,
                   version: IntellifireBridge::VERSION)

      begin
        server.start
      ensure
        @poller.stop
      end
    end
  end
end
