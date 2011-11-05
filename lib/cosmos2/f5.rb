require 'cosmos2'
require 'cosmos2/plugin'
require "socket"
require_with_hint 'f5-icontrol', "In order to use the F5 plugin please install the f5-icontrol gem, version 11.0.0.1 or newer"

module Cosmos2
  # A plugin to interact with an F5 load balancer:
  #
  #     with f5 do
  #       enable :ip => node_ip
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
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      authenticate
    end

    # Retrieves the members of a pool.
    #
    # @param [Hash] params The parameters
    # @option params [String] :pool The pool name
    # @return [Array<Hash>] The members as hashes with `:ip`, `:port`, `:availability`, and `:enabled` entries
    def get_members(params)
      pool_name = params[:pool]
      notify(:msg => "[F5] Retrieving all members for pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :info])
      @f5['LocalLB.PoolMember'].get_object_status([ pool_name ])[0].collect do |pool_member|
        member = pool_member['member']
        status = pool_member['object_status']
        { :ip => member['address'],
          :port => member['port'],
          :availability => status['availability_status'],
          :enabled => (status['enabled_status'] == 'ENABLED_STATUS_ENABLED') }
      end
    end

    # Retrieves a member of a pool.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port
    # @option params [String] :pool The pool name
    # @return [Hash,nil] The member as a hash with `:ip`, `:port`, `:availability`, and `:enabled` entries
    def get_member(params)
      pool_name = params[:pool]
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      notify(:msg => "[F5] Retrieving member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :info])
      @f5['LocalLB.PoolMember'].get_object_status([ pool_name ])[0].collect do |pool_member|
        member = pool_member['member']
        status = pool_member['object_status']
        if member['address'] == node_ip && member['port'] == node_port
          return { :ip => member['address'],
                   :port => member['port'],
                   :availability => status['availability_status'],
                   :enabled => (status['enabled_status'] == 'ENABLED_STATUS_ENABLED') }
        end
      end
      nil
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
      @f5['LocalLB.NodeAddress'].get_object_status([ node_ip ]).each do |status|
        return { :ip => node_ip,
                 :availability => status['availability_status'],
                 :enabled => (status['enabled_status'] == 'ENABLED_STATUS_ENABLED') }
      end
    end

    # Retrieves statistics for a pool member.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port
    # @option params [String] :pool The pool name
    # @return [Hash,nil] The statistics as a hash of statistics name to current value
    def get_member_stats(params)
      pool_name = params[:pool]
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      notify(:msg => "[F5] Retrieving stats for member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
             :tags => [:f5, :info])
      stats = @f5['LocalLB.PoolMember'].get_statistics([ pool_name ], [[{ 'address' => node_ip, 'port' => node_port }]])
      result = {}
      if stats[0] && stats[0]['statistics'] && stats[0]['statistics'][0] && stats[0]['statistics'][0]['statistics']
        stats[0]['statistics'][0]['statistics'].each do |stat|
          name = extract_type(stat)
          if name
            # TODO: switch on the type and create the proper value
            if extract_type(stat.value) == 'iControl:Common.ULong64'
              result[name] = (stat.value.high << 32) | stat.value.low
            end
          end
        end
      end
      result
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

    # Enables a node in one or all pools if not already enabled. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The node's hostname; specify this or the node's `:ip`
    # @option params [String] :ip The node's ip address; specify this or the node's `:host`
    # @option params [String] :port The node's port, only need if a pool is specified
    # @option params [String] :pool The pool name; if not specified then the node will be enabled
    #                               in all pools that it is a member of
    # @return [Hash,nil] The hash of the node/member `:ip`, `:availability`, `:enabled` and possibly `:port` entries
    def enable(params)
      pool_name = params[:pool]
      node_ip = get_ip(params)
      if pool_name
        node_port = (params[:port] || 80).to_i
        notify(:msg => "[F5] Enabling member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        set_pool_member_status(pool_name,
                               'member' => { 'address' => node_ip, 'port' => node_port },
                               'monitor_state' => 'STATE_ENABLED')
      else
        notify(:msg => "[F5] Enabling node #{node_ip} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        set_node_status(node_ip, 'STATE_ENABLED')
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
    # @return [Hash,nil] The hash of the node/member `:ip`, `:availability`, `:enabled` and possibly `:port` entries
    def disable(params)
      pool_name = params[:pool]
      node_ip = get_ip(params)
      if pool_name
        node_port = (params[:port] || 80).to_i
        notify(:msg => "[F5] Disabling member #{node_ip}:#{node_port} in pool #{pool_name} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        set_pool_member_status(pool_name,
                               'member' => { 'address' => node_ip, 'port' => node_port },
                               'monitor_state' => 'STATE_DISABLED')
      else
        notify(:msg => "[F5] Disabling node #{node_ip} on load balancer #{@config[:host]}",
               :tags => [:f5, :info])
        set_node_status(node_ip, 'STATE_DISABLED')
      end
    end

    # number of connections
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
      if group
        @f5['System.ConfigSync'].synchronize_to_group(group)
      else
        @f5['System.ConfigSync'].synchronize_configuration('CONFIGSYNC_ALL')
      end
    end

    private

    def authenticate
      if @environment.in_dry_run_mode
        notify(:msg => "Would connect to F5 instance #{@config[:host]}",
               :tags => [:f5, :dryrun])
      else
        @f5 = ::F5::IControl.new(@config[:host],
                                 @config[:credentials][:username],
                                 @config[:credentials][:password],
                                 ['LocalLB.Pool', 'LocalLB.PoolMember', 'LocalLB.NodeAddress', 'System.ConfigSync']).get_interfaces
      end
    end

    def get_ip(params)
      if params[:host]
        Socket::getaddrinfo(params[:host], nil)[0][3]
      elsif params[:ip]
        params[:ip]
      else
        raise "Need either :host or :ip parameter"
      end
    end

    def set_pool_member_status(pool_name, object_status_hash)
      @f5['LocalLB.PoolMember'].set_monitor_state([ pool_name ], [[ object_status_hash ]])
      get_member(:ip => object_status_hash['member']['address'],
                 :port => object_status_hash['member']['port'],
                 :pool => pool_name)
    end

    def set_node_status(node_ip, object_status_hash)
      @f5['LocalLB.NodeAddress'].set_monitor_state([ node_ip ], [ object_status_hash ])
      get_node(:ip => node_ip)
    end
  end
end
