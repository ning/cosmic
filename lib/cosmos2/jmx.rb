require 'cosmos2'
require 'cosmos2/plugin'

require_with_hint 'jmx4r', "In order to use the jmx plugin please run 'gem install jmx4r'"

module Cosmos2
  # A plugin that makes JMX available to cosmos scripts, e.g. to read out values or perform
  # operations on running Java services. You'd typically use it in a cosmos context like so:
  #
  #     with jmx do
  #       TODO
  #     end
  #
  # This plugin does not require a section in the config file unless you want to instantiate
  # more than one instance under names other than `jmx`, or if JMX requires authentication.
  #
  # Note that this plugin will not actually connect to the remote Java service in dry-run mode.
  # Instead it will only send messages tagged as `:jmx` and `:dryrun`.
  class JMX < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new jmx plugin instance.
    #
    # @param [Environment] environment The cosmos environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [JMX] The new instance
    def initialize(environment, name = :jmx)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @connections = {}
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
    end

    # Returns an mbean by name. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to query for the mbean; 'localhost' by default
    # @option params [String] :port The JMX port on the host; 3000 by default
    # @option params [String] :name The mbean name
    # @return [::JMX::MBean,nil] The mbean
    def get_mbean(params)
      mbeanify(params)
    end

    # Finds one or more mbeans. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to query for the mbean; 'localhost' by default
    # @option params [String] :port The JMX port on the host; 3000 by default
    # @option params [String] :filter The mbean filter; default value is '*:*' for all mbeans
    # @return [Array<::JMX::MBean>] The found mbeans
    def find_mbeans(params)
      conn = get_connection(params[:host] || 'localhost', params[:port] || 3000)
      if conn
        ::JMX::MBean.find_all_by_name(params[:filter] || '*:*', :connection => conn)
      else
        []
      end
    end

    # Returns the value of an mbean attribute. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [::JMX::MBean,nil] :mbean The mbean; if not specified, then `host`, `port` and `name` are required
    # @option params [String,nil] :host The host to query for the mbean; 'localhost' by default
    # @option params [String,nil] :port The JMX port on the host; 3000 by default
    # @option params [String,nil] :name The mbean name
    # @option params [String] :attribute The attribute to retrieve
    # @return [Object] The attribute value
    def get_attribute(params)
      mbean = mbeanify(params)
      if mbean
        mbean.send(params[:attribute].snake_case)
      else
        nil
      end
    end

    # Sets the value of an mbean attribute. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [::JMX::MBean,nil] :mbean The mbean; if not specified, then `host`, `port` and `name` are required
    # @option params [String,nil] :host The host to query for the mbean; 'localhost' by default
    # @option params [String,nil] :port The JMX port on the host; 3000 by default
    # @option params [String,nil] :name The mbean name
    # @option params [String] :attribute The attribute to set
    # @option params [Object] :value What to set the attribute to
    # @return [::JMX::MBean] The mbean
    def set_attribute(params)
      mbean = mbeanify(params)
      if mbean
        mbean.send(params[:attribute].snake_case + '=', params[:value])
      end
      mbean
    end

    # Invokes an mbean operation. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [::JMX::MBean,nil] :mbean The mbean; if not specified, then `host`, `port` and `name` are required
    # @option params [String,nil] :host The host to query for the mbean; 'localhost' by default
    # @option params [String,nil] :port The JMX port on the host; 3000 by default
    # @option params [String,nil] :name The mbean name
    # @option params [String] :operation The operation to invoke
    # @option params [Array<Object>,nil] :args The arguments to use when invoking the mbean operation
    # @return [Object,nil] The return value of the operation if any
    def invoke(params)
      mbean = mbeanify(params)
      if mbean
        mbean.send(params[:operation].snake_case, *(params[:args] || []))
      else
        nil
      end
    end

    private

    def get_connection(host, port)
      if @environment.in_dry_run_mode
        notify(:msg => "Would try to connect to JMX on host '#{host}:#{port}'",
               :tags => [:jmx, :dryrun])
      else
        username = nil
        password = nil
        if @config[:credentials]
          username = @config[:credentials][:username]
          password = @config[:credentials][:password]
        end
        @connections[host + ':' + port.to_s] ||= ::JMX::MBean.create_connection(:host => host,
                                                                                :port => port.to_i,
                                                                                :username => username,
                                                                                :password => password)
      end
    end

    def mbeanify(params)
      return params[:mbean] if params[:mbean]
      conn = get_connection(params[:host] || 'localhost', params[:port] || 3000)
      if conn
        ::JMX::MBean.find_by_name(params[:name], :connection => conn)
      else
        nil
      end
    end
  end
end
