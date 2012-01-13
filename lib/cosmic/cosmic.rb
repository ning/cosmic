require 'highline/import'
require 'net/ldap'
require 'yaml'
require 'set'
require 'logger'

# Runs a block in the context of an object. This is similar to the `with` keyword
# in Pascal or JavaScript. For example:
#
#     str = "Hello World"
#     with str do
#       puts reverse
#     end
#
# It also supports blocks with arity of 1:
#
#     str = "Hello World"
#     with str do |my_str|
#       puts my_str.reverse
#     end
#
# @param [Object, nil] obj The object that serves as the context for the block. If `nil` then
#                          the block won't be executed
# @yield A block of arity 0 or 1 that will be executed in the context of the given object
# @return [Object, nil] The return value of the block if any. If the block is not
#                       executed because the object is `nil`, then nothing will be
#                       returned
def with(obj, &block)
  if obj && block_given?
    if block.arity == 1
      yield obj
    else
      obj.instance_eval(&block)
    end
  end
end

# This is the same as `#with` except that it will only run the block in the context of the object
# if the object is not an instance of `Cosmic::HoneyPot`. In effect this means that you'd use
# this in cases where a plugin is not configured but used in a script and you don't want to
# run code using the plugin at all.
#
# @param [Object, nil] obj The object that serves as the context for the block. If `nil` or an
#                          instance of `Cosmic::HoneyPot` then the block won't be executed
# @yield A block of arity 0 or 1 that will be executed in the context of the given object
# @return [Object, nil] The return value of the block if any. If the block is not
#                       executed because the object is `nil`, then nothing will be
#                       returned
def with_available(obj, &block)
  if obj && !obj.is_a?(Cosmic::HoneyPot) && block_given?
    if block.arity == 1
      yield obj
    else
      obj.instance_eval(&block)
    end
  end
end

# Wraps the given object in an array unless it is already one. If passed `nil` then
# it will return an empty array.
#
# @param [Object] obj The object to arrayify
# @return [Array] The object if it is already an array, or an empty array if given `nil`.
#                 Otherwise an array with the object as the single element
def arrayify(obj)
  if obj
    if obj.is_a?(Array)
      obj
    else
      [obj]
    end
  else
    []
  end
end

# Helper method that runs a block peridically until the block returns
# a non `nil` value or a certain amount of time has passed
#
# @params [Integer] timeout The timeout to wait in seconds
# @params [Integer] sleep_time How long to wait between executions of the block
# @yield The block of arity 0 that will be executed
# @return The result of the block if any
def repeat_until_result(timeout = 60, sleep_time = 5)
  raise "No block given" unless block_given?
  start_time = Time.new.to_i
  while Time.new.to_i - start_time < timeout
    result = yield
    return result if result
    sleep sleep_time
  end
end

# A version of the `require` method that prints out an optional text telling the user
# how to fix the load problem.
#
# @param [String] what What to load
# @param [String] hint An optional hint to show if the thing could not be loaded
# @return [true,false] Whether the module was loaded (`true`) or it was already loaded
#                      before (`false`)
def require_with_hint(what, hint)
  begin
    require what
  rescue LoadError => e
    puts hint
    raise e
  end
end

