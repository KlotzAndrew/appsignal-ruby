require "erb"
require "yaml"
require "uri"
require "socket"
require "tmpdir"

module Appsignal
  class Config
    DEFAULT_CONFIG = {
      :debug                          => false,
      :log                            => "file",
      :ignore_actions                 => [],
      :ignore_errors                  => [],
      :ignore_namespaces              => [],
      :filter_parameters              => [],
      :send_params                    => true,
      :endpoint                       => "https://push.appsignal.com",
      :instrument_net_http            => true,
      :instrument_redis               => true,
      :instrument_sequel              => true,
      :skip_session_data              => false,
      :enable_frontend_error_catching => false,
      :frontend_error_catching_path   => "/appsignal_error_catcher",
      :enable_allocation_tracking     => true,
      :enable_gc_instrumentation      => false,
      :enable_host_metrics            => true,
      :enable_minutely_probes         => false,
      :hostname                       => ::Socket.gethostname,
      :ca_file_path                   => File.expand_path(File.join("../../../resources/cacert.pem"), __FILE__),
      :dns_servers                    => []
    }.freeze

    ENV_TO_KEY_MAPPING = {
      "APPSIGNAL_ACTIVE"                         => :active,
      "APPSIGNAL_PUSH_API_KEY"                   => :push_api_key,
      "APPSIGNAL_APP_NAME"                       => :name,
      "APPSIGNAL_PUSH_API_ENDPOINT"              => :endpoint,
      "APPSIGNAL_FRONTEND_ERROR_CATCHING_PATH"   => :frontend_error_catching_path,
      "APPSIGNAL_DEBUG"                          => :debug,
      "APPSIGNAL_LOG"                            => :log,
      "APPSIGNAL_LOG_PATH"                       => :log_path,
      "APPSIGNAL_INSTRUMENT_NET_HTTP"            => :instrument_net_http,
      "APPSIGNAL_INSTRUMENT_REDIS"               => :instrument_redis,
      "APPSIGNAL_INSTRUMENT_SEQUEL"              => :instrument_sequel,
      "APPSIGNAL_SKIP_SESSION_DATA"              => :skip_session_data,
      "APPSIGNAL_ENABLE_FRONTEND_ERROR_CATCHING" => :enable_frontend_error_catching,
      "APPSIGNAL_IGNORE_ACTIONS"                 => :ignore_actions,
      "APPSIGNAL_IGNORE_ERRORS"                  => :ignore_errors,
      "APPSIGNAL_IGNORE_NAMESPACES"              => :ignore_namespaces,
      "APPSIGNAL_FILTER_PARAMETERS"              => :filter_parameters,
      "APPSIGNAL_SEND_PARAMS"                    => :send_params,
      "APPSIGNAL_HTTP_PROXY"                     => :http_proxy,
      "APPSIGNAL_ENABLE_ALLOCATION_TRACKING"     => :enable_allocation_tracking,
      "APPSIGNAL_ENABLE_GC_INSTRUMENTATION"      => :enable_gc_instrumentation,
      "APPSIGNAL_RUNNING_IN_CONTAINER"           => :running_in_container,
      "APPSIGNAL_WORKING_DIR_PATH"               => :working_dir_path,
      "APPSIGNAL_ENABLE_HOST_METRICS"            => :enable_host_metrics,
      "APPSIGNAL_ENABLE_MINUTELY_PROBES"         => :enable_minutely_probes,
      "APPSIGNAL_HOSTNAME"                       => :hostname,
      "APPSIGNAL_CA_FILE_PATH"                   => :ca_file_path,
      "APPSIGNAL_DNS_SERVERS"                    => :dns_servers
    }.freeze

    attr_reader :root_path, :env, :initial_config, :config_hash
    attr_accessor :logger

    def initialize(root_path, env, initial_config = {}, logger = Appsignal.logger)
      @root_path      = root_path
      @env            = ENV.fetch("APPSIGNAL_APP_ENV".freeze, env.to_s)
      @initial_config = initial_config
      @logger         = logger
      @valid          = false
      @config_hash    = Hash[DEFAULT_CONFIG]

      # Set config based on the system
      detect_from_system
      # Initial config
      merge(@config_hash, initial_config)
      # Load the config file if it exists
      load_from_disk
      # Load config from environment variables
      load_from_environment
      # Validate that we have a correct config
      validate
    end

    # @api private
    # @return [String] System's tmp directory.
    def self.system_tmp_dir
      if Gem.win_platform?
        Dir.tmpdir
      else
        File.realpath("/tmp")
      end
    end

    def [](key)
      config_hash[key]
    end

    def []=(key, value)
      config_hash[key] = value
    end

    def log_file_path
      path = config_hash[:log_path] || root_path && File.join(root_path, "log")
      if path && File.writable?(path)
        return File.join(File.realpath(path), "appsignal.log")
      end

      system_tmp_dir = self.class.system_tmp_dir
      if File.writable? system_tmp_dir
        $stdout.puts "appsignal: Unable to log to '#{path}'. Logging to "\
          "'#{system_tmp_dir}' instead. Please check the "\
          "permissions for the application's (log) directory."
        File.join(system_tmp_dir, "appsignal.log")
      else
        $stdout.puts "appsignal: Unable to log to '#{path}' or the "\
          "'#{system_tmp_dir}' fallback. Please check the permissions "\
          "for the application's (log) directory."
      end
    end

    def valid?
      @valid
    end

    def active?
      @valid && config_hash[:active]
    end

    def write_to_environment # rubocop:disable Metrics/AbcSize
      ENV["_APPSIGNAL_ACTIVE"]                       = active?.to_s
      ENV["_APPSIGNAL_APP_PATH"]                     = root_path.to_s
      ENV["_APPSIGNAL_AGENT_PATH"]                   = File.expand_path("../../../ext", __FILE__).to_s
      ENV["_APPSIGNAL_ENVIRONMENT"]                  = env
      ENV["_APPSIGNAL_AGENT_VERSION"]                = Appsignal::Extension.agent_version
      ENV["_APPSIGNAL_LANGUAGE_INTEGRATION_VERSION"] = "ruby-#{Appsignal::VERSION}"
      ENV["_APPSIGNAL_DEBUG_LOGGING"]                = config_hash[:debug].to_s
      ENV["_APPSIGNAL_LOG"]                          = config_hash[:log]
      ENV["_APPSIGNAL_LOG_FILE_PATH"]                = log_file_path.to_s if log_file_path
      ENV["_APPSIGNAL_PUSH_API_ENDPOINT"]            = config_hash[:endpoint]
      ENV["_APPSIGNAL_PUSH_API_KEY"]                 = config_hash[:push_api_key]
      ENV["_APPSIGNAL_APP_NAME"]                     = config_hash[:name]
      ENV["_APPSIGNAL_HTTP_PROXY"]                   = config_hash[:http_proxy]
      ENV["_APPSIGNAL_IGNORE_ACTIONS"]               = config_hash[:ignore_actions].join(",")
      ENV["_APPSIGNAL_IGNORE_ERRORS"]                = config_hash[:ignore_errors].join(",")
      ENV["_APPSIGNAL_IGNORE_NAMESPACES"]            = config_hash[:ignore_namespaces].join(",")
      ENV["_APPSIGNAL_FILTER_PARAMETERS"]            = config_hash[:filter_parameters].join(",")
      ENV["_APPSIGNAL_SEND_PARAMS"]                  = config_hash[:send_params].to_s
      ENV["_APPSIGNAL_RUNNING_IN_CONTAINER"]         = config_hash[:running_in_container].to_s
      ENV["_APPSIGNAL_WORKING_DIR_PATH"]             = config_hash[:working_dir_path] if config_hash[:working_dir_path]
      ENV["_APPSIGNAL_ENABLE_HOST_METRICS"]          = config_hash[:enable_host_metrics].to_s
      ENV["_APPSIGNAL_ENABLE_MINUTELY_PROBES"]       = config_hash[:enable_minutely_probes].to_s
      ENV["_APPSIGNAL_HOSTNAME"]                     = config_hash[:hostname].to_s
      ENV["_APPSIGNAL_PROCESS_NAME"]                 = $PROGRAM_NAME
      ENV["_APPSIGNAL_CA_FILE_PATH"]                 = config_hash[:ca_file_path].to_s
      ENV["_APPSIGNAL_DNS_SERVERS"]                  = config_hash[:dns_servers].join(",")
    end

    private

    def config_file
      @config_file ||=
        root_path.nil? ? nil : File.join(root_path, "config", "appsignal.yml")
    end

    def detect_from_system
      config_hash[:log] = "stdout" if Appsignal::System.heroku?

      # Make active by default if APPSIGNAL_PUSH_API_KEY is present
      config_hash[:active] = true if ENV["APPSIGNAL_PUSH_API_KEY"]
    end

    def load_from_disk
      return if !config_file || !File.exist?(config_file)

      configurations = YAML.load(ERB.new(IO.read(config_file)).result)
      config_for_this_env = configurations[env]
      if config_for_this_env
        config_for_this_env = Hash[config_for_this_env.map do |key, value|
          [key.to_sym, value]
        end] # convert keys to symbols

        # Backwards compatibility with config files generated by earlier
        # versions of the gem
        if !config_for_this_env[:push_api_key] && config_for_this_env[:api_key]
          config_for_this_env[:push_api_key] = config_for_this_env[:api_key]
        end
        if !config_for_this_env[:ignore_errors] && config_for_this_env[:ignore_exceptions]
          config_for_this_env[:ignore_errors] = config_for_this_env[:ignore_exceptions]
        end

        merge(@config_hash, config_for_this_env)
      else
        @logger.error "Not loading from config file: config for '#{env}' not found"
      end
    end

    def load_from_environment
      config = {}

      # Configuration with string type
      %w(APPSIGNAL_PUSH_API_KEY APPSIGNAL_APP_NAME APPSIGNAL_PUSH_API_ENDPOINT
         APPSIGNAL_FRONTEND_ERROR_CATCHING_PATH APPSIGNAL_HTTP_PROXY
         APPSIGNAL_LOG APPSIGNAL_LOG_PATH APPSIGNAL_WORKING_DIR_PATH
         APPSIGNAL_HOSTNAME APPSIGNAL_CA_FILE_PATH).each do |var|
        env_var = ENV[var]
        next unless env_var
        config[ENV_TO_KEY_MAPPING[var]] = env_var
      end

      # Configuration with boolean type
      %w(APPSIGNAL_ACTIVE APPSIGNAL_DEBUG APPSIGNAL_INSTRUMENT_NET_HTTP
         APPSIGNAL_INSTRUMENT_REDIS APPSIGNAL_INSTRUMENT_SEQUEL
         APPSIGNAL_SKIP_SESSION_DATA APPSIGNAL_ENABLE_FRONTEND_ERROR_CATCHING
         APPSIGNAL_ENABLE_ALLOCATION_TRACKING APPSIGNAL_ENABLE_GC_INSTRUMENTATION
         APPSIGNAL_RUNNING_IN_CONTAINER APPSIGNAL_ENABLE_HOST_METRICS
         APPSIGNAL_SEND_PARAMS APPSIGNAL_ENABLE_MINUTELY_PROBES).each do |var|
        env_var = ENV[var]
        next unless env_var
        config[ENV_TO_KEY_MAPPING[var]] = env_var == "true"
      end

      # Configuration with array of strings type
      %w(APPSIGNAL_IGNORE_ACTIONS APPSIGNAL_IGNORE_ERRORS
         APPSIGNAL_IGNORE_NAMESPACES APPSIGNAL_FILTER_PARAMETERS).each do |var|
        env_var = ENV[var]
        next unless env_var
        config[ENV_TO_KEY_MAPPING[var]] = env_var.split(",")
      end

      merge(@config_hash, config)
    end

    def merge(original_config, new_config)
      new_config.each do |key, value|
        unless original_config[key].nil?
          @logger.debug("Config key '#{key}' is being overwritten")
        end
        original_config[key] = value
      end
    end

    def validate
      # Strip path from endpoint so we're backwards compatible with
      # earlier versions of the gem.
      endpoint_uri = URI(config_hash[:endpoint])
      config_hash[:endpoint] =
        if endpoint_uri.port == 443
          "#{endpoint_uri.scheme}://#{endpoint_uri.host}"
        else
          "#{endpoint_uri.scheme}://#{endpoint_uri.host}:#{endpoint_uri.port}"
        end

      if config_hash[:push_api_key]
        @valid = true
      else
        @valid = false
        @logger.error "Push api key not set after loading config"
      end
    end
  end
end
