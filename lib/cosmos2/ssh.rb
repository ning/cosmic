require 'cosmos2'
require 'cosmos2/plugin'

require_with_hint 'net/ssh', "In order to use the ssh plugin please run 'gem install net-ssh'"

module Cosmos2
  # A plugin that makes SSH and SCP available to cosmos scripts, e.g. to perform actions on remote
  # servers or to transfer files. You'd typically use it in a cosmos context like so:
  #
  #     response = with ssh do
  #       exec :host => host, :user => user, :cmd => "uname -a"
  #     end
  #
  # The plugin assumes that the locally running ssh agent process is configured to interact
  # with the remote servers without needing passwords (i.e. by having keys registered). In this
  # case, it will not need a configuration section unless you want more than one instance of the
  # plugin (which is not really necessary in this case as the plugin does not maintain state).
  #
  # Alternatively, you can configure the plugin with username and password, either directly or
  # via the environment's authentication mechanism (e.g. from ldap). In this case, more than one
  # plugin instance allows you to use different credentials for different remote servers.
  #
  # Note that this plugin will not actually connect to the remote servers in dry-run mode.
  # Instead it will only send messages tagged as `:ssh` and `:dryrun`.
  class SSH < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new ssh plugin instance.
    #
    # @param [Environment] environment The cosmos environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [SSH] The new instance
    def initialize(environment, name = :ssh)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @connections = {}
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
    end

    # Executes a command on a remote host and returns the output (stdin & stderr combined) of the
    # command.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to connect to 
    # @option params [String] :user The user to use for the ssh connection; if not specified
    #                               then it will use the username from the configured credentials
    # @option params [String] :cmd The command to run on the host
    # @return [String] All output of the command (stdout and stderr combined)
    def exec(params)
      host = params[:host]
      user = params[:user] || @config[:credentials][:username]
      password = @config[:credentials][:password]
      cmd = params[:cmd]
      if @environment.in_dry_run_mode
        notify(:msg => "Would connect as user #{user} to host #{host} and execute command '#{cmd}'",
               :tags => [:ssh, :dryrun])
      else
        response = nil
        Net::SSH.start(host, user, :password => password) do |ssh|
          response = ssh.exec!(cmd)
        end
        response
      end
    end

    # Transfers a local file to a remote host.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to copy the file to
    # @option params [String] :user The user to use for the ssh connection; if not specified
    #                               then it will use the username from the configured credentials
    # @option params [String] :local The local path to the file to upload
    # @option params [String] :remote The remote path to the file to upload; if not specified then
    #                                 it will use the local path for this
    # @yield An optional block of arity 4 that will be executed whenever a new chunk of data is sent;
    #        the arguments are: the chunk, the filename, the number of bytes sent so far, the size
    #        of the file
    # @return [void]
    def upload(params, &block)
      host = params[:host]
      user = params[:user] || @config[:credentials][:username]
      password = @config[:credentials][:password]
      local = params[:local]
      remote = params[:remote] || params[:local]
      if @environment.in_dry_run_mode
        notify(:msg => "Would upload local file #{local} as user #{user} to host #{host} at #{remote}",
               :tags => [:ssh, :dryrun])
      else
        response = nil
        Net::SCP.start(host, user, :password => password) do |scp|
          scp.upload!(local, remote, block)
        end
      end
    end

    # Downloads a remote file from a remote host.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to copy the file to
    # @option params [String] :user The user to use for the ssh connection; if not specified
    #                               then it will use the username from the configured credentials
    # @option params [String] :local The local target path for the downloaded file to upload; if not
    #                                specified then it will use the remote path for this
    # @option params [String] :remote The remote path to the file to download
    # @yield An optional block of arity 4 that will be executed whenever a new chunk of data is received;
    #        the arguments are: the chunk, the filename, the number of bytes received so far, the size
    #        of the file
    # @return [void]
    def download(params, &block)
      host = params[:host]
      user = params[:user] || @config[:credentials][:username]
      password = @config[:credentials][:password]
      local = params[:local] || params[:remote]
      remote = params[:remote]
      if @environment.in_dry_run_mode
        notify(:msg => "Would download remote file #{remote} as user #{user} from host #{host} to local file #{local}",
               :tags => [:ssh, :dryrun])
      else
        response = nil
        Net::SCP.start(host, user, :password => password) do |scp|
          scp.download!(remote, local, block)
        end
      end
    end
  end
end
