require 'cosmos2'
require 'cosmos2/plugin'
begin
  require 'galaxy/command'
  require 'galaxy/console'
  require 'galaxy/versioning'
rescue
  puts "In order to use the galaxy plugin please install the galaxy gem version 2.5.1 or newer (2.5.1.1 if using (J)Ruby 1.9)"
  exit
end

module Cosmos2
  # A galaxy report that gathers results (agents) instead of outputing them to stdout.
  # It optionally can also send messages to the environment. For that purpose, the
  # constructor takes an optional message template and set of tags. The template is
  # evaluated for each individual result (galaxy agent) as a string with the variable
  # `agent` in context. E.g. the template
  #
  #     '[Galaxy] Found agent #{agent.host}'
  #
  # would be evaluated for each agent that the command using the report encounters,
  # and would generate messages using the host attributes of the agents.
  class GalaxyGatheringReport < ::Galaxy::Client::Report
    # The results
    attr_reader :results

    # Creates a new report instance.
    #
    # @param [Environment] environment The cosmos2 environment
    # @param [String,nil] msg_template The message template to use to generate messages
    # @param [Array<Symbol>,Symbol,nil] tags The tags to use for generated messages
    # @return [GalaxyGatheringReport] The new instance
    def initialize(environment, msg_template = nil, tags = [])
      @environment = environment
      @tags = arrayify(tags)
      @msg_template = msg_template
      @results = []
    end

    # Records a single result (galaxy agent). Called by galaxy commands.
    #
    # @param [Galaxy::Agent] agent The agent
    def record_result agent
      @results << agent
      if @msg_template
        @environment.notify(:msg => eval('"' + @msg_template + '"'), :tags => @tags)
      end
    end
  end

  # A plugin that makes galaxy available to cosmos2 scripts. You'd typically create an `:galaxy` plugin section
  # in the configuration and then use it in a cosmos2 context like so:
  #
  #     with galaxy do
  #       snapshot = take_snapshot
  #       services = select :type => /^myservice$?/
  #       update :services => services, :to => 'new-version'
  #       start :services => services
  #     end
  #
  # The galaxy plugin emits messages tagged as `:galaxy` and `:info` for most of its actions.
  # Note that in dry-run mode this plugin will still connect to galaxy and perform non-destructive operations
  # (e.g. {#select} and {#take_snapshot}) but not destructive ones (such as {#update}). Instead, it will send
  # messages tagged as `:galaxy` and `:dryrun` in those cases.
  class Galaxy < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new galaxy plugin instance.
    #
    # @param [Environment] environment The cosmos2 environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Galaxy] The new instance
    def initialize(environment, name = :galaxy)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @galaxy_options = { :console => ::Galaxy::Transport.locate("druby://#{@config[:host] || 'localhost'}:#{@config[:port] || 4440}"),
                          :versioning_policy => @config[:relaxed_versioning] ?
                                                   ::Galaxy::Versioning::RelaxedVersioningPolicy :
                                                   ::Galaxy::Versioning::StrictVersioningPolicy }

    end

    # Takes a snapshot of the current galaxy state, which can be used for instance with #rollback.
    #
    # @return [Array<Galaxy::Agent>] The current state as galaxy sees it, as an array of agents
    def take_snapshot
      select
    end

    # Selects services on galaxy via at most one of the following selectors:
    #
    # * `:path` Regular expression for the full path in galaxy which is of the form
    #           `/<environment>/<version>/<type>`
    # * `:type` Regular expression for only the type component of the path in galaxy
    # * `:host`/`:hosts` The host(s) to select
    #
    # If no selector is specified then this will return all services.
    #
    # @param [Hash] params The parameters
    # @option params [Regexp,String] :path Regular expression for the path selection
    # @option params [Regexp,String] :type Regular expression for the type selection
    # @option params [String] :host A single host to select
    # @option params [String] :hosts The hosts to select
    # @return [Array<Galaxy::Agent>] The selected servies
    def select(params = {})
      if params[:path]
        path_regex = params[:path]
        path_regex = Regexp.new(path_regex.to_s) unless path_regex.is_a?(Regexp)
        selector = lambda {|agent| agent.config_path && path_regex.match(agent.config_path) }
        notify(:msg => "[Galaxy] Selecting all services for path #{path_regex.inspect}",
               :tags => [:galaxy, :info])
      elsif params[:type]
        type_regex = params[:type]
        type_regex = Regexp.new(type_regex.to_s) unless type_regex.is_a?(Regexp)
        selector = lambda {|agent| agent.config_path && type_regex.match(type_of?(agent)) }
        notify(:msg => "[Galaxy] Selecting all services of type #{type_regex.inspect}",
               :tags => [:galaxy, :info])
      elsif params[:host] || params[:hosts]
        host_names = arrayify(params[:host]) & arrayify(params[:hosts])
        selector = lambda {|agent| host_names.include?(agent.host) }
        notify(:msg => "[Galaxy] Selecting all services for hosts #{host_names.inspect}",
               :tags => [:galaxy, :info])
      else
        notify(:msg => "[Galaxy] Selecting all services",
               :tags => [:galaxy, :info])
      end
      command = ::Galaxy::Commands::ShowCommand.new([], @galaxy_options)
      command.report = GalaxyGatheringReport.new(@environment)
      execute_with_agents(command, {})
      command.report.results.select {|result| selector.nil? || selector.call(result) }
    end

    # Assigns a service to a host. Use one of `:service`, `:services`, `:host`, or `:hosts` to
    # select which hosts to assign the service to. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :env The environment
    # @option params [String] :version The version
    # @option params [String] :type The service type
    # @option params [Galaxy::Agent] :service The host/service to assign
    # @option params [Array<Galaxy::Agent>] :services The hosts/services to assign
    # @option params [String] :host The host to assign
    # @option params [String] :hosts The hosts to assign
    # @return [Array<Galaxy::Agent>] The assigned services
    def assign(params)
      env = params[:env] or raise "No :env argument given"
      version = params[:version] or raise "No :version argument given"
      type = params[:type] or raise "No :type argument given"
      dry_run_or_not(params, 'Would assign #{agent.host} to /#{params[:env]}/#{params[:version]}/#{params[:type]}') {
        command = ::Galaxy::Commands::AssignCommand.new([ env, version, type ], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment)
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Starts one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts` to
    # select which hosts/services to start. This method will do nothing in dryrun mode except
    # create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Galaxy::Agent] :service The service to start
    # @option params [Array<Galaxy::Agent>] :services The services to start
    # @option params [String] :host The host to start
    # @option params [String] :hosts The hosts to start
    # @return [Array<Galaxy::Agent>] The started services
    def start(params)
      dry_run_or_not(params, 'Would start #{agent.host}') {
        command = ::Galaxy::Commands::StartCommand.new([], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Started #{agent.host}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Restarts one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts`
    # to select which hosts to restart. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Galaxy::Agent] :service The service to restart
    # @option params [Array<Galaxy::Agent>] :services The services to restart
    # @option params [String] :host The host to restart
    # @option params [String] :hosts The hosts to restart
    # @return [Array<Galaxy::Agent>] The restarted services
    def restart(params)
      dry_run_or_not(params, 'Would restart #{agent.host}') {
        command = ::Galaxy::Commands::RestartCommand.new([], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Restarted #{agent.host}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Stops one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts` to
    # select which hosts to stop. This method will do nothing in dryrun mode except create a
    # message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Galaxy::Agent] :service The service to stop
    # @option params [Array<Galaxy::Agent>] :services The services to stop
    # @option params [String] :host The host to stop
    # @option params [String] :hosts The hosts to stop
    # @return [Array<Galaxy::Agent>] The stopped services
    def stop(params)
      dry_run_or_not(params, 'Would stop #{agent.host}') {
        command = ::Galaxy::Commands::StopCommand.new([], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Stopped #{agent.host}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Updates one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts` to
    # select which hosts to update. This method will do nothing in dryrun mode except create a
    # message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :to The version to update the services to
    # @option params [Galaxy::Agent] :service The service to update
    # @option params [Array<Galaxy::Agent>] :services The services to update
    # @option params [String] :host The host to update
    # @option params [String] :hosts The hosts to update
    # @return [Array<Galaxy::Agent>] The updated services
    def update(params)
      to = params[:to] or raise "No :to argument given"
      dry_run_or_not(params, 'Would update #{agent.host} to version #{params[:to]}') {
        command = ::Galaxy::Commands::UpdateCommand.new([ params[:to] ], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Updated #{agent.host} to #{to}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Updates the confinguration of one or more services. Use one of `:service`, `:services`,
    # `:host`, or `:hosts` to select which hosts to update. This method will do nothing in dryrun
    # mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :to The version to update the confguration of the services to
    # @option params [Galaxy::Agent] :service The service to update the confguration of
    # @option params [Array<Galaxy::Agent>] :services The services to update the confguration of
    # @option params [String] :host The host to update the confguration of
    # @option params [String] :hosts The hosts to update the confguration of
    # @return [Array<Galaxy::Agent>] The updated services
    def update_config(params)
      to = params[:to] or raise "No :to argument given"
      dry_run_or_not(params, 'Would update the config of #{agent.host} to version #{params[:to]}') {
        command = ::Galaxy::Commands::UpdateConfigCommand.new([ params[:to] ], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Updated the configuration of #{agent.host} to #{to}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Rolls back one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts`
    # to select which hosts to roll back. Note that this will simply undo the last deployment for
    # each of the passed-in services. For rolling back an entire deployment but preserving the
    # files of the deployment, it is better to use {#revert}. This method will do nothing in
    # dryrun mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Galaxy::Agent] :service The service to roll back
    # @option params [Array<Galaxy::Agent>] :services The services to roll back
    # @option params [String] :host The host to roll back
    # @option params [String] :hosts The hosts to roll back
    # @return [Array<Galaxy::Agent>] The rolled-back services
    def rollback(params)
      dry_run_or_not(params, 'Would rollback #{agent.host}') {
        command = ::Galaxy::Commands::RollbackCommand.new([], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Rolled back #{agent.host}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    # Reverts one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts`
    # to select which hosts to revert. This method differs from {#rollback} in that you give it takes
    # a previously taken snapshot which specifies the version of that the service should be reverted
    # to. It then will update all passed-in services that are also present in the snapshot (as
    # determined by the ip of the agent), to the version stated in the snapshot. The method also
    # supports reverting multiple different service types to differing versions. This method will
    # do nothing in dryrun mode except create messages tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Array<Galaxy::Agent>,Galaxy::Agent] :to The snapshot to revert to
    # @option params [Galaxy::Agent] :service The service to revert
    # @option params [Array<Galaxy::Agent>] :services The services to revert
    # @option params [String] :host The host to revert
    # @option params [String] :hosts The hosts to revert
    # @return [Array<Galaxy::Agent>] The reverted services
    def revert(params)
      to = params[:to] or raise "No :to argument given"
      services = services_from_params(params)
      ips = services.inject(Set.new) { |ips, agent| ips << agent.ip }
      agents_by_version = arrayify(to).inject(Hash.new) do |by_version, agent|
        if ips.include?(agent.ip)
          version = version_of?(agent)
          for_version = by_version[version]
          by_version[version] = (for_version = []) unless for_version
          for_version << agent
        end
        by_version
      end
      reverted = agents_by_version.map { |version, agents| update(:services => agents, :to => version) }
      reverted.flatten
    end

    # Clears one or more services. Use one of `:service`, `:services`, `:host`, or `:hosts`
    # to select which hosts to clear. This method will do nothing in dryrun mode except create
    # messages tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Galaxy::Agent] :service The service to clear
    # @option params [Array<Galaxy::Agent>] :services The services to clear
    # @option params [String] :host The host to clear
    # @option params [String] :hosts The hosts to clear
    # @return [Array<Galaxy::Agent>] The cleared services
    def clear(params)
      dry_run_or_not(params, 'Would clear #{agent.host}') {
        command = ::Galaxy::Commands::ClearCommand.new([], @galaxy_options)
        command.report = GalaxyGatheringReport.new(@environment, '[Galaxy] Cleared #{agent.host}', [:galaxy, :info])
        command.execute(services_from_params(params))
        command.report.results
      }
    end

    private

    def dry_run_or_not(params, dry_run_msg)
      if @environment.in_dry_run_mode
        to = params[:to] or raise "No :to argument given"
        services = params[:services] || arrayify(params[:service])
        services.each do |agent|
          notify(:msg => eval('"' + dry_run_msg + '"'), :tags => [:galaxy, :dryrun])
        end
        services
      else
        yield # implicit block binding
      end
    end

    def execute_with_agents(command, filters)
      agents = command.select_agents(filters)
      agents.each { |agent| agent.proxy = ::Galaxy::Transport.locate(agent.url) if agent.url }
      command.execute(agents)
    end

    def version_of?(agent)
      agent.config_path.split(/\//, 4)[2]
    end

    def type_of?(agent)
      agent.config_path.split(/\//, 4)[3]
    end

    def services_from_params(params)
      raise "No :service or :services or :host or :hosts argument given" unless params[:service] || params[:services] || params[:host] || params[:hosts]
      services = arrayify(params[:services]) & arrayify(params[:service])
      if params[:host] || params[:hosts]
        host_names = arrayify(params[:host]) & arrayify(params[:hosts])
        services &= select(:hosts => host_names)
      end
      services
    end
  end
end
