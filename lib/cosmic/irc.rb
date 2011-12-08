require 'cosmic'
require 'cosmic/plugin'

if RUBY_VERSION < '1.9'
  desc = defined?(RUBY_DESCRIPTION) ? RUBY_DESCRIPTION : "ruby #{RUBY_VERSION} (#{RUBY_RELEASE_DATE})"
  abort <<-end_message

    The IRC cosmic plugin requires Ruby 1.9 or newer. You're running #{desc}
    Please upgrade to use it.

  end_message
end

require_with_hint 'cinch', "In order to use the cinch plugin please run 'gem install cinch'"
require_with_hint 'atomic', "In order to use the cinch plugin please run 'gem install atomic'"

module Cosmic
  # A listener for the message bus that outputs messages to an IRC channel.
  class ChannelMessageListener
    # The channel
    attr_reader :channel

    # Creates a new listener instance for the given channel.
    #
    # @param [Cinch::Channel] channel The channel
    # @return [ChannelMessageListener] The new instance
    def initialize(channel)
      @channel = channel
    end

    # Sends a message to this listener.
    #
    # @param [Hash] params The parameters
    # @option params [String] :msg The message
    # @return [void]
    def on_message(params)
      @channel.msg(params[:msg])
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
    # @return [CosmosLogger] The new logger instance
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
      log(message, :debug)
    end

      # This method is used for logging exceptions.
      #
      # @param [Exception] e The exception to log
      # @return [void]
    def log_exception(e)
      log(e.message, :error)
    end

    # This method is used by {#debug} and {#log_exception} to log
    # messages, and also by the IRC parser to log incoming and
    # outgoing messages.
    #
    # @param [String] message The message to log
    # @param [Symbol<:debug, :generic, :incoming, :outgoing>] kind The kind of message to log
    # @return [void]
    def log(message, kind = :generic)
      if @environment
        @environment.notify(:msg => message, :tags => @kind_map[kind])
      end
    end
  end


  # A plugin that makes IRC available to cosmos scripts, mostly as a output target for
  # messages. You'd typically create an `:irc` plugin section in the configuration and then
  # use it in a cosmos context like so:
  #
  #     with irc do
  #       connect channel: '#cosmos', to: [:info, :warn, :error, :galaxy]
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
    # @param [Environment] environment The cosmos environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [IRC] The new instance
    def initialize(environment, name = :irc)
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @config[:nick] ||= 'cosmos'
      @config[:host] ||= 'localhost'
      @config[:port] ||= 6667
      @config[:connection_timeout_sec] ||= 60
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
      msg = params[:msg] or raise "No :msg argument given"
      raise "No :channels argument given" unless params[:channels]
      channels = arrayify(params[:channels])
      if !channels.empty?
        if @environment.in_dry_run_mode
          notify(:msg => "Would write message '#{msg}' to channels #{channels.join(',')}",
                 :tags => [:irc, :dryrun])
        else
          channels.each { |channel| write_to_channel(msg, channel) }
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
      channel_name = params[:channel] or raise "No :channel argument given"
      get_channel_internal(channel_name)
    end

    # Joins a channel and connects it to the message bus. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :channel The channel to join
    # @option params [Array<String>,String] :to The tags for the messages that the plugin should write to the channel
    # @return [Cinch::Channel,nil] The channel if the plugin was able to connect it
    def connect(params)
      channel_name = params[:channel] or raise "No :channel argument given"
      channel = get_channel_internal(channel_name)
      if channel
        @environment.connect_message_listener(:listener => ChannelMessageListener.new(channel), :tags => params[:to])
      end
      channel
    end

    # Disconnects a channel from the message bus but does not leave it. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :channel The channel to disconnect from the message bus
    # @return [Cinch::Channel,nil] The channel
    def disconnect(params)
      channel_name = params[:channel] or raise "No :channel argument given"
      channel = get_channel_internal(channel_name)
      if channel
        @environment.disconnect_message_listener(:listener => ChannelMessageListener.new(channel))
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

    private

    def authenticate
      if @environment.in_dry_run_mode
        notify(:msg => "Would connect to IRC server #{@config[:host]}:#{@config[:port]} with nick #{@config[:nick]}",
               :tags => [:irc, :dryrun])
      else
        config = @config
        environment = @environment
        @bot = Cinch::Bot.new do
          @logger = MessageBusLogger.new(:environment => environment,
                                         :debug => [:irc, :trace],
                                         :generic => [:irc, :trace],
                                         :error => [:irc, :error],
                                         :incoming => [:irc, :trace],
                                         :outgoing => [:irc, :trace])
          configure do |c|
            c.nick     = config[:nick]
            c.server   = config[:host]
            c.port     = config[:port]
            c.password = config[:credentials][:password]
            c.verbose  = false
          end
        end
        connected = do_with_timeout(@config[:connection_timeout_sec]) { |done|
          @bot.on :connect do |m|
            done.value = true
          end
          @bot.start
        }
        if !connected
          @bot.quit
          raise "Could not connect to the irc server #{@config[:host]}:#{@config[:port]}"
        end
      end
    end

    def get_channel_internal(channel_or_name)
      if channel_or_name.is_a?(Cinch::Channel)
        channel = channel_or_name
      elsif @environment.in_dry_run_mode
        notify(:msg => "Would join channel #{channel_or_name.to_s} on IRC server #{@config[:host]}:#{@config[:port]}",
               :tags => [:irc, :dryrun])
        nil
      else
        name = channel_or_name.to_s
        channel = @joined_channels[name]
        if !channel
          channel = Cinch::Channel.new(name, @bot)
          joined = do_with_timeout(@config[:connection_timeout_sec]) { |done|
            @bot.on :join do |m|
              done.value = true if m.channel == channel
            end
            channel.join
          }
          if joined
            @joined_channels[name] = channel
          else
            raise "Could not join the channel #{name} on the irc server #{@config[:host]}:#{@config[:port]}"
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
      done = Atomic.new(false)
      thread = Thread.new do
        yield done # implicit block binding
      end
      start_time = Time.new
      while !done.value && (Time.new - start_time).to_i < timeout
        sleep 10
      end
      if done.value
        true
      else
        thread.exit
        false
      end
    end
  end
end
