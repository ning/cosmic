require 'cosmic'
require 'cosmic/plugin'

if RUBY_VERSION < '1.9'
  desc = defined?(RUBY_DESCRIPTION) ? RUBY_DESCRIPTION : "ruby #{RUBY_VERSION} (#{RUBY_RELEASE_DATE})"
  abort <<-end_message

    The IRC cosmic plugin requires Ruby 1.9 or newer. You're running #{desc}
    Please upgrade to use it.

  end_message
end

require_with_hint 'cinch', "In order to use the irc plugin please run 'gem install cinch'"
require_with_hint 'atomic', "In order to use the irc plugin please run 'gem install atomic'"

module Cosmic
  class IRCError < StandardError; end

  # A listener for the message bus that outputs messages to an IRC channel.
  class ChannelMessageListener
    # The channel
    attr_reader :channel
    # Prefix for messages put on the channel
    attr_reader :prefix

    # Creates a new listener instance for the given channel.
    #
    # @param [Cinch::Channel] channel The channel
    # @return [ChannelMessageListener] The new instance
    def initialize(channel, prefix = nil)
      @channel = channel
      @prefix = (prefix.nil? ? '' : prefix)
    end

    # Sends a message to this listener.
    #
    # @param [Hash] params The parameters
    # @option params [String] :msg The message
    # @return [void]
    def on_message(params)
      @channel.msg("#{@prefix}#{params[:msg]}")
    end

    # Compares this listener with another listener and returns true if both represent
    # the same IRC channel connection.
    #
    # @param [ChannelMessageListener] listener The other listener
    # @return [true,false] If the two listeners represent the same IRC channel connection
    def eql?(listener)
      listener && self.class.equal?(listener.class) && @channel == listener.channel
    end

    alias == eql?

    # Calculates the hash code for this listener.
    #
    # @return [Integer] The hash code
    def hash
      @channel.hash
    end
  end

  # Custom Cinch logger that puts log messages onto the message bus.
  class MessageBusLogger < Cinch::Logger::Logger
    # Creates a new logger instance. The parameters are used to configure
    # the environment to log to, plus the tags for each log kind. For
    # example:
    #
    #     MessageBusLogger.new(:environment => @environment,
    #                          :debug => [:irc, :debug])
    #
    # Only messages with log kinds that are mapped to tags will be put onto
    # the message bus, all others will be silently ignored.
    #
    # @param [Hash] params The parameters
    # @option params [Environment] :environment The environment
    # @option params [Array<Symbol>,Symbol] :debug The tags that debug messages should be mapped to
    # @option params [Array<Symbol>,Symbol] :error The tags that error/exception messages should be mapped to
    # @option params [Array<Symbol>,Symbol] :incoming The tags that incoming IRC messages should be mapped to
    # @option params [Array<Symbol>,Symbol] :outgoing The tags that outgoing IRC messages should be mapped to
    # @option params [Array<Symbol>,Symbol] :generic The tags that all other messages should be mapped to
    # @return [MessageBusLogger] The new logger instance
    def initialize(params)
      @environment = params[:environment]
      @kind_map = {}
      @kind_map[:debug] = arrayify(params[:debug])
      @kind_map[:error] = arrayify(params[:error])
      @kind_map[:generic] = arrayify(params[:generic])
      @kind_map[:incoming] = arrayify(params[:incoming])
      @kind_map[:outgoing] = arrayify(params[:outgoing])
    end

    # This method can be used to log custom messages on `:debug` level.
    #
    # @param [String] message The message to log
    # @return [void]
    def debug(message)
      log(message, :debug) unless message.nil?
    end

      # This method is used for logging exceptions.
      #
      # @param [Exception] e The exception to log
      # @return [void]
    def log_exception(e)
      log(e.message, :error) unless e.nil?
    end

    # This method is used by {#debug} and {#log_exception} to log
    # messages, and also by the IRC parser to log incoming and
    # outgoing messages.
    #
    # @param [String] message The message to log
    # @param [Symbol<:debug, :generic, :incoming, :outgoing>] kind The kind of message to log
    # @return [void]
    def log(message, kind = :generic)
      @environment.notify(:msg => message, :tags => @kind_map[kind]) unless @environment.nil? || message.nil?
    end
  end


  # A plugin that makes IRC available to Cosmic scripts, mostly as a output target for
  # messages. You'd typically create an `:irc` plugin section in the configuration and then
  # use it in a Cosmic context like so:
  #
  #     with irc do
  #       connect channel: '#cosmic', to: [:info, :warn, :error, :galaxy]
  #     end
  #
  # The irc plugin emits messages tagged as `:irc` and `:trace` for most of its actions,
  # plus `:irc` and `:error` in case of errors.
  # Note that this plugin will not actually connect to the IRC server in dry-run mode.
  # Instead it will only send messages tagged as `:irc` and `:dryrun`.
  class IRC < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new irc plugin instance and connect it to the configured IRC server. In
    # dryrun mode it will not actually connect but instead create a message tagged as `:dryrun`.
    #
    # @param [Environment] environment The Cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [IRC] The new instance
    def initialize(environment, name = :irc)
      @name = name.to_s
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      raise "No irc host specified in the configuration" unless @config[:host]
      @config[:nick] ||= 'cosmic'
      @config[:port] ||= 6667
      @config[:connection_timeout_sec] ||= 60
      @error_listener = ErrorListener.new
      @joined_channels = {}
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      authenticate
    end

    # Writes a message to one or more channels. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :msg The message to write
    # @option params [String,Array<String>,Cinch::Channel,Array<Cinch::Channel>] :channels The channels to write to
    # @return [void]
    def write(params)
      msg = get_param(params, :msg)
      raise "No :channels argument given" unless params.has_key?(:channels)
      channels = arrayify(params[:channels])
      if !channels.empty?
        if @environment.in_dry_run_mode
          notify(:msg => "[#{@name}] Would write message '#{msg}' to channels #{channels.join(',')}",
                 :tags => [:irc, :dryrun])
        else
          channels.each { |channel| write_to_channel(msg, channel) }
          notify(:msg => "[#{@name}] Wrote message '#{msg}' to channels #{channels.join(',')}",
                 :tags => [:irc, :trace])
        end
      end
    end

    # Joins a channel and returns an object representing the channel. This method will do nothing in dryrun
    # mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :channel The channel to join
    # @return [Cinch::Channel,nil] The channel if the plugin was able to join it
    def join(params)
      channel_name = get_param(params, :channel)
      get_channel_internal(channel_name)
    end

    # Joins a channel and connects it to the message bus. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Cinch::Channel,String] :channel The channel to connect
    # @option params [Array<String>,String] :to The tags for the messages that the plugin should write to the channel
    # @option params [String] :prefix An optional prefix to use when writing to the channel
    # @return [Cinch::Channel,nil] The channel if the plugin was able to connect it
    def connect(params)
      channel_or_name = get_param(params, :channel)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would connect the message bus to channel #{channel_or_name} for tags #{params[:to]}",
               :tags => [:irc, :dryrun])
      else
        channel = get_channel_internal(channel_or_name)
        if channel
          # we do this before the actual action so that the message doesn't show up
          # in the channel itself (if trace happens to be in the tags)
          notify(:msg => "[#{@name}] Connected the message bus to channel #{channel_or_name} for tags #{params[:to]}",
                 :tags => [:irc, :trace])
          listener = ChannelMessageListener.new(channel, params[:prefix])
          @environment.connect_message_listener(:listener => listener, :tags => params[:to])
        end
      end
      channel
    end

    # Disconnects a channel from the message bus but does not leave it. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Cinch::Channel,String] :channel The channel to disconnect from the message bus
    # @return [Cinch::Channel,nil] The channel
    def disconnect(params)
      channel_or_name = get_param(params, :channel)
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would disconnect the message bus from channel #{channel_or_name}",
               :tags => [:irc, :dryrun])
      else
        channel = get_channel_internal(channel_or_name)
        if channel
          @environment.disconnect_message_listener(:listener => ChannelMessageListener.new(channel))
          notify(:msg => "[#{@name}] Disconnected the message bus from channel #{channel_or_name}",
                 :tags => [:irc, :trace])
        end
      end
      channel
    end

    # Leaves a channel after disconnecting from the message bus if necessary. This method will do nothing in dryrun
    # mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :channel The channel to leave
    # @option params [String] :msg An optional message to send 
    # @return [void]
    def leave(params)
      channel = disconnect(params)
      if channel
        channel.part(params[:msg])
        @joined_channels.delete(channel.name)
      end
    end

    # Shuts down this IRC plugin instance by quitting from the server.
    def shutdown
      if @bot
        channels = Array.new(@joined_channels.values)
        channels.each do |channel|
          disconnect(:channel => channel)
        end
        @bot.quit
      end
    end

    private

    class ErrorListener
      def initialize
        @mutex = Mutex.new
        @errors = {}
      end

      def reset
        @mutex.synchronize do
          @errors.clear()
        end
      end

      def add_error(code, msg)
        @mutex.synchronize do
          @errors[code] = msg
        end
      end

      def has_errors?
        @mutex.synchronize do
          return !@errors.empty?
        end
      end

      def errors
        result = {}
        @mutex.synchronize do
          result.merge!(@errors)
          @errors.clear()
        end
        result
      end
    end

    class Result
      attr_accessor :errors

      def initialize
        @success = Atomic.new(false)
      end

      def success=(value)
        @success.value = value
      end

      def success
        @success.value
      end

      def has_errors?
        !@errors.nil? && !@errors.empty?
      end
    end

    def authenticate
      host = @config[:host]
      port = @config[:port]
      nick = @config[:nick]
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would connect to IRC server #{host}:#{port} with nick #{nick}",
               :tags => [:irc, :dryrun])
      else
        logged_in = false
        while !logged_in
          username = @config[:auth][:username]
          password = @config[:auth][:password]
          timeout = @config[:connection_timeout_sec]
          environment = @environment
          @bot = Cinch::Bot.new do
            @logger = MessageBusLogger.new(:environment => environment,
                                           :generic => [:irc, :trace],
                                           :error => [:irc, :error])
            configure do |c|
              c.nick     = nick
              c.server   = host
              c.port     = port
              c.user     = username unless username.nil? || username == ""
              c.password = password unless password.nil? || password == ""
              c.verbose  = false
              c.timeouts.connect = timeout
            end
          end
          me = self
          error_listener = @error_listener
          result = do_with_timeout(@config[:connection_timeout_sec]) { |result|
            bot = @bot # for reference within the handler below
            @bot.on :connect do |m|
              result.success = true
            end
            @bot.on :error do |m|
              if m.raw =~ /(?:\:[^\s]*\s+)?(\d+)\s+(.*)/
                code = $1.to_i
                text = $2
                error_listener.add_error code, text
                if (code == 461 && text =~ /\:Not enough parameters/) || code == 464
                  bot.config.reconnect = false
                end
              end
            end
            @bot.start
          }
          if result.success
            notify(:msg => "[#{@name}] Connected to IRC server #{host}:#{port} with nick #{nick}",
                   :tags => [:irc, :trace])
          else
            @bot.config.reconnect = false
            @bot.quit
            quit_time = Time.now.to_i

            should_retry = false
            if @config[:auth_type] =~ /^credentials$/ && result.has_errors?
              # Let's check for errors that we can retry
              if result.errors[461] =~ /USER \:Not enough parameters/
                puts "The IRC server at #{host}:#{port} requires a username. Please try again"
                should_retry = true
              elsif result.errors[461] =~ /PASS \:Not enough parameters/
                puts "The IRC server at #{host}:#{port} requires a password. Please try again"
                should_retry = true
              elsif !result.errors[464].nil?
                puts "Invalid username or password. Please try again"
                should_retry = true
              end
            end
            if should_retry
              @environment.resolve_service_auth(:service_name => @name.to_sym, :config => @config, :force => true)

              # Now we need to wait for the bot to quit retrying. Unfortunately
              # there is no way to tell whether the bot has stopped retrying
              # so we'll actually have to wait here
              # see https://github.com/cinchrb/cinch/issues/63
              # What's worse is that there is no max retry time limit in cinch
              # in version 1.1.3, so the object might actually wait forever
              # So instead we'll simply wait 30sec altogether and hope for the best for now
              wait_time = 30 - (Time.now.to_i - quit_time)

              if wait_time > 0
                puts "Need to wait #{wait_time} seconds before trying to connect to the IRC server again"
                sleep(wait_time)
              end
            else
              raise IRCError, "Could not connect to the irc server #{host}:#{port}"
            end
          end
        end
      end
    end

    def get_channel_internal(channel_or_name)
      if channel_or_name.is_a?(Cinch::Channel)
        channel = channel_or_name
      elsif @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would join channel #{channel_or_name.to_s}",
               :tags => [:irc, :dryrun])
        nil
      else
        name = channel_or_name.to_s
        channel = @joined_channels[name]
        if channel.nil?
          me = self
          channel = Cinch::Channel.new(name, @bot)
          result = do_with_timeout(@config[:connection_timeout_sec]) { |finished|
            @bot.on :join do |m|
              if m.channel == channel
                finished.value = true
              end
            end
            channel.join
          }
          if result.success
            notify(:msg => "[#{@name}] Joined channel #{name}",
                   :tags => [:irc, :trace])
            @joined_channels[name] = channel
          else
            if result.has_errors?
              # TODO
              raise IRCError, "Foo"
            else
              raise IRCError, "Could not join the channel #{name}"
            end
          end
        end
      end
      channel
    end

    def write_to_channel(msg, channel_or_name)
      channel = get_channel_internal(channel_or_name)
      if channel
        channel.msg(msg)
      end
    end

    def do_with_timeout(timeout)
      @error_listener.reset
      result = Result.new
      thread = Thread.new do
        yield result # implicit block binding
      end
      start_time = Time.new
      while !result.success && !@error_listener.has_errors? && (Time.new - start_time).to_i < timeout
        sleep 1
      end
      result.errors = @error_listener.errors
      result
    end
  end
end
