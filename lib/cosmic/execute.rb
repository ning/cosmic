require 'cosmic'
require 'cosmic/plugin'

JRUBY = defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby'

require_with_hint 'open4', "In order to use the exec plugin please run 'gem install open4'" unless JRUBY

module Cosmic
  # A plugin that provides scripts a simple way of executing commands and capturing their output.
  # You'd typically use it in a cosmos context like so:
  #
  #     output = with execute do
  #       exec :cmd => "uname -a"
  #     end
  #
  # This plugin does not need any configuration.
  #
  # Note that this plugin will not actually execute the command in dry-run mode.
  # Instead it will only send messages tagged as `:execute` and `:dryrun`.
  class Execute < Plugin
    # Creates a new exec plugin instance.
    #
    # @param [Environment] environment The cosmos environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Exec] The new instance
    def initialize(environment, name = :execute)
      @environment = environment
    end

    # Executes a command and returns the output (stdin & stderr combined) of the command.
    #
    # @param [Hash] params The parameters
    # @option params [String] :cmd The command to run
    # @return [Array<Integer, String>] The status and output of the command (stdout and stderr
    #                                  combined)
    def exec(params)
      cmd = params[:cmd] or raise "No :cmd argument given"
      if @environment.in_dry_run_mode
        notify(:msg => "Would execute command '#{cmd}'",
               :tags => [:execute, :dryrun])
      else
        output = ""
        pid, ignored, stdout, stderr = (JRUBY ? IO : Open4).send(:popen4, cmd)
        threads = []
        threads << Thread.new(stdout) do |out|
          out.each do |line|
            output << "\n#{line.chomp.strip}"
          end
        end
        threads << Thread.new(stderr) do |err|
          err.each do |line|
            output << "\n#{line.chomp.strip}"
          end
        end
        threads.each do |thread|
          thread.join
        end
        begin
          Process.getpgid(pid)
          ignored, status = Process.waitpid2(pid)
          exitstatus = status.exitstatus
        rescue Errno::ESRCH
          exitstatus = 0
        end
        return [exitstatus, output.strip]
      end
    end
  end
end
