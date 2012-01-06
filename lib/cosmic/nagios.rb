require 'cosmic'
require 'cosmic/plugin'
require 'net/http'
require 'uri'
require_with_hint 'json', "In order to use the nagios plugin please run 'gem install json'"

module Cosmic
  # A plugin that allows Cosmic scripts to control Nagios, for instance to turn off Nagios checks
  # for hosts while updating them:
  #
  #     with nagios do
  #       disable :host => host
  #       # do something with the host
  #       enable :host => host
  #     end
  #
  # The plugin needs to be configured with the url of the [Nagix](https://github.com/ning/Nagix)
  # server.
  #
  # Note that this plugin will not actually perform any destructive actions in Nagios in dry-run
  # mode. Instead it will only send messages tagged as `:nagios` and `:dryrun`.
  class Nagios < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new nagios plugin instance.
    #
    # @param [Environment] environment The Cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Nagios] The new instance
    def initialize(environment, name = :nagios)
      @name = name.to_s
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      raise "No nagix host specified in the configuration" unless @config[:nagix_host]
      uri = URI.parse(@config[:nagix_host])
      @nagix = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == 'https'
        @nagix.use_ssl = true
        @nagix.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
    end

    # Returns the Nagios status for the given host. This is equivalent to the MK Livestatus
    # returned by Nagios.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to return the status for
    # @option params [String,nil] :service The service on the host to return the status for;
    #                                      if not specified, then the status of the host will
    #                                      be returned
    # @return [Hash,nil] The Nagios status of the host/service as a Hash
    def status(params)
      host = params[:host] or raise "No :host argument given"
      service = params[:service]
      if service
        request = Net::HTTP::Get.new("/hosts/#{host}/#{service}/attributes?format=json")
        response = @nagix.request(request)
        notify(:msg => "[#{@name}] Retrieved Nagios status for service #{service} on host #{host}",
               :tags => [:nagios, :trace])
      else
        request = Net::HTTP::Get.new("/hosts/#{host}/attributes?format=json")
        response = @nagix.request(request)
        notify(:msg => "[#{@name}] Retrieved Nagios status for host #{host}",
               :tags => [:nagios, :trace])
      end
      if response.code.to_i < 300
        statuses = JSON.parse(response.body)
        if statuses.length > 0
          return statuses[0]
        else
          nil
        end
      else
        raise "Got response #{response.code} from Nagix server"
      end
    end

    # This is a simple wrapper around the `#status` method that extracts from the returned
    # status data whether notifications are enabled for the given host/service.
    # @param [Hash] params The parameters
    # @option params [String] :host The host to return the status for
    # @option params [String,nil] :service The service on the host to return the status for;
    #                                      if not specified, then the status of the host will
    #                                      be returned
    # @return [Boolean,nil] Whether notifications are enabled; returns `nil` if it wasn't
    #                       able to determine that
    def enabled?(params)
      status_hash = status(params)
      if status_hash && status_hash['notifications_enabled']
        status_hash['notifications_enabled'].to_i == 1
      else
        nil
      end
    end

    # Enables all configured Nagios check notifications for the given host. This is equivalent
    # to the `ENABLE_HOST_SVC_NOTIFICATIONS` and `ENABLE_SVC_NOTIFICATIONS` Nagios commands.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to enable checks for
    # @option params [String,nil] :service The service on the host to enable checks for;
    #                                      if not specified then all services will be enabled
    # @return [Hash] The Nagios status of the host/service as a Hash
    def enable(params)
      host = params[:host] or raise "No :host argument given"
      service = params[:service]
      if @environment.in_dry_run_mode
        if service
          notify(:msg => "[#{@name}] Would enable Nagios notifications for service #{service} on host #{host}",
                 :tags => [:nagios, :dryrun])
        else
          notify(:msg => "[#{@name}] Would enable Nagios notifications for host #{host}",
                 :tags => [:nagios, :dryrun])
        end
      else
        if service
          notify(:msg => "[#{@name}] Enabling notifications for service #{service} on host #{host}",
                 :tags => [:nagios, :trace])
          request = Net::HTTP::Put.new("/hosts/#{host}/#{service}/command/ENABLE_SVC_NOTIFICATIONS")
        else
          notify(:msg => "[#{@name}] Enabling notifications for host #{host}",
                 :tags => [:nagios, :trace])
          request = Net::HTTP::Put.new("/hosts/#{host}/command/ENABLE_HOST_SVC_NOTIFICATIONS")
        end
        request.body = "{}"
        request["Content-Type"] = "application/json"
        response = @nagix.request(request)
        if response.code.to_i >= 300
          raise "Got response #{response.code} from Nagix server"
        end
      end
      status(params)
    end

    # Enables all configured Nagios check notifications for the given host. This is equivalent
    # to the `DISABLE_HOST_SVC_NOTIFICATIONS` and `DISABLE_SVC_NOTIFICATIONS` Nagios commands.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to disable checks for
    # @option params [String,nil] :service The service on the host to disable checks for;
    #                                      if not specified then all services will be disabled
    # @return [Hash] The Nagios status of the host/service as a Hash
    def disable(params)
      host = params[:host] or raise "No :host argument given"
      service = params[:service]
      if @environment.in_dry_run_mode
        if service
          notify(:msg => "[#{@name}] Would disable Nagios notifications for service #{service} on host #{host}",
                 :tags => [:nagios, :dryrun])
        else
          notify(:msg => "[#{@name}] Would disable Nagios notifications for host #{host}",
                 :tags => [:nagios, :dryrun])
        end
      else
        if service
          notify(:msg => "[#{@name}] Disabling notifications for service #{service} on host #{host}",
                 :tags => [:nagios, :trace])
          request = Net::HTTP::Put.new("/hosts/#{host}/#{service}/command/DISABLE_SVC_NOTIFICATIONS")
        else
          notify(:msg => "[#{@name}] Disabling notifications for host #{host}",
                 :tags => [:nagios, :trace])
          request = Net::HTTP::Put.new("/hosts/#{host}/command/DISABLE_HOST_SVC_NOTIFICATIONS")
        end
        request.body = "{}"
        request["Content-Type"] = "application/json"
        response = @nagix.request(request)
        if response.code.to_i >= 300
          raise "Got response #{response.code} from Nagix server"
        end
      end
      status(params)
    end
  end
end
