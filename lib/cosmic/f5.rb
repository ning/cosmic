require 'cosmic'
require 'cosmic/plugin'
require 'socket'
require 'monitor'
require_with_hint 'f5-icontrol', "In order to use the F5 plugin please install the f5-icontrol gem, version 11.0.0.1 or newer"

module Cosmic
  # A plugin to interact with an F5 load balancer:
  #
  #     with f5 do
  #       disable :host => 'foo'
  #       add_to_pool :host => 'foo', :port => 12345, :pool => 'prod-foo'
  #                   :monitor_rule => { :type => 'MONITOR_RULE_TYPE_SINGLE', :templates => 'foo' }
  #       enable :host => 'foo'
  #     end
  #
  # The F5 plugin emits messages tagged as `:f5` and `:info` for most of its actions.
  # Note that in dry-run mode this plugin will still connect to the load balancer and perform non-destructive
  # operations (e.g. {#get_members}) but not destructive ones (such as {#enable}). Instead, it will send
  # messages tagged as `:f5` and `:dryrun` in those cases.
  class F5 < Plugin
    class OperationFailed < StandardError; end

    # The plugin's configuration
    attr_reader :config

    # Creates a new F5 plugin instance.
    #
    # @param [Environment] environment The cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Galaxy] The new instance
    def initialize(environment, name = :f5)
      @name = name.to_s
      # Using Monitor instead of Mutex as the former is reentrant
      @monitor = Monitor.new
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      raise "No F5 host specified in the configuration" unless @config[:host]
      authenticate
    end

    # Adds a node to a pool. If a monitor rule is specified, then it will also set it on the
    # member using the {#set_monitor_rule} method.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, 80 by default
    # @option params [String] :pool The pool name
    # @option params [String] :monitor_rule The monitoring rule
    # @return [Array<Hash>] The member as a hash with `:pool_name`,, `:ip`, `:port`,
    #                       `:availability`, `:enabled` and `:monitor_rule` entries
    def add_to_pool(params)
      pool_name = get_param(params, :pool)
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would add node node #{node_ip}:#{node_port} to pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :dryrun])
        get_member(params)
      else
        notify(:msg => "[#{@name}] Adding node #{node_ip}:#{node_port} to pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :trace])
        with_f5('LocalLB.Pool') do
          add_member([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
        end
        if params.has_key?(:monitor_rule)
          set_monitor_rule(params)
        else
          get_member(params)
        end
      end
    end

    # Sets the monitor rule for a pool member which defines how the load balancer monitors the member.
    # The `:monitor_rule` parameter is a hash consisting of
    #
    # * `:type` - The type of the monitoring rule, one of `MONITOR_RULE_TYPE_SINGLE` for a
    #             single monitor, `MONITOR_RULE_TYPE_AND_LIST` for a list of monitors that
    #             all have to succeed, or `MONITOR_RULE_TYPE_M_OF_N` if a quorum of monitors
    #             have to succeed
    # * `:quorum` - The optional number of monitors that have to succeed, only used if the
    #               type is `MONITOR_RULE_TYPE_M_OF_N`
    # * `:templates` - An array of the names of the monitoring rule templates to use
    #
    # If `:monitor_rule` is not specified, then this method will remove any monitoring rules for
    # the member.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, 80 by default
    # @option params [String] :pool The pool name
    # @option params [String] :monitor_rule The monitoring rule
    # @return [Array<Hash>] The member as a hash with `:pool_name`,, `:ip`, `:port`,
    #                       `:availability`, `:enabled` and `:monitor_rule` entries
    def set_monitor_rule(params)
      pool_name = get_param(params, :pool)
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would set monitor rule for node #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :dryrun])
      else
        notify(:msg => "[#{@name}] Setting monitor rule for node #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :trace])
        if params.has_key?(:monitor_rule)
          ip_port = { 'address' => node_ip,
                      'port' => node_port }
          monitor_ip_port = { 'address_type' => 'ATYPE_EXPLICIT_ADDRESS_EXPLICIT_PORT',
                              'ipport' => ip_port }
          monitor_rule = { 'type' => params[:monitor_rule][:type] || 'MONITOR_RULE_TYPE_SINGLE',
                           'quorum' => params[:monitor_rule][:quorum] || 0,
                           'monitor_templates' => params[:monitor_rule][:templates] || [] }
          monitor_associations = [{ 'member' => monitor_ip_port,
                                    'monitor_rule' => monitor_rule }]
        else
          monitor_associations = []
        end
        with_f5('LocalLB.PoolMember') do
          set_monitor_association([ pool_name ], [ monitor_associations ])
        end
      end
      get_member(params)
    end

    # Removes a node from a pool.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, 80 by default
    # @option params [String] :pool The pool name
    # @return [void]
    def remove_from_pool(params)
      pool_name = get_param(params, :pool)
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would remote node #{node_ip}:#{node_port} from pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :dryrun])
      else
        notify(:msg => "[#{@name}] Removing node #{node_ip}:#{node_port} from pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :trace])
        with_f5('LocalLB.Pool') do
          # TODO: deal with node not existing (exception)
          remove_member([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
        end
      end
      nil
    end

    # Retrieves the members of a pool.
    #
    # @param [Hash] params The parameters
    # @option params [String] :pool The pool name
    # @return [Array<Hash>] The members as hashes with `:pool_name`,, `:ip`, `:port`,
    #                       `:availability`, `:enabled` and `:monitor_rule` entries
    def get_members(params)
      pool_name = get_param(params, :pool)
      notify(:msg => "[#{@name}] Retrieving all members for pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :trace])
      members = with_f5('LocalLB.PoolMember') do
        # TODO: deal with pool not existing (get_object_status returns nil)
        get_object_status([ pool_name ])[0].collect do |pool_member|
          member = pool_member['member']
          status = pool_member['object_status']
          { :ip => member['address'],
            :port => member['port'],
            :availability => status['availability_status'],
            :enabled => (status['enabled_status'] == 'ENABLED_STATUS_ENABLED'),
            :pool => pool_name }
        end
      end
      members_hash = members.inject({}) { |h, member| h[member[:ip].to_s + ':' + member[:port].to_s] = member; h }
      pool_members = members.map { |member| { 'address' => member[:ip], 'port' => member[:port] } }
      with_f5('LocalLB.PoolMember') do
        get_monitor_association([ pool_name ])[0].each do |monitor_associations|
          address = monitor_associations['member']['ipport']
          member = members_hash[address['address'].to_s + ':' + address['port'].to_s]
          if member
            monitor_rule = monitor_associations['monitor_rule']
            member[:monitor_rule] = { :type => monitor_rule['type'],
                                      :quorum => monitor_rule['quorum'],
                                      :templates => monitor_rule['monitor_templates'] }
          end
        end
      end

      members
    end

    # Retrieves a member of a pool.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, 80 by default
    # @option params [String] :pool The pool name
    # @return [Array<Hash>] The member as a hash with `:pool_name`,, `:ip`, `:port`,
    #                       `:availability`, `:enabled` and `:monitor_rule` entries
    def get_member(params)
      pool_name = get_param(params, :pool)
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      notify(:msg => "[#{@name}] Retrieving member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :trace])
      member = nil
      with_f5('LocalLB.PoolMember') do
        # TODO: deal with pool not existing (get_object_status returns nil)
        get_object_status([ pool_name ])[0].each do |pool_member|
          member_info = pool_member['member']
          status = pool_member['object_status']
          if member_info['address'] == node_ip && member_info['port'] == node_port
            member = { :ip => member_info['address'],
                       :port => member_info['port'],
                       :availability => status['availability_status'],
                       :enabled => (status['enabled_status'] == 'ENABLED_STATUS_ENABLED'),
                       :pool => pool_name }
            break
          end
        end
      end

      if member
        with_f5('LocalLB.PoolMember') do
          get_monitor_association([ pool_name ])[0].each do |monitor_associations|
            address = monitor_associations['member']['ipport']
            if address['address'] == node_ip && address['port'] == node_port
              monitor_rule = monitor_associations['monitor_rule']
              member[:monitor_rule] = { :type => monitor_rule['type'],
                                        :quorum => monitor_rule['quorum'],
                                        :templates => monitor_rule['monitor_templates'] }
              break
            end
          end
        end
      end
      member
    end

    # Retrieves a node.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @return [Hash,nil] The member as a hash with `:ip`, `:availability`, and `:enabled` entries
    def get_node(params)
      node_ip = get_ip(params)
      notify(:msg => "[#{@name}] Retrieving node #{node_ip} from load balancer #{@config[:host]}",
             :tags => [:f5, :trace])
      with_f5('LocalLB.NodeAddress') do
        get_object_status([ node_ip ]).each do |status|
          return { :ip => node_ip,
                   :availability => status['availability_status'],
                   :enabled => (status['enabled_status'] == 'ENABLED_STATUS_ENABLED') }
        end
      end
    end

    # Retrieves statistics for a node or pool member. If `pool_name` is specified, then
    # only the stats for that pool are returned.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port; only required if a pool name is given
    # @option params [String] :pool The pool name, 80 by default if a pool name is given
    # @return [Hash,nil] The statistics as a hash of statistics name to current value
    def get_stats(params)
      node_ip = get_ip(params)
      result = {}
      if params.has_key?(:pool)
        pool_name = params[:pool]
        node_port = (params[:port] || 80).to_i
        notify(:msg => "[#{@name}] Retrieving stats for member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :trace])
        stats = with_f5('LocalLB.PoolMember') do
          get_statistics([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
        end
        # TODO: deal with node not existing (stats is nil)
        stats = stats[0] if stats[0]
      else
        notify(:msg => "[#{@name}] Retrieving stats for node #{node_ip} on load balancer #{@config[:host]}",
               :tags => [:f5, :trace])
        stats = with_f5('LocalLB.NodeAddress') do
          get_statistics([ node_ip ])
        end
      end
      # TODO: deal with node not existing (stats is nil)
      if stats['statistics'] && stats['statistics'][0] && stats['statistics'][0]['statistics']
        stats['statistics'][0]['statistics'].each do |stat|
          name = extract_type(stat)
          if name
            # TODO: switch on the type and support all possible values
            if extract_type(stat.value) == 'iControl:Common.ULong64'
              result[name] = (stat.value.high << 32) | stat.value.low
            end
          end
        end
      end
      result
    end

    # Retrieves the number of active connections for a node or pool member. If `pool_name` is specified,
    # then only the stats for that pool are returned.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port; only required if a pool name is given
    # @option params [String] :pool The pool name; optional
    # @return [Integer,nil] The number of active connections
    def get_num_connections(params)
      # TODO: deal with node not existing (nil coming back from get_stats)
      get_stats(params)['STATISTIC_SERVER_SIDE_CURRENT_CONNECTIONS']
    end

    # Enables a node in one or all pools if not already enabled. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, only need if a pool is specified
    # @option params [String] :pool The pool name; if not specified then the node will be enabled
    #                               in all pools that it is a member of
    # @return [Hash,nil] The hash of the node/member `:ip`, `:availability`, `:enabled` and possibly
    #                    `:pool_name`, `:port`, and `:monitor_rule` entries
    def enable(params)
      node_ip = get_ip(params)
      if params.has_key?(:pool)
        pool_name = params[:pool]
        node_port = (params[:port] || 80).to_i
        if @environment.in_dry_run_mode
          notify(:msg => "[#{@name}] Would enable member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          get_member(params)
        else
          notify(:msg => "[#{@name}] Enabling member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :trace])
          set_pool_member_status(pool_name,
                                 'member' => { 'address' => node_ip, 'port' => node_port },
                                 'monitor_state' => 'STATE_ENABLED')
        end
      else
        if @environment.in_dry_run_mode
          node = get_node(params)
          notify(:msg => "[#{@name}] Would enable node #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          node
        else
          notify(:msg => "[#{@name}] Enabling node #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :trace])
          set_node_status(node_ip, 'STATE_ENABLED')
        end
      end
    end

    # Disables a node in one or all pools if not already enabled. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, only need if a pool is specified
    # @option params [String] :pool The pool name; if not specified then the node will be disabled
    #                               in all pools that it is a member of
    # @return [Hash,nil] The hash of the node/member `:ip`, `:availability`, `:enabled` and possibly
    #                    `:pool_name`, `:port`, and `:monitor_rule` entries
    def disable(params)
      node_ip = get_ip(params)
      if params.has_key?(:pool)
        pool_name = params[:pool]
        node_port = (params[:port] || 80).to_i
        if @environment.in_dry_run_mode
          notify(:msg => "[#{@name}] Would disable member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          get_member(params)
        else
          notify(:msg => "[#{@name}] Disabling member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :trace])
          set_pool_member_status(pool_name,
                                 'member' => { 'address' => node_ip, 'port' => node_port },
                                 'session_state' => 'STATE_DISABLED')
        end
      else
        if @environment.in_dry_run_mode
          node = get_node(params)
          notify(:msg => "[#{@name}] Would disable member #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          node
        else
          notify(:msg => "[#{@name}] Disabling node #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :trace])
          set_node_status(node_ip, 'STATE_DISABLED')
        end
      end
    end

    # Synchronizes the configuration to a specified group or all groups that the load balancer is a member of. This
    # method will do nothing in dryrun mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :group The specific group to sync to; if omitted then all groups will be synced to
    # @return [void]
    def sync(params)
      if params.has_key?(:group)
        group = params[:group]
        if @environment.in_dry_run_mode
          notify(:msg => "[#{@name}] Would sync configurations for load balancer #{@config[:host]} to group #{group}",
                 :tags => [:f5, :dryrun])
        else
          notify(:msg => "[#{@name}] Syncing configurations for load balancer #{@config[:host]} to group #{group}",
                 :tags => [:f5, :trace])
          with_f5('System.ConfigSync') do
            synchronize_to_group(group)
          end
        end
      else
        if @environment.in_dry_run_mode
          notify(:msg => "[#{@name}] Would sync configurations for load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
        else
          notify(:msg => "[#{@name}] Syncing configurations for load balancer #{@config[:host]}",
                 :tags => [:f5, :trace])
          with_f5('System.ConfigSync') do
            synchronize_configuration('CONFIGSYNC_ALL')
          end
        end
      end
      nil
    end

    private

    def authenticate
      begin
        @f5 = ::F5::IControl.new(@config[:host],
                                 @config[:auth][:username],
                                 @config[:auth][:password],
                                 ['LocalLB.Pool', 'LocalLB.PoolMember', 'LocalLB.NodeAddress', 'System.ConfigSync']).get_interfaces
      rescue => e
        notify(:msg => "[#{@name}] Error when trying to log in to the load balancer #{@config[:host]} as user #{@config[:auth][:username]}: #{e.message}",
               :tags => [:f5, :error])
        raise e
      end
    end

    def with_f5(interface, &block)
      result = nil
      @monitor.synchronize do
        begin
          result = @f5[interface].instance_eval(&block)
        rescue SOAP::Error => e
          if @config[:auth_type] =~ /^credentials$/ && e.to_s == "401: F5 Authorization Required"
            puts "Invalid username or password. Please try again"
            @environment.resolve_service_auth(:service_name => @name.to_sym, :config => @config, :force => true)
            authenticate
            retry
          else
            if e.faultstring.to_s =~ /Exception\: Common\:\:OperationFailed/
              raise OperationFailed, e.faultstring.to_s, e.backtrace
            else
              raise
            end
          end
        end
      end
      return result
    end

    def get_ip(params)
      if params.has_key?(:host)
        Socket::getaddrinfo(params[:host], nil)[0][3]
      elsif params.has_key?(:ip)
        params[:ip]
      else
        raise "No :host or :ip argument given"
      end
    end

    def set_pool_member_status(pool_name, object_status_hash)
      with_f5('LocalLB.PoolMember') do
        set_session_enabled_state([ pool_name ], [[ object_status_hash ]])
      end
      get_member(:ip => object_status_hash['member']['address'],
                 :port => object_status_hash['member']['port'],
                 :pool => pool_name)
    end

    def set_node_status(node_ip, object_status_hash)
      with_f5('LocalLB.NodeAddress') do
        set_session_enabled_state([ node_ip ], [ object_status_hash ])
      end
      get_node(:ip => node_ip)
    end

    def extract_type(soap_xml_elem)
      soap_xml_elem.__xmlele.each do |item|
        return item[1] if item[0].name == 'type'
      end
      soap_xml_elem.__xmlattr.each do |attribute|
        return attribute[1] if attribute[0].name == 'type'
      end
      nil
    end
  end
end
