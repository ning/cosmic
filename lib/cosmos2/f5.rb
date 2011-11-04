require 'cosmos2'
require 'cosmos2/plugin'
require "socket"
require_with_hint 'f5-icontrol', "In order to use the F5 plugin please install the f5-icontrol gem, version 11.0.0.1 or newer"

module Cosmos2
  class F5 < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new F5 plugin instance.
    #
    # @param [Environment] environment The cosmos2 environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Galaxy] The new instance
    def initialize(environment, name = :galaxy)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      authenticate
    end

    def get_members(params)
      pool_name = params[:pool]
      @f5['LocalLB.PoolMember'].get_object_status([ pool_name ])[0][0]['object_status']
    end

    def enable(params)
      pool_name = params[:pool]
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      set_pool_member_status(pool_name, node_ip, node_port,
                             { 'member' => { 'address' => node_ip, 'port' => node_port },
                               'monitor_state' => 'STATE_ENABLED' })
    end

    def disable(params)
      pool_name = params[:pool]
      node_ip = get_ip(params)
      node_port = (params[:port] || 80).to_i
      set_pool_member_status(pool_name, node_ip, node_port,
                             { 'member' => { 'address' => node_ip, 'port' => node_port },
                               'monitor_state' => 'STATE_DISABLED' })
    end

    private

    def authenticate
      if @environment.in_dry_run_mode
        notify(:msg => "Would connect to F5 instance #{@config[:host]}",
               :tags => [:f5, :dryrun])
      else
        @f5 = F5::IControl.new(@config[:host],
                               @config[:credentials][:username],
                               @config[:credentials][:password],
                               ['LocalLB.Pool', 'LocalLB.PoolMember']).get_interfaces
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

    def set_pool_member_status(pool_name, node_ip, node_port, object_status_hash)
      @f5['LocalLB.PoolMember'].set_monitor_state([ pool_name ], [[ object_status_hash ]])
    end
  end
end
