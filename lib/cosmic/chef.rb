require 'cosmic'
require 'cosmic/plugin'

require_with_hint 'chef/node', "In order to use the chef plugin please run 'gem install chef'"
require_with_hint 'chef/knife', "In order to use the chef plugin please run 'gem install chef'"
require_with_hint 'chef/knife/node_run_list_add', "In order to use the chef plugin please run 'gem install chef'"

module Cosmic
  # A plugin that allows to interact with Chef in Cosmic scripts, e.g. to retrieve information about
  # a server from Ohai or apply a role to a node. You'd typically use it in a Cosmic context like so:
  #
  #     response = with chef do
  #       puts get_info :host => 'foo'
  #     end
  #
  # Note that this plugin will only perform read-only operations (e.g. {#get_info} when in dry-run mode.
  # For other operations it will only send messages tagged as `:chef` and `:dryrun`.
  class Chef < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new chef plugin instance.
    #
    # @param [Environment] environment The Cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Chef] The new instance
    def initialize(environment, name = :chef)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @connections = {}
      @knife = ::Chef::Knife.new
      @knife.config[:verbosity] = 0 # Only error logging for now, TODO configure a Cosmic logger
      @knife.configure_chef
    end

    # Retrieves the info that Chef has for a given host.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to get the info for
    # @return [::Chef::Node,nil] The chef node object for the host if it knows about the host
    def get_info(params)
      host = params[:host] or raise "No :host argument given"
      begin
        ::Chef::Node.load(host)
      rescue Net::HTTPServerException => ex
        if ex.message =~ /404.*/
          nil
        else
          raise ex
        end
      end
    end

    # Adds a role to the run list of a host or node.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to update; use this or `:node`
    # @option params [String] :node The node to update; use this or `:host`
    # @option params [String] :role The name of the role
    # @return [Hash,nil] A hash with the info for the host
    def add_role(params)
      if @environment.in_dry_run_mode
        notify(:msg => "Would add role #{params[:role]} to #{params[:host] || params[:node]} ",
               :tags => [:chef, :dryrun])
        nil
      else
        node = params[:node]
        host = params[:host]
        if !node && !host
          raise "No :host or :node argument given"
        end
        if !node
          node = get_info(params)
        end
        role = params[:role] or raise "No :role argument given"
        ::Chef::Knife::NodeRunListAdd.new.add_to_run_list(node, role)
        get_info(params)
      end
    end
  end
end
