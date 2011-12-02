require 'cosmos2'
require 'cosmos2/plugin'
require 'socket'
require 'monitor'
require_with_hint 'f5-icontrol', "In order to use the F5 plugin please install the f5-icontrol gem, version 11.0.0.1 or newer"

module Cosmos2
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
    # The plugin's configuration
    attr_reader :config

    # Creates a new F5 plugin instance.
    #
    # @param [Environment] environment The cosmos2 environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Galaxy] The new instance
    def initialize(environment, name = :f5)
      # Using Monitor instead of Mutex as the former is reentrant
      @monitor = Monitor.new
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
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
      pool_name = params[:pool] or raise "No :pool argument given"
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      if @environment.in_dry_run_mode
        notify(:msg => "Would add node node #{node_ip}:#{node_port} to pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :dryrun])
        get_member(params)
      else
        notify(:msg => "[F5] Adding node #{node_ip}:#{node_port} to pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        @monitor.synchronize do
          @f5['LocalLB.Pool'].add_member([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
        end
        if params[:monitor_rule]
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
      pool_name = params[:pool] or raise "No :pool argument given"
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      if @environment.in_dry_run_mode
        notify(:msg => "Would set monitor rule for node #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :dryrun])
      else
        notify(:msg => "[F5] Setting monitor rule for node #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        if params[:monitor_rule]
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
        @monitor.synchronize do
          @f5['LocalLB.PoolMember'].set_monitor_association([ pool_name ], [ monitor_associations ])
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
      pool_name = params[:pool] or raise "No :pool argument given"
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      if @environment.in_dry_run_mode
        notify(:msg => "Would remote node #{node_ip}:#{node_port} from pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :dryrun])
      else
        notify(:msg => "[F5] Removing node #{node_ip}:#{node_port} from pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        @monitor.synchronize do
          @f5['LocalLB.Pool'].remove_member([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
        end
      end
    end

    # Retrieves the members of a pool.
    #
    # @param [Hash] params The parameters
    # @option params [String] :pool The pool name
    # @return [Array<Hash>] The members as hashes with `:pool_name`,, `:ip`, `:port`,
    #                       `:availability`, `:enabled` and `:monitor_rule` entries
    def get_members(params)
      pool_name = params[:pool] or raise "No :pool argument given"
      notify(:msg => "[F5] Retrieving all members for pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :info])
      members = @monitor.synchronize do
        @f5['LocalLB.PoolMember'].get_object_status([ pool_name ])[0].collect do |pool_member|
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
      @monitor.synchronize do
        @f5['LocalLB.PoolMember'].get_monitor_association([ pool_name ])[0].each do |monitor_associations|
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
      pool_name = params[:pool] or raise "No :pool argument given"
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      notify(:msg => "[F5] Retrieving member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :info])
      member = nil
      @monitor.synchronize do
        @f5['LocalLB.PoolMember'].get_object_status([ pool_name ])[0].each do |pool_member|
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
        @monitor.synchronize do
          @f5['LocalLB.PoolMember'].get_monitor_association([ pool_name ])[0].each do |monitor_associations|
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
      notify(:msg => "[F5] Retrieving node #{node_ip} from load balancer #{@config[:host]}",
             :tags => [:f5, :info])
      @monitor.synchronize do
        @f5['LocalLB.NodeAddress'].get_object_status([ node_ip ]).each do |status|
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
      pool_name = params[:pool]
      node_ip = get_ip(params)
      result = {}
      if pool_name
        node_port = (params[:port] || 80).to_i
        notify(:msg => "[F5] Retrieving stats for member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        stats = @monitor.synchronize do
          @f5['LocalLB.PoolMember'].get_statistics([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
        end
        stats = stats[0] if stats[0]
      else
        notify(:msg => "[F5] Retrieving stats for node #{node_ip} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        stats = @monitor.synchronize do
          @f5['LocalLB.NodeAddress'].get_statistics([ node_ip ])
        end
      end
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
      pool_name = params[:pool]
      node_ip = get_ip(params)
      if pool_name
        node_port = (params[:port] || 80).to_i
        if @environment.in_dry_run_mode
          notify(:msg => "Would enable member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          get_member(params)
        else
          notify(:msg => "[F5] Enabling member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :info])
          set_pool_member_status(pool_name,
                                 'member' => { 'address' => node_ip, 'port' => node_port },
                                 'monitor_state' => 'STATE_ENABLED')
        end
      else
        if @environment.in_dry_run_mode
          notify(:msg => "Would enable node #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          get_member(params)
        else
          notify(:msg => "[F5] Enabling node #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :info])
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
      pool_name = params[:pool]
      node_ip = get_ip(params)
      if pool_name
        node_port = (params[:port] || 80).to_i
        if @environment.in_dry_run_mode
          notify(:msg => "Would disable member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          get_member(params)
        else
          notify(:msg => "[F5] Disabling member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :info])
          set_pool_member_status(pool_name,
                                 'member' => { 'address' => node_ip, 'port' => node_port },
                                 'session_state' => 'STATE_DISABLED')
        end
      else
        if @environment.in_dry_run_mode
          notify(:msg => "Would disable member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
                 :tags => [:f5, :dryrun])
          get_member(params)
        else
          notify(:msg => "[F5] Disabling node #{node_ip} on load balancer #{@config[:host]}",
                 :tags => [:f5, :info])
          set_node_status(node_ip, 'STATE_DISABLED')
        end
      end
    end

    # add/remove to/from pool (set 'name' if defined, e.g. to hostname)
    # health check ?

    # Synchronizes the configuration to a specified group or all groups that the load balancer is a member of. This
    # method will do nothing in dryrun mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :group The specific group to sync to; if omitted then all groups will be synced to
    # @return [void]
    def sync(params)
      group = params[:group]
      @monitor.synchronize do
        if group
          @f5['System.ConfigSync'].synchronize_to_group(group)
        else
          @f5['System.ConfigSync'].synchronize_configuration('CONFIGSYNC_ALL')
        end
      end
    end

    private

    def authenticate
      @f5 = ::F5::IControl.new(@config[:host],
                               @config[:credentials][:username],
                               @config[:credentials][:password],
                               ['LocalLB.Pool', 'LocalLB.PoolMember', 'LocalLB.NodeAddress', 'System.ConfigSync']).get_interfaces
    end

    def get_ip(params)
      if params[:host]
        Socket::getaddrinfo(params[:host], nil)[0][3]
      elsif params[:ip]
        params[:ip]
      else
        raise "No :host or :ip argument given"
      end
    end

    def set_pool_member_status(pool_name, object_status_hash)
      @monitor.synchronize do
        @f5['LocalLB.PoolMember'].set_session_enabled_state([ pool_name ], [[ object_status_hash ]])
      end
      get_member(:ip => object_status_hash['member']['address'],
                 :port => object_status_hash['member']['port'],
                 :pool => pool_name)
    end

    def set_node_status(node_ip, object_status_hash)
      @monitor.synchronize do
        @f5['LocalLB.NodeAddress'].set_session_enabled_state([ node_ip ], [ object_status_hash ])
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
