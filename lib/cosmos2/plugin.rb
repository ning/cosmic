require 'cosmos2'

module Cosmos2
  # Base class for plugins.
  class Plugin
    # Helper method for plugins to send events to the environment. The method
    # will fall back to `stdout` if no environment is available, which is
    # mostly useful for errors during plugin initialization.
    #
    # @param [Hash] params The parameters
    # @option params [Object] :msg The event's message
    # @option params [Array<Symbol>, Symbol] :tags The tags of the event
    # @return [void]
    def notify(params)
      if @environment
        @environment.notify(params)
      elsif params[:msg] && params[:tags]
        # Fallback to stdout - this is mostly for errors during setup
        stdout.puts '[' + arraify(params[:tags]).join(',') + ']' + params[:msg]
      end
    end

    # Catches calls to undefined methods and checks whether they are of the form
    # `<defined method>?`. If so, then it will call the defined method in a
    # `begin`-`rescue` block and catch any errors and send events tagged as
    # `:error` instead of passing the exception on to the caller.
    #
    # @param [Symbol] method_sym The method symbol to call
    # @param [Array<Object>] args The invocation arguments
    # @yield An optional block which is ignored
    # @return [Plugin,nil] The plugin instance if found, otherwise `nil`
    def method_missing(method_sym, *args, &block)
      if method_sym.to_s =~ /^(.*)\?$/
        begin
          send($1, *args, &block)
        rescue => e
          notify(:msg => e.to_s, :tags => :error)
        end
      else
        super
      end
    end

    # Checks if the plugin can respond to a call to the indicated method. This checks
    # for defined methods and for calls to methods with a name of the form
    # `<defined method>?`.
    #
    # @param [Symbol] method_sym The method symbol to check
    # @param [true,false] include_private Whether to include private methods
    # @return [true,false] `true` if the plugin could handle the call
    def respond_to?(method_sym, include_private = false)
      if method_sym.to_s =~ /^(.*)\?$/
        super($1, include_private)
      else
        super
      end
    end
  end
end

