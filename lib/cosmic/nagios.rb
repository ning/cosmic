require 'cosmic'
require 'cosmic/plugin'
require 'uri'

require_with_hint 'net/ssh', "In order to use the nagios plugin please run 'gem install net-ssh'"

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
  # The plugin will ssh to the nagios server and then issue commands to mk_livestatus. This
  # requires that the nagios server is reachable via ssh, and that the user used for ssh
  # can access the unix socket created by mk_livestatus. The latter is usually achieved by
  # putting that user into the `nagios` group.
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
      init_opts
    end

    # Returns the Nagios status for the given host. This is equivalent to the MK Livestatus
    # returned by Nagios.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to return the status for
    # @option params [String,Array<String>,nil] :services The service(s) on the host to return
    #                               the status for. If not specified, then the status of the host will
    #                               be returned
    # @return [Hash,nil] The Nagios status of the host as a hash/service(s) as a hash of hashes
    def status(params)
      host = get_param(params, :host)
      notify(:msg => "[#{@name}] Retrieving Nagios status for host #{host}",
             :tags => [:nagios, :trace])
      cmd = "GET hosts\n"\
            "Filter: host_name = #{host}\n"\
            "Filter: alias = #{host}\n"\
            "Filter: address = #{host}\n"\
            "Or: 3\n"\
            "ColumnHeaders: on\n"\
            "ResponseHeader: fixed16\n"
      result = parse(exec(cmd))
      if params.has_key?(:services) && !result.empty?
        real_host = result[0]["name"]
        services = arrayify(params[:services])

        notify(:msg => "[#{@name}] Retrieving Nagios status for service(s) #{services} on host #{host}",
               :tags => [:nagios, :trace])
        result = arrayify(params[:services]).inject({}) do |statuses, service|
          cmd = "GET services\n"\
                "Filter: host_name = #{real_host}\n"\
                "Filter: description = #{service}\n"\
                "And: 2\n"\
                "ColumnHeaders: on\n"\
                "ResponseHeader: fixed16\n"
          response = parse(exec(cmd))
          statuses[service] = response[0] unless response.empty?
        end
        result
      else
        result.empty? ? nil : result[0]
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
    # to the `ENABLE_HOST_SVC_NOTIFICATIONS`, `ENABLE_SVC_NOTIFICATIONS` and
    # `ENABLE_HOST_NOTIFICATIONS` Nagios commands.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to enable checks for
    # @option params [String,Array<String>,:all,nil] :services The service(s) on the host to enable checks for.
    #                               If not specified then notifications for the host itself will be enabled.
    #                               When given the special argument `:all` then all services on the host will
    #                               be disabled.
    # @return [Hash,nil] The Nagios status of the host as a hash/service(s) as a hash of hashes.
    #                    If `:all` is specified, then the host status is returned
    def enable(params)
      host = get_param(params, :host)
      if @environment.in_dry_run_mode
        if params.has_key?(:service)
          services = params[:services]
          if services == :all
            notify(:msg => "[#{@name}] Would enable Nagios notifications for all services on host #{host}",
                   :tags => [:nagios, :dryrun])
          else
            notify(:msg => "[#{@name}] Would enable Nagios notifications for service(s) #{params[:services]} on host #{host}",
                   :tags => [:nagios, :dryrun])
          end
        else
          notify(:msg => "[#{@name}] Would enable Nagios notifications for host #{host}",
                 :tags => [:nagios, :dryrun])
        end
      else
        real_host = find_host(params)
        if real_host.nil?
          raise "Host #{host} does not seem to be present in Nagios"
        end
        if params.has_key?(:services)
          services = params[:services]
          if services == :all
            notify(:msg => "[#{@name}] Enabling notifications for all services on host #{host}",
                   :tags => [:nagios, :trace])
            exec("COMMAND [#{Time.now.to_i}] ENABLE_HOST_SVC_NOTIFICATIONS;#{real_host}\n\n")
          else
            notify(:msg => "[#{@name}] Enabling notifications for service(s) #{params[:services]} on host #{host}",
                   :tags => [:nagios, :trace])
            arrayify(services).each do |service|
              exec("COMMAND [#{Time.now.to_i}] ENABLE_SVC_NOTIFICATIONS;#{real_host};#{service}\n\n")
            end
          end
        else
          notify(:msg => "[#{@name}] Enabling notifications for host #{host}",
                 :tags => [:nagios, :trace])
          exec("COMMAND [#{Time.now.to_i}] ENABLE_HOST_NOTIFICATIONS;#{real_host}\n\n")
        end
      end
      status(params)
    end

    # Enables all configured Nagios check notifications for the given host. This is equivalent
    # to the `DISABLE_HOST_SVC_NOTIFICATIONS`, `DISABLE_SVC_NOTIFICATIONS` and
    # `DISABLE_HOST_NOTIFICATIONS` Nagios commands.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to disable checks for
    # @option params [String,Array<String>,:all,nil] :services The service(s) on the host to enable checks for.
    #                               If not specified then notifications for the host itself will be enabled.
    #                               When given the special argument `:all` then all services on the host will
    #                               be disabled.
    # @return [Hash,nil] The Nagios status of the host as a hash/service(s) as a hash of hashes.
    #                    If `:all` is specified, then the host status is returned
    def disable(params)
      host = get_param(params, :host)
      if @environment.in_dry_run_mode
        if params.has_key?(:service)
          services = params[:services]
          if services == :all
            notify(:msg => "[#{@name}] Would disable Nagios notifications for all services on host #{host}",
                   :tags => [:nagios, :dryrun])
          else
            notify(:msg => "[#{@name}] Would disable Nagios notifications for service(s) #{params[:services]} on host #{host}",
                   :tags => [:nagios, :dryrun])
          end
        else
          notify(:msg => "[#{@name}] Would disable Nagios notifications for host #{host}",
                 :tags => [:nagios, :dryrun])
        end
      else
        real_host = find_host(params)
        if real_host.nil?
          raise "Host #{host} does not seem to be present in Nagios"
        end
        if params.has_key?(:services)
          services = params[:services]
          if services == :all
            notify(:msg => "[#{@name}] Disabling notifications for all services on host #{host}",
                   :tags => [:nagios, :trace])
            exec("COMMAND [#{Time.now.to_i}] DISABLE_HOST_SVC_NOTIFICATIONS;#{real_host}\n\n")
          else
            notify(:msg => "[#{@name}] Disabling notifications for service(s) #{params[:services]} on host #{host}",
                   :tags => [:nagios, :trace])
            arrayify(services).each do |service|
              exec("COMMAND [#{Time.now.to_i}] DISABLE_SVC_NOTIFICATIONS;#{real_host};#{service}\n\n")
            end
          end
        else
          notify(:msg => "[#{@name}] Disabling notifications for host #{host}",
                 :tags => [:nagios, :trace])
          exec("COMMAND [#{Time.now.to_i}] DISABLE_HOST_NOTIFICATIONS;#{real_host}\n\n")
        end
      end
      status(params)
    end

    private

    def init_opts
      raise "No nagios host specified in the configuration" unless @config[:nagios_host]
      raise "No mk_livestatus socket path specified in the configuration" unless @config[:mk_livestatus_socket_path]
      @ssh_opts = {}
      if @config[:auth][:keys] || @config[:auth][:key_data]
        @ssh_opts[:keys] = @config[:auth][:keys]
        @ssh_opts[:key_data] = @config[:auth][:key_data]
        @ssh_opts[:keys_only] = true
      elsif @config[:auth][:password]
        @ssh_opts[:password] = @config[:auth][:password]
      end
    end

    def exec(cmd)
      host = @config[:nagios_host]
      user = @config[:auth][:username]
      unless @environment.in_dry_run_mode
        full_cmd = "echo '#{cmd}' | unixcat #{@config[:mk_livestatus_socket_path]}"
        response = nil
        begin
          Net::SSH.start(host, user, @ssh_opts) do |ssh|
            response = ssh.exec!(full_cmd)
          end
        rescue Net::SSH::AuthenticationFailed => e
          if @config[:auth_type] =~ /^credentials$/ && !@config.has_key?(:password)
            puts "Invalid username or password. Please try again"
            @environment.resolve_service_auth(:service_name => @name.to_sym, :config => @config, :force => true)
            init_opts
            retry
          else
            raise e
          end
        end
        response
      end
    end

    def find_host(params)
      host = get_param(params, :host)
      cmd = "GET hosts\n"\
            "Filter: host_name = #{host}\n"\
            "Filter: alias = #{host}\n"\
            "Filter: address = #{host}\n"\
            "Or: 3\n"\
            "ColumnHeaders: on\n"\
            "ResponseHeader: fixed16\n"
      response = parse(exec(cmd))
      response.empty? ? nil : response[0]['name']
    end

    def parse(response)
      result = []
      if response
        lines = response.split("\n")
        header = lines.shift.chomp
        columns = lines.shift.chomp.split(';')
        lines.each do |line|
          hsh = {}
          columns = Array.new(columns)
          values = line.chomp.split(';')
          columns.zip(values) { |k,v| hsh[k] = v }
          result.push(hsh)
        end
      end
      result
    end
  end
end
