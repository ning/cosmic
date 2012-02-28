require 'cosmic'
require 'cosmic/plugin'

require_with_hint 'jmx4r', "In order to use the jmx plugin please run 'gem install jmx4r'"

require 'java'
java_import 'javax.management.InstanceNotFoundException'
java_import 'java.rmi.ConnectException'

module Cosmic
  # A plugin that makes JMX available to Cosmic scripts, e.g. to read out values or perform
  # operations on running Java services. You'd typically use it in a Cosmic context like so:
  #
  #     with jmx do
  #       mbeans = services.collect do |service|
  #         get_mbean :host => service.host, :port => 12345, :name => 'some.company:name=MyMBean'
  #       end
  #       mbeans.each do |mbean|
  #         set_attribute :mbean => mbean, :attribute => 'SomeValue', :value => 1
  #       end
  #     end
  #
  # This plugin does not require a section in the config file unless you want to instantiate
  # more than one instance under names other than `jmx`, or if JMX requires authentication.
  #
  # Note that this plugin will not actually connect to the remote Java service in dry-run mode.
  # Instead it will only send messages tagged as `:jmx` and `:dryrun`.
  class JMX < Plugin
    class JMXError < StandardError; end

    # The plugin's configuration
    attr_reader :config

    # Creates a new jmx plugin instance.
    #
    # @param [Environment] environment The Cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [JMX] The new instance
    def initialize(environment, name = :jmx)
      @name = name.to_s
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @connections = {}
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
    end

    # Returns an mbean by name. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to query for the mbean
    # @option params [String] :port The JMX port on the host
    # @option params [String] :name The mbean name
    # @return [::JMX::MBean,nil] The mbean
    def get_mbean(params)
      mbeanify(params)
    end

    # Finds one or more mbeans. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to query for the mbean
    # @option params [String] :port The JMX port on the host
    # @option params [String] :filter The mbean filter; default value is '*:*' for all mbeans
    # @return [Array<::JMX::MBean>] The found mbeans
    def find_mbeans(params)
      filter = params[:filter] || '*:*'
      conn = get_connection(params)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would find all mbeans matching #{filter} on host #{host}:#{port}",
               :tags => [:jmx, :dryrun])
      else
        unless conn.nil?
          result = ::JMX::MBean.find_all_by_name(filter, :connection => conn)
          notify(:msg => "[#{@name}] Found all mbeans matching #{filter} on host #{host}:#{port}",
                 :tags => [:jmx, :trace])
          return result
        end
      end
      []
    end

    # Returns the value of an mbean attribute. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [::JMX::MBean,nil] :mbean The mbean; if not specified, then `host`, `port` and `name` are required
    # @option params [String,nil] :host The host to query for the mbean; 'localhost' by default
    # @option params [String,nil] :port The JMX port on the host
    # @option params [String,nil] :name The mbean name
    # @option params [String] :attribute The attribute to retrieve
    # @return [Object] The attribute value
    def get_attribute(params)
      attribute = get_param(params, :attribute)
      mbean = mbeanify(params)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would retrieve attribute #{attribute} of mbean #{params[:name] || mbean}",
               :tags => [:jmx, :dryrun])
      else
        unless mbean.nil?
          attr_name = attribute.snake_case
          if mbean.respond_to?(attr_name)
            result = mbean.send(attribute.snake_case)
            notify(:msg => "[#{@name}] Retrieved attribute #{attribute} of mbean #{params[:name] || mbean}",
                   :tags => [:jmx, :trace])
            return result
          else
            raise JMXError, "The mbean does not have an attribute #{attribute}"
          end
        end
      end
      nil
    end

    # Sets the value of an mbean attribute. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [::JMX::MBean,nil] :mbean The mbean; if not specified, then `host`, `port` and `name` are required
    # @option params [String,nil] :host The host to query for the mbean; 'localhost' by default
    # @option params [String,nil] :port The JMX port on the host
    # @option params [String,nil] :name The mbean name
    # @option params [String] :attribute The attribute to set
    # @option params [Object] :value What to set the attribute to
    # @return [::JMX::MBean] The mbean
    def set_attribute(params)
      attribute = get_param(params, :attribute)
      value = get_param(params, :value)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would set attribute #{attribute} to '#{value}' on mbean #{params[:name] || params[:mbean]}",
               :tags => [:jmx, :dryrun])
      else
        mbean = mbeanify(params)
        unless mbean.nil?
          attr_name = attribute.snake_case + '='
          if mbean.respond_to?(attr_name)
            mbean.send(attr_name, value)
            notify(:msg => "[#{@name}] Set attribute #{attribute} to '#{value}' on mbean #{params[:name] || mbean}",
                   :tags => [:jmx, :trace])
          else
            raise JMXError, "The mbean does not have an attribute #{attribute} or the attribute cannot be changed"
          end
        end
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
    # @option params [Array<Object>,nil] :args The (optional) arguments to use when invoking the mbean operation
    # @return [Object,nil] The return value of the operation if any
    def invoke(params)
      operation = get_param(params, :operation)
      mbean = mbeanify(params)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would invoke operation #{operation} on mbean #{params[:name] || mbean}",
               :tags => [:jmx, :dryrun])
      else
        unless mbean.nil?
          op_name = operation.snake_case + '='
          if mbean.respond_to?(op_name)
            result = mbean.send(op_name, *(params[:args] || []))
            notify(:msg => "[#{@name}] Invoked operation #{operation} on mbean #{params[:name] || mbean}",
                   :tags => [:jmx, :trace])
            return result
          else
            raise JMXError, "The mbean does not have an operation #{operation}"
          end
        end
      end
      nil
    end

    # Shuts down this JMX plugin instance by releasing all connections to remote mbeans.
    def shutdown
      @connections.values.each do |conn|
        conn.close
      end
      @connections.clear
    end

    private

    def get_connection(params)
      host = get_param(params, :host)
      port = get_param(params, :port)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would try to connect to JMX on host #{host}:#{port}",
               :tags => [:jmx, :dryrun])
        nil
      else
        username = nil
        password = nil
        if @config[:auth]
          username = @config[:auth][:username]
          password = @config[:auth][:password]
        end
        key = host + ':' + port.to_s
        begin
          @connections[key] ||= ::JMX::MBean.create_connection(:host => host,
                                                               :port => port.to_i,
                                                               :username => username,
                                                               :password => password)
        rescue ConnectException
          raise JMXError, "Could not connect to host #{params[:host]}:#{params[:port]}"
        end
        notify(:msg => "[#{@name}] Connected to JMX on host #{host}:#{port}",
               :tags => [:jmx, :trace])
        @connections[key]
      end
    end

    def mbeanify(params)
      return params[:mbean] if params.has_key?(:mbean)
      unless @environment.in_dry_run_mode
        name = get_param(params, :name)
        conn = get_connection(params)
        if conn
          begin
            mbean = ::JMX::MBean.find_by_name(name, :connection => conn)
          rescue InstanceNotFoundException
            raise JMXError, "MBean #{name} not found on host #{params[:host]}:#{params[:port]}"
          end
          notify(:msg => "[#{@name}] Retrieved mbean #{name} from host #{params[:host]}:#{params[:port]}",
                 :tags => [:jmx, :trace])
          return mbean
        end
      end
      nil
    end
  end
end
