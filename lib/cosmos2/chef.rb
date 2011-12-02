require 'cosmos2'
require 'cosmos2/plugin'

require_with_hint 'chef/knife', "In order to use the chef plugin please run 'gem install chef'"
require_with_hint 'chef/node', "In order to use the chef plugin please run 'gem install chef'"

module Cosmos2
  # A plugin that allows to interact with Chef in cosmos scripts, e.g. to retrieve information about
  # a server from Ohai or apply a role to a node. You'd typically use it in a cosmos context like so:
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
    # @param [Environment] environment The cosmos environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Chef] The new instance
    def initialize(environment, name = :chef)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @connections = {}
      @knife = Chef::Knife.new
      @knife.config[:verbosity] = 0 # Only error logging for now, TODO configure a cosmos logger
      @knife.configure_chef
    end

    # Retrieves the info that Chef has for a given host.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to get the info for
    # @return [Hash,nil] A hash with the info for the host
    def get_info(params)
      host = params[:host] or raise "No :host argument given"
      Chef::Node.load(host)
    end
  end
end
