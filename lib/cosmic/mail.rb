require 'cosmic'
require 'cosmic/plugin'

require_with_hint 'mail', "In order to use the mail plugin please run 'gem install mail'"

module Cosmic
  # A plugin that allows Cosmic scripts to send email:
  #
  #     with mail do
  #       send :from => 'me@example.com',
  #            :to => 'you@example.com',
  #            :subject => 'Hello',
  #            :body => 'World'
  #     end
  #
  # or
  #
  #     with mail do
  #       send do
  #        from    'cosmic@ninginc.com'
  #        to      'thomas@ning.com'
  #        subject 'Hello'
  #        text_part do
  #          body 'Plain Text World'
  #        end
  #        html_part do
  #          content_type 'text/html; charset=UTF-8'
  #          body '<h1>HTML World</h1>'
  #        end
  #       end
  #     end
  #
  # The latter form makes use of mail creation support via blocks in the
  # [Mail gem](https://github.com/mikel/mail). See the gem's documentation for what
  # additional options are available in that mode.
  #
  # The plugin either requires a running postfix or sendmail daemon on the machine that
  # the script is executed on, or a section for the mail server in the cosmic configuration
  # file. In the latter case, mail server authentication can use the normal authentication
  # mechanisms available to plugins.
  #
  # Note that this plugin will not actually send email in dry-run mode.
  # Instead it will only send messages tagged as `:mail` and `:dryrun`.
  class Mail < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new mail plugin instance.
    #
    # @param [Environment] environment The Cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [Mail] The new instance
    def initialize(environment, name = :mail)
      @name = name.to_s
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      if @config[:delivery_method]
        @delivery_method = @config[:delivery_method].to_sym
        @delivery_config = {}
        if @config[@delivery_method]
          @delivery_config.merge!(@config[@delivery_method])
        end
        if @config[:auth]
          @delivery_config[:user_name] = @config[:auth][:username]
          @delivery_config[:password] = @config[:auth][:password]
        end
      end
    end

    # Sends an email.
    #
    # @param [Hash] params The parameters
    # @option params [String] :from The sender; if not specified and a user is specified
    #                               in the credentials section for the mail plugin, then
    #                               that user is used, otherwise an error is raised
    # @option params [String] :to The recipient
    # @option params [String] :subject The subject of the message
    # @option params [String] :body The body of the message
    # @yield An optional block invoked in the context of the email message object; in this
    #        case all other parameters are ignored and the script has full control over the
    #        message creation; see [the Mail gem](https://github.com/mikel/mail) for
    #        more info about how to use this
    def send(*args, &block)
      if block_given?
        mail = ::Mail.new(&block)
      else
        params = args.flatten.first
        mail_sender = params[:from]
        if mail_sender.nil? && @config[:auth]
          mail_sender = @config[:auth][:username]
        end
        raise "No :from argument given" unless mail_sender
        mail_recipient = get_param(params, :to)
        mail_subject = params[:subject] || ''
        mail_body = params[:body] || ''
        mail = ::Mail.new do
          from    mail_sender
          to      mail_recipient
          subject mail_subject
          body    mail_body
        end
      end
      if @environment.in_dry_run_mode
        notify(:msg => "[#{@name}] Would send an email with subject #{mail.subject} from #{mail.from} to #{mail.to}",
               :tags => [:mail, :dryrun])
      else
        if @delivery_method
          mail.delivery_method(@delivery_method, @delivery_config)
        end
        mail.deliver!
        notify(:msg => "[#{@name}] Sent an email with subject #{mail.subject} from #{mail.from} to #{mail.to}",
               :tags => [:mail, :trace])
      end
    end
  end
end