# The main cosmic namespace.
module Cosmic
  # Represents the message passing facility in between the environment or plugins.
  # Each message on the bus has a set of tags. Interested parties register
  # themselves as listeners for messages that have specific tags. The bus then
  # guarantees that whenever a message is sent on the bus (via `notify`) then all
  # listeners that expressed interest in the one of tags of the message, will receive
  # the message. The bus will call the listener in order of registration, and all
  # calls happen sequentially in the thread that generates the message.
  class MessageBus
    # Creates a new message bus without any listeners.
    #
    # @return [Environment] The new instance
    def initialize
      @listeners = []
    end

    # Adds a listener for specific set of tags. Doesn't do anything if no listener
    # or no tags were specified.
    #
    # @param [Object] listener The listener. Must respond to the method
    #                          `on_message({:msg => message, :tags => tags})`
    # @param [Array<Symbol>, Symbol] tags The tags that the listener is interested in
    # @return [void]
    def add_listener(listener, tags)
      tag_set = Set.new(arrayify(tags))
      if listener && !tag_set.empty?
        @listeners.push({ :listener => listener, :tags => tag_set })
      end
    end

    # Removes a listener. Doesn't do anything if no listener was specified.
    #
    # @param [Object] listener The listener to remove
    # @return [void]
    def remove_listener(listener)
      if listener
        @listeners.delete_if { |registration| registration[:listener] == listener }
      end
    end

    # Notifies all listeners of a new message. Doesn't do anything if no listener
    # or no tags were specified.
    #
    # @param [Object] msg The message
    # @param [Array<Symbol>, Symbol] tags The tags for the message
    # @return [void]
    def notify(msg, tags)
      tag_set = Set.new(arrayify(tags))
      if msg && !tag_set.empty?
        @listeners.each do |listener_hash|
          if !(listener_hash[:tags] & tag_set).empty?
            listener_hash[:listener].on_message(:msg => msg, :tags => tags)
          end
        end
      end
    end

    # Shuts down this message bus by removing all listeners.
    def shutdown
      @listeners.clear
    end
  end

  # Helper class that responds to any method call with itself.
  class HoneyPot
    # Catches all method calls to the honey pot and returns itself.
    #
    # @param [Symbol] method_sym The method symbol to call
    # @param [Array<Object>] args The invocation arguments
    # @yield An optional block which however will never be executed
    # @return [HoneyPot] The honey pot itself
    def method_missing(method_sym, *args, &block)
      self
    end

    # Returns `true` for every passed method symbol indicating
    # that the object has that method.
    #
    # @param [Symbol] method_sym The method symbol to check
    # @param [true,false] include_private Whether to include private methods. Is ignored
    # @return [true] Always returns `true`
    def respond_to?(method_sym, include_private = false)
      true
    end
  end

  # Simple message listener that outputs messages to stdout.
  class StdoutListener
    # Called by the message bus on messages.
    #
    # @param [Hash] params The parameters
    # @option params [Object] :msg The message
    # @option params [Array<Symbol>] :tags The message's tags
    # @return [void]
    def on_message(params)
      puts params[:msg]
    end
  end

  # Simple message listener that outputs messages to stderr.
  class StderrListener
    # Called by the message bus on messages.
    #
    # @param [Hash] params The parameters
    # @option params [Object] :msg The message
    # @option params [Array<Symbol>] :tags The message's tags
    # @return [void]
    def on_message(params)
      $stderr.puts params[:msg]
    end
  end

  # Custom logger for plugins that puts log messages onto the message bus.
  class CosmicLogger < Logger
    # Creates a new logger instance. The parameters are used to configure
    # the environment to log to, plus the tags for each log level. For
    # example:
    #
    #     CosmicLogger.new(:environment => @environment,
    #                      Logger::WARN => :warn,
    #                     Logger::ERROR => [:error,:fatal])
    #
    # Only messages with log levels that are mapped to tags will be put onto
    # the message bus, all others will be silently ignored.
    #
    # @param [Hash] params The parameters
    # @option params [Environment] :environment The environment
    # @option params [Array<Symbol>,Symbol] Logger::DEBUG The tags that debug messages should be mapped to
    # @option params [Array<Symbol>,Symbol] Logger::INFO The tags that info messages should be mapped to
    # @option params [Array<Symbol>,Symbol] Logger::WARN The tags that warn messages should be mapped to
    # @option params [Array<Symbol>,Symbol] Logger::ERROR The tags that error messages should be mapped to
    # @option params [Array<Symbol>,Symbol] Logger::FATAL The tags that fatal messages should be mapped to
    # @option params [Array<Symbol>,Symbol] Logger::UNKNOWN The tags that messages with unknown severity should be mapped to
    # @return [CosmicLogger] The new logger instance
    def initialize(params)
      @environment = params[:environment]
      @level_map = {}
      @level_map['DEBUG'] = arrayify(params[Logger::DEBUG])
      @level_map['INFO'] = arrayify(params[Logger::INFO])
      @level_map['WARN'] = arrayify(params[Logger::WARN])
      @level_map['ERROR'] = arrayify(params[Logger::ERROR])
      @level_map['FATAL'] = arrayify(params[Logger::FATAL])
      @level_map['UNKNOWN'] = arrayify(params[Logger::UNKNOWN])
      @level_map['ANY'] = arrayify(params[Logger::UNKNOWN])
    end

    # Base logger method responsible for dealing with a specific message.
    #
    # @param [String] severity The severity of the message
    # @param [Time] timestamp The time of the message, ignored
    # @param [String] progname The name of the logging program, ignored
    # @param [String] msg The message
    def format_message(severity, timestamp, progname, msg)
      tags = @level_map[severity]
      if tags
        @environment.notify(:msg => msg, :tags => tags)
      end
    end
  end

  # Represents the environment in which plugins are run.
  class Environment
    # The complete configuration
    attr_reader :config
    # Whether dry run mode is turned on (off by default)
    attr_reader :in_dry_run_mode

    # Creates a new environment instance from the configuration in a file. The 
    # passed-in parameters hash is merged on top of the file configuration
    # thus allowing to modify configuration settings before the environment is
    # created. If no file was specified, then it will try to load `.cosmicrc` in
    # the current folder first, and if that fails, then `.cosmicrc` in the home
    # folder of the current user. If these don't exist either, then it will return
    # an environment which is configured using only the passed in parameters.
    #
    # @param [Hash] params The parameters, may contain config overrides
    # @option params [String,nil] :config_file The path to the configuration file
    # @return [Environment] The new environment instance
    def self.from_config_file(params = {})
      config = read_rc(params[:config_file])
      config = {} unless config && config.is_a?(Hash)
      Environment.new(config.merge(params))
    end

    # Creates a new environment instance from the given configuration settings.
    # See the configuration documentation for details.
    #
    # @param [Hash] config_hash The configuration
    # @return [Environment] The new instance
    def initialize(config_hash = {})
      @config = unify_keys(config_hash)
      @in_dry_run_mode = @config[:dry_run_mode] || false # we don't allow changing after the environment object is created
      @cached_plugins = {}
      @message_bus = MessageBus.new
      if @config[:verbose] === true
        @message_bus.add_listener(StdoutListener.new, [:dryrun, :warn, :info, :trace])
      else
        @message_bus.add_listener(StdoutListener.new, [:dryrun, :warn, :info])
      end
      @message_bus.add_listener(StderrListener.new, :error)
      authenticate
    end

    # Returns the configuration section for the indicated plugin.
    #
    # @param [Hash] params The parameters
    # @option params [Symbol] :name The plugin's name
    # @return [Hash] The plugin's config or an empty hash if not found or no name given
    def get_plugin_config(params)
      if @config[:plugins] && params[:name]
        @config[:plugins][params[:name].to_sym] || {}
      else
        {}
      end
    end

    # Helper method for plugins to resolve authentication tokens from the
    # environment. The environment understands several different authentication
    # schemes which are explained in detail in the configuration documentation.
    # When successful, then it will update `params[:config][:auth][:username]`
    # and `params[:config][:auth][:password]` with the resolved credentials,
    # or `params[:config][:auth][:key_data]` with the key data read from the
    # environment (e.g. for ssh private keys).
    #
    # @param [Hash] params The parameters
    # @option params [Symbol] :service_name The service name, e.g. `:irc`
    # @option params [Hash] :config The service's configuration
    # @return [void]
    def resolve_service_auth(params)
      return unless params[:service_name] && params[:config]
      service_name = params[:service_name].to_sym
      service_config = params[:config]
      service_config[:auth] ||= {}
      auth_config = service_config[:auth]

      if service_config[:credentials]
        username = service_config[:credentials][:username]
        password = service_config[:credentials][:password]
      end
      case service_config[:auth_type]
        when /^credentials_from_env$/
          username, password = get_service_credentials_from_env(service_name, service_config)
        when /^ldap_credentials$/
          if service_config[:ldap] && service_config[:ldap][:auth]
            username = service_config[:ldap][:auth][:username]
            password = service_config[:ldap][:auth][:password]
          elsif @config[:ldap] && @config[:ldap][:auth]
            username = @config[:ldap][:auth][:username]
            password = @config[:ldap][:auth][:password]
          end
        when /^credentials$/
          if !username && !password
            username = ask("Username for #{service_name.to_s}?\n")
            password = ask("Password for #{service_name.to_s}?\n") { |q| q.echo = false }
          end
        when /^keys$/
          auth_config[:keys] = arrayify(service_config[:keys])
        when /^keys_from_env$/
          if service_config[:ldap]
            path = service_config[:ldap][:key_path] || ldapify_username(@config[:ldap][:auth][:username])
            attrs = arrayify(service_config[:ldap][:key_attrs])
            if path && attrs.length > 0
              key_entry = first_or_nil(get_from_ldap(:path => path))
              if key_entry
                key_data = []
                attrs.each do |attr_name|
                  attr_value = first_or_nil(key_entry[attr_name])
                  key_data << attr_value if attr_value
                end
                auth_config[:key_data] = key_data if key_data.length > 0
              end
            end
          end
      end
      auth_config[:username] = username
      auth_config[:password] = password
    end

    # If Cosmic is connected to an LDAP server, then this method
    # will return the entry referenced by the given path.
    #
    # @param [Hash] params The parameters
    # @option params [String] :path The LDAP path to the desired entry
    # @return [Net::LDAP::Entry,nil] The entry or nil if the path doesn't exist
    def get_from_ldap(params)
      case @config[:auth_type]
        when /^ldap$/
          return @ldap.search(:base => params[:path] || '', :return_result => true)
      end
      nil
    end

    # Connects a listener with the message bus. Doesn't do anything if
    # no listener or tags are given.
    #
    # @param [Hash] params The parameters
    # @option params [Object] :listener The listener
    # @option params [Array<Symbol>, Symbol] :tags The tags that the listener is interested in
    # @return [void]
    def connect_message_listener(params)
      @message_bus.add_listener(params[:listener], params[:tags])
    end

    # Disconnects a listener from the message bus. Doesn't do anything if
    # no listener was given.
    #
    # @param [Hash] params The parameters
    # @option params [Object] :listener The listener
    # @return [void]
    def disconnect_message_listener(params)
      @message_bus.remove_listener(params[:listener])
    end

    # Sends a message to the message bus. Doesn't do anything if no message or tags
    # are given.
    #
    # @param [Hash] params The parameters
    # @option params [Object] :msg The message
    # @option params [Array<Symbol>, Symbol] :tags The tags of the message
    # @return [void]
    def notify(params)
      @message_bus.notify(params[:msg], params[:tags])
    end

    # Catches calls to undefined methods and tries to map them to plugins. It tries
    # to look for a plugin configuration section under that name, and if it finds
    # one, check if the section has a `plugin_class` attribute. If so, then it will
    # try to instantiate the class and return the instance. Otherwise, it will
    # check if there is a class of the following form:
    #
    # * `Cosmic::<name>`
    # * `Cosmic::<name in all uppercase>`
    # * `Cosmic::<name in camel case>`
    # * `::<name>`
    # * `::<name in all uppercase>`
    # * `::<name in camel case>`
    #
    # E.g. for `irc`, it would look for `Cosmic::irc`, `Cosmic::IRC`, `Cosmic::Irc`,
    # `::irc`, `::IRC`, `::Irc`. If it finds one, it will instantiate it and return
    # it.
    # The environment also caches the instantiated plugins so that the second call
    # for the same case-insensitive name returns the same plugin instance. So for
    # example calls like
    #
    #     environment.irc
    #     environment.Irc
    #
    # will first check if the environment knows about a plugin `irc` and if yes,
    # then will return the instance right away. If not then it will instantiate the
    # plugin as explained above.
    #
    # @param [Symbol] method_sym The method symbol to call
    # @param [Array<Object>] args The invocation arguments
    # @yield An optional block which is ignored
    # @return [Plugin,nil] The plugin instance if found, otherwise `nil`
    def method_missing(method_sym, *args, &block)
      name = method_sym.to_s
      required = true
      if name =~ /^(.+)\?$/
        required = false
        name = $1
      end

      # First we check if we already know it
      instance = @cached_plugins[name.downcase]
      return instance if instance

      # Now let's check if there is a plugin configured for that name, or if
      # there is a class of that name in namespace Cosmic
      clazz = find_plugin_class(name)
      begin
        if clazz
          instance = clazz.new(self, name.to_sym)
          @cached_plugins[name.downcase] = instance
          instance
        else
          super
        end
      rescue Exception => e
        if required
          raise "No such plugin instance configured or configuration is invalid for '#{name}': #{e}"
        else
          HoneyPot.new
        end
      end
    end

    # Checks if the environment instance could handle the call to `method_sym`.
    # In effect, this checks if the environment knows about a plugin of that name
    # or could instantiate one of that name. See #method_missing for details on
    # the rules.
    #
    # @param [Symbol] method_sym The method symbol to check
    # @param [true,false] include_private Whether to include private methods. Is ignored
    # @return [true,false] `true` if the environment could handle the call
    def respond_to?(method_sym, include_private = false)
      name = method_sym.to_s
      if name =~ /^(.+)\?$/
        name = $1
      end

      return @cached_plugins[name.downcase] || find_plugin_class(name)
    end

    # Shuts down this environment. This method will basically shut down all registered
    # plugins and the message bus.
    def shutdown
      @cached_plugins.values.each do |plugin|
        plugin.shutdown
      end
      @message_bus.shutdown
    end

    private

    def self.read_rc(config_file)
      if config_file
        YAML.load_file(config_file)
      else
        if File.exist?(".cosmicrc")
          YAML.load_file(".cosmicrc")
        elsif File.exists?("#{ENV['HOME']}/.cosmicrc")
          YAML.load_file("#{ENV['HOME']}/.cosmicrc")
        end
      end
    end

    def unify_keys(obj)
      if obj && obj.is_a?(Hash)
        obj.inject({}){ |memo,(k,v)| memo[k.to_sym] = unify_keys(v); memo }
      else
        obj
      end
    end

    def first_or_nil(values)
      if values && values.length && values.length > 0
        values[0]
      else
        nil
      end
    end

    def find_plugin_class(name)
      if @config[:plugins] && @config[:plugins][name.to_sym]
        plugin_class = @config[:plugins][name.to_sym][:plugin_class]
        if plugin_class
          clazz = load_class(plugin_class)
          return clazz if clazz
        end
      end
      camel_case_name = name.gsub(/^[a-z]/) { |a| a.upcase }
      clazz_names = ["Cosmic::#{name}",
                     "Cosmic::#{name.upcase}",
                     "Cosmic::#{camel_case_name}",
                     "Module::#{name}",
                     "Module::#{name.upcase}",
                     "Module::#{camel_case_name}"]
      clazz_names.each do |clazz_name|
        clazz = load_class(clazz_name)
        return clazz if clazz
      end
      nil
    end

    def load_class(name)
      if name
        # we're using eval here instead of const_get since it works for all classes
        begin
          clazz = eval(name)
          return clazz if clazz && clazz.is_a?(Class)
        rescue Exception => e
          # ignored
        end
      end
      nil
    end

    def authenticate
      case @config[:auth_type]
        when /^ldap$/
          authenticate_with_ldap
        when /^credentials$/
          authenticate_with_credentials
      end
    end

    def ldapify_username(username)
      if username.nil? || username =~ /cn=.*/
        username
      else
        "cn=#{username},ou=users,#{@config[:ldap][:base]}"
      end
    end

    def authenticate_with_ldap
      ldap_config = @config[:ldap]
      return unless ldap_config

      # net/ldap doesn't handle strings instead of symbols, so let's convert them as necessary
      ldap_config[:encryption] = ldap_config[:encryption].to_sym if ldap_config[:encryption]

      if ldap_config[:auth]
        ldap_config[:auth][:method] = ldap_config[:auth][:method].to_sym if ldap_config[:auth][:method]

        case ldap_config[:auth][:method]
          when /^simple$/
            if !ldap_config[:auth][:username]
              ldap_config[:auth][:username] = ldapify_username(ask("LDAP user ?\n"))
              ldap_config[:auth][:password] = ask("LDAP password ?\n") { |q| q.echo = false }
            end
        end
      end
      begin
        @ldap = Net::LDAP.new(ldap_config)
        if !@ldap.bind
          error = @ldap.get_operation_result
          @ldap = nil
          notify(:msg => "Cannot connect to LDAP: Error #{error.code} #{error.message}", :tags => :error)
        end
      rescue Net::LDAP::LdapError => e
        notify(:msg => "Cannot connect to LDAP: #{e.message}", :tags => :error)
      end
    end

    def authenticate_with_credentials
      cred_config = @config[:credentials]
      return unless cred_config

      if !cred_config[:username]
        cred_config[:username] = ask("Username ?\n")
        cred_config[:password] = ask("Password ?\n") { |q| q.echo = false }
      end
    end

    def get_service_credentials_from_env(service_name, service_config)
      username = nil
      password = nil
      case @config[:auth_type]
        when /^ldap$/
          service_ldap_config = service_config[:ldap] || @config[:ldap]
          if service_ldap_config && @ldap
            @ldap.search(:base => service_ldap_config[:path] || '', :return_result => true) do |entry|
              if service_ldap_config[:username_attr]
                username = first_or_nil(entry[service_ldap_config[:username_attr]])
              end
              if service_ldap_config[:password_attr]
                password = first_or_nil(entry[service_ldap_config[:password_attr]])
              end
            end
          end
      end
      [username, password]
    end

  end
end
