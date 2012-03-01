require 'cosmic'
require 'cosmic/plugin'

require_with_hint 'net/ssh', "In order to use the ssh plugin please run 'gem install net-ssh'"
require_with_hint 'net/scp', "In order to use the ssh plugin please run 'gem install net-scp'"

module Cosmic
  # A plugin that makes SSH and SCP available to Cosmic scripts, e.g. to perform actions on remote
  # servers or to transfer files. You'd typically use it in a Cosmic context like so:
  #
  #     with ssh do
  #       exec :host => host, :cmd => "uname -a"
  #
  #       first = true
  #       upload :host => service.host, :local => local, :remote => remote do |ch, name, sent, total|
  #         print "\r" unless first
  #         print "#{name}: #{sent}/#{total}"
  #         first = false
  #       end
  #       print "\n"
  #     end
  #
  # By default, the plugin assumes that the locally running ssh agent process is configured to
  # interact with the remote servers without needing passwords (i.e. by having keys registered).
  # In this case, it will not need a configuration section unless you want more than one instance
  # of the plugin (which is not really necessary in this case as the plugin does not maintain state).
  #
  # Alternatively, you can configure it to use specific ssh keys, which you can either reference
  # directly in the configuration, or have the plugin fetch them from a specific LDAP path.
  #
  # Lastly, the plugin can determine username & password using the normal environment
  # authentication mechanisms, e.g. from the configuration or from LDAP.
  #
  # Note that this plugin will not actually connect to the remote servers in dry-run mode.
  # Instead it will only send messages tagged as `:ssh` and `:dryrun`.
  class SSH < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new ssh plugin instance.
    #
    # @param [Environment] environment The Cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [SSH] The new instance
    def initialize(environment, name = :ssh)
      @name = name.to_s
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      init_ssh_opts
    end

    # Executes a command on a remote host and returns the output (stdin & stderr combined) of the
    # command.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to connect to 
    # @option params [String] :user The user to use for the ssh connection; if not specified
    #                               then it will use the username from the credentials if configured,
    #                               or the current user
    # @option params [String] :password The password to use for the ssh connection; if not specified
    #                                   then it will use the one from the credentials if configured,
    #                                   or leave it to the ssh agent otherwise (which will use a key
    #                                   if possible or ask otherwise)
    # @option params [String] :cmd The command to run on the host
    # @return [String] All output of the command (stdout and stderr combined)
    def exec(params)
      host = get_param(params, :host)
      cmd = get_param(params, :cmd)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would execute command '#{cmd}' as user #{params[:user] || @config[:auth][:username]} on host #{host}",
               :tags => [:ssh, :dryrun])
      else
        response = nil
        begin
          user = params[:user] || @config[:auth][:username]
          opts = merge_with_ssh_opts(params)
          Net::SSH.start(host, user, opts) do |ssh|
            response = ssh.exec!(cmd)
          end
        rescue Net::SSH::AuthenticationFailed => e
          if @config[:auth_type] =~ /^credentials$/ && !params.has_key?(:password)
            puts "Invalid username or password. Please try again"
            @environment.resolve_service_auth(:service_name => @name.to_sym, :config => @config, :force => true)
            init_ssh_opts
            retry
          else
            raise e
          end
        end
        notify(:msg => "[#{@name}] Executed command '#{cmd}' as user #{user} on host #{host}",
               :tags => [:ssh, :trace])
        response
      end
    end

    # Transfers a local file to a remote host.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to copy the file to
    # @option params [String] :user The user to use for the ssh connection; if not specified
    #                               then it will use the username from the credentials if configured,
    #                               or the current user
    # @option params [String] :password The password to use for the ssh connection; if not specified
    #                                   then it will use the one from the credentials if configured,
    #                                   or leave it to the ssh agent otherwise (which will use a key
    #                                   if possible or ask otherwise)
    # @option params [String] :local The local path to the file to upload
    # @option params [String] :remote The remote path to the file to upload; if not specified then
    #                                 it will use the local path for this
    # @yield An optional block of arity 4 that will be executed whenever a new chunk of data is sent;
    #        the arguments are: the chunk, the filename, the number of bytes sent so far, the size
    #        of the file
    # @return [void]
    def upload(params, &block)
      host = get_param(params, :host)
      local = get_param(params, :local)
      remote = params[:remote] || local
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would upload local file #{local} as user #{params[:user] || @config[:auth][:username]} to host #{host} at #{remote}",
               :tags => [:ssh, :dryrun])
      else
        begin
          user = params[:user] || @config[:auth][:username]
          opts = merge_with_ssh_opts(params)
          Net::SCP.start(host, user, opts) do |scp|
            scp.upload!(local, remote, &block)
          end
        rescue Net::SSH::AuthenticationFailed => e
          if @config[:auth_type] =~ /^credentials$/ && !params.has_key?(:password)
            puts "Invalid username or password. Please try again"
            @environment.resolve_service_auth(:service_name => @name.to_sym, :config => @config, :force => true)
            init_ssh_opts
            retry
          else
            raise e
          end
        end
        notify(:msg => "[#{@name}] Uploaded local file #{local} as user #{user} to host #{host} at #{remote}",
               :tags => [:ssh, :trace])
      end
    end

    # Downloads a remote file from a remote host.
    #
    # @param [Hash] params The parameters
    # @option params [String] :host The host to copy the file to
    # @option params [String] :user The user to use for the ssh connection; if not specified
    #                               then it will use the username from the credentials if configured,
    #                               or the current user
    # @option params [String] :password The password to use for the ssh connection; if not specified
    #                                   then it will use the one from the credentials if configured,
    #                                   or leave it to the ssh agent otherwise (which will use a key
    #                                   if possible or ask otherwise)
    # @option params [String] :local The local target path for the downloaded file to upload; if not
    #                                specified then it will use the remote path for this
    # @option params [String] :remote The remote path to the file to download
    # @yield An optional block of arity 4 that will be executed whenever a new chunk of data is received;
    #        the arguments are: the chunk, the filename, the number of bytes received so far, the size
    #        of the file
    # @return [void]
    def download(params, &block)
      host = get_param(params, :host)
      remote = get_param(params, :remote)
      local = params[:local] || remote
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would download remote file #{remote} as user #{params[:user] || @config[:auth][:username]} from host #{host} to local file #{local}",
               :tags => [:ssh, :dryrun])
      else
        begin
          user = params[:user] || @config[:auth][:username]
          opts = merge_with_ssh_opts(params)
          Net::SCP.start(host, user, merge_with_ssh_opts(params)) do |scp|
            scp.download!(remote, local, &block)
          end
        rescue Net::SSH::AuthenticationFailed => e
          if @config[:auth_type] =~ /^credentials$/ && !params.has_key?(:password)
            puts "Invalid username or password. Please try again"
            @environment.resolve_service_auth(:service_name => @name.to_sym, :config => @config, :force => true)
            init_ssh_opts
            retry
          else
            raise e
          end
        end
        notify(:msg => "[#{@name}] Downloaded remote file #{remote} as user #{user} from host #{host} to local file #{local}",
               :tags => [:ssh, :trace])
      end
    end

    private

    def init_ssh_opts
      @ssh_opts = {}
      if @config[:auth][:keys] || @config[:auth][:key_data]
        @ssh_opts[:keys] = @config[:auth][:keys]
        @ssh_opts[:key_data] = @config[:auth][:key_data]
        @ssh_opts[:keys_only] = true
      elsif @config[:auth][:password]
        @ssh_opts[:password] = @config[:auth][:password]
      end
    end

    def merge_with_ssh_opts(params)
      if params.has_key?(:password)
        @ssh_opts.merge(:password => params[:password])
      else
        @ssh_opts
      end
    end
  end
end
