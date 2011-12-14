require 'cosmic'
require 'cosmic/plugin'
require 'uri'
require 'net/http'
require 'net/https'
require_with_hint 'jira4r', "In order to use the jira plugin please run 'gem install tomdz-jira4r'"
require_with_hint 'nokogiri', "In order to use the jira plugin please run 'gem install nokogiri'"

module Cosmic
  # A listener for the message bus that outputs messages as comments on a JIRA issue.
  class IssueMessageListener
    # The JIRA server connection
    attr_reader :jira
    # The JIRA issue that this listener represents
    attr_reader :issue

    # Creates a new listener instance for the given jira plugin and issue.
    #
    # @param [JIRA] jira The plugin instance
    # @param [Object] issue The issue to send messages to
    # @return [ChannelMessageListener] The new instance
    def initialize(jira, issue)
      @jira = jira
      @issue = issue
    end

    # Sends a message to this listener.
    #
    # @param [Hash] params The parameters
    # @option params [String] :msg The message
    # @return [void]
    def on_message(params)
      @jira.comment_on(:issue => @issue, :comment => params[:msg])
    end

    # Compares this listener with another listener and returns true if both represent
    # the same JIRA issue connection.
    #
    # @param [IssueMessageListener] listener The other listener
    # @return [true,false] If the two listeners represent the same JIRA issue connection
    def eql?(listener)
      listener && self.class.equal?(listener.class) &&
        @jira == listener.jira && @issue.key == listener.issue.key
    end

    alias == eql?

    # Calculates the hash code for this listener.
    #
    # @return [Integer] The hash code
    def hash
      @jira.hash ^ @issue.key.hash
    end
  end

  # A plugin to interact with JIRA. One common use is to create JIRA issues that
  # track deployments, with comments for the individual steps:
  #
  #     issue = with jira do
  #       issue = create_issue! :project => 'COS',
  #                             :type => 'New Feature',
  #                             :summary => 'Deployment',
  #                             :description => 'Deploying something'
  #       connect :issue => issue, :to => [:info, :galaxy]
  #       issue
  #     end
  #     ...
  #     jira.resolve! :issue => issue, :comment => 'Deployment finished', :resolution => 'Fixed'
  #
  # The jira plugin currently does not emit any messages unless in dryrun mode, in which case
  # it will not actually connect to the JIRA server in dry-run mode. Instead it will only send
  # messages tagged as `:jira` and `:dryrun`.
  class JIRA < Plugin
    # The plugin's configuration
    attr_reader :config

    # Creates a new jira plugin instance and connect it to the configrued JIRA server. In
    # dryrun mode it will not actually connect but instead create a message tagged as `:dryrun`.
    #
    # @param [Environment] environment The cosmic environment
    # @param [Symbol] name The name for this plugin instance e.g. in the config
    # @return [JIRA] The new instance
    def initialize(environment, name = :jira)
      # Using Monitor instead of Mutex as the former is reentrant
      @monitor = Monitor.new
      @environment = environment
      @config = @environment.get_plugin_config(:name => name.to_sym)
      @config[:address] ||= 'http://localhost'
      @environment.resolve_service_auth(:service_name => name.to_sym, :config => @config)
      authenticate
    end

    # Retrieves a JIRA issue. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :key The key of the issue
    # @return [Jira4R::V2::RemoteIssue,nil] The issue
    def get_issue(params)
      key = params[:key] or raise "No :key argument given"
      issueify(key)
    end

    # Creates a new JIRA issue. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [String] :project The key of the project (short name)
    # @option params [String] :type The type of the issue
    # @option params [String] :summary The issue summary
    # @option params [String,nil] :description The issue description
    # @option params [String,nil] :assignee The assignee. If not specified, then the user
    #                                       used to authenticate with JIRA will be used
    # @return [Jira4R::V2::RemoteIssue,nil] The new issue
    def create_issue(params)
      project_name = params[:project] or raise "No :project argument given"
      type = params[:type] or raise "No :type argument given"
      summary = params[:summary] or raise "No :summary argument given"
      if @environment.in_dry_run_mode
        notify(:msg => "Would create a new issue in project #{project_name} on JIRA server #{@config[:address]} as user #{@config[:auth][:username]}",
               :tags => [:jira, :dryrun])
      else
        project = get_project(project_name)
        if project
          type_id = nil
          @monitor.synchronize do
            @jira.getIssueTypesForProject(project.id).each do |issue_type|
              if issue_type.name == type
                type_id = issue_type.id
              end
            end
          end
          raise "The type '#{type}' does not seem to be defined for project '#{project.name}'" unless type_id

          issue = Jira4R::V2::RemoteIssue.new
          issue.project = project.key
          issue.summary = summary
          issue.description = params[:description] || ''
          issue.type = type_id
          issue.assignee = params[:assignee] || @config[:auth][:username]
          @monitor.synchronize do
            @jira.createIssue(issue)
          end
        else
          raise "Could not find JIRA project #{project_nam}"
        end
      end
    end

    # Adds a comment to a JIRA issue. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Jira4R::V2::RemoteIssue,String] :issue The issue or its key
    # @option params [String,nil] :author The author of the comment. If not specified, then the
    #                                     user used to authenticate with JIRA will be used
    # @option params [String,nil] :comment The comment
    # @return [Jira4R::V2::RemoteIssue,nil] The issue
    def comment_on(params)
      key = params[:issue] or raise "No :issue argument given"
      if @environment.in_dry_run_mode
        notify(:msg => "Would comment on issue #{key} on JIRA server #{@config[:address]} as user #{@config[:auth][:username]}",
               :tags => [:jira, :dryrun])
      else
        issue = issueify(key)
        if issue
          comment = Jira4R::V2::RemoteComment.new()
          comment.author = params[:author] || @config[:auth][:username]
          comment.body = params[:comment] || ''
          @monitor.synchronize do
            @jira.addComment(issue.key.upcase, comment)
          end
        else
          raise "Could not find JIRA issue #{params[:issue]}"
        end
        issue
      end
    end

    # Links an issue to another one. This method will do nothing in dryrun mode except create
    # a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Jira4R::V2::RemoteIssue,String] :issue The issue or its key
    # @option params [Jira4R::V2::RemoteIssue,String] :to The issue to link to, or its key
    # @option params [String] :kind The kind of the link (e.g. `depends on`)
    # @option params [String,nil] :comment The link comment
    # @return [Jira4R::V2::RemoteIssue,nil] The issue
    def link(params)
      from_key = params[:issue] or raise "No :issue argument given"
      to_key = params[:to] or raise "No :to argument given"
      kind = params[:kind] or raise "No :kind argument given"
      if @environment.in_dry_run_mode
        notify(:msg => "Would create a link of type #{kind} from issue #{from_key} to #{to_key} on JIRA server #{@config[:address]} as user #{@config[:auth][:username]}",
               :tags => [:jira, :dryrun])
      else
        issue = issueify(from_key)
        to = issueify(to_key)
        if issue && to
          # The SOAP and RPC apis don't support linking so we have go via the web form instead
          uri = URI.parse(@config[:address])
          http = Net::HTTP.new(uri.host, uri.port)
          if uri.scheme == 'https'
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          end
          # Login first to get the cookie and token
          req = Net::HTTP::Post.new('/login.jsp')
          req.set_form_data('os_authType' => 'basic', 'os_cookie' => true)
          req.basic_auth(@config[:auth][:username], @config[:auth][:password])

          response = http.request(req)

          if response.code.to_i == 200
            cookies = response.get_fields('set-cookie').collect { |cookie| cookie.split(';')[0] }
            doc = Nokogiri::HTML(response.body)
            token = ''
            doc.xpath("//meta[@id='atlassian-token']").each do |meta_tag|
              token = meta_tag['content']
            end

            req = Net::HTTP::Post.new('/secure/LinkExistingIssue.jspa')
            req.set_form_data('id' => issue.id,
                              'linkKey' => to.key,
                              'linkDesc' => kind,
                              'comment' => params[:comment] || '',
                              'atl_token' => token)
            req['Cookie'] = cookies.to_s

            response = http.request(req)
            if response.code.to_i >= 400
              raise "Could not link JIRA issue #{issue.key} to #{to.key}, response status was #{response.code.to_i}"
            end
          else
            raise "Could not login to JIRA via http/https, response status was #{response.code.to_i}"
          end
        else
          raise "Could not find the JIRA issue #{from_key}" unless issue
          raise "Could not find the target JIRA issue #{to_key}" unless to
        end
        issue
      end
    end

    # Resolves an issue after disconnecting it from the message bus if necessary. This method will do
    # nothing in dryrun mode except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Jira4R::V2::RemoteIssue,String] :issue The issue or its key
    # @option params [String,nil] :action The action. If not specified, then `Resolve Issue` will be used
    # @option params [String,nil] :resolution The resolution. If not specified, then `Fixed` will be used
    # @return [Jira4R::V2::RemoteIssue,nil] The issue
    def resolve(params)
      if @environment.in_dry_run_mode
        notify(:msg => "Would resolve issue #{params[:issue]} on JIRA server #{@config[:address]} as user #{@config[:auth][:username]}",
               :tags => [:jira, :dryrun])
      else
        issue = disconnect(params)
        if issue
          action_name = params[:action] || 'Resolve Issue'
          resolution_field = Jira4R::V2::RemoteFieldValue.new
          resolution_field.id = "resolution"
          resolution_field.values = get_resolution_id(params[:resolution] || 'Fixed')
          perform_workflow_action(issue, action_name, [resolution_field])
        else
          raise "Could not find JIRA issue #{params[:issue]}"
        end
        issue
      end
    end

    # Connects an existing JIRA issue to the message bus. All messages with the given tags
    # will then be added as comments to the JIRA issue. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Jira4R::V2::RemoteIssue,String] :issue The issue or its key
    # @option params [Array<String>,String] :to The tags for the messages that the plugin should write to the channel
    # @return [Cinch::Channel,nil] The channel if the plugin was able to connect it
    # @return [Jira4R::V2::RemoteIssue,nil] The issue
    def connect(params)
      key = params[:issue] or raise "No :issue argument given"
      tags = params[:to] or raise "No :to argument given"
      if @environment.in_dry_run_mode
        notify(:msg => "Would connect issue #{key} from JIRA server #{@config[:address]} as user #{@config[:auth][:username]} to the message bus",
               :tags => [:jira, :dryrun])
      else
        issue = issueify(key)
        if issue
          @environment.connect_message_listener(:listener => IssueMessageListener.new(self, issue), :tags => tags)
        elsif !@environment.in_dry_run_mode
          raise "Could not find JIRA issue #{key}"
        end
        issue
      end
    end

    # Disconnects an existing JIRA issue from the message bus. This does not change anything in the JIRA issue itself,
    # e.g. no comment will be added by this method or the issue resolved. This method will do nothing in dryrun mode
    # except create a message tagged as `:dryrun`.
    #
    # @param [Hash] params The parameters
    # @option params [Jira4R::V2::RemoteIssue,String] :issue The issue or its key
    # @return [Jira4R::V2::RemoteIssue,nil] The issue
    def disconnect(params)
      key = params[:issue] or raise "No :issue argument given"
      if @environment.in_dry_run_mode
        notify(:msg => "Would disconnect issue #{key} from JIRA server #{@config[:address]} as user #{@config[:auth][:username]} from the message bus",
               :tags => [:jira, :dryrun])
      else
        issue = issueify(key)
        if issue
          @environment.disconnect_message_listener(:listener => IssueMessageListener.new(self, issue))
        end
        issue
      end
    end

    private

    def authenticate
      if @environment.in_dry_run_mode
        notify(:msg => "Would login to JIRA server #{@config[:address]} as user #{@config[:auth][:username]}",
               :tags => [:jira, :dryrun])
      else
        @jira = Jira4R::JiraTool.new(2, @config[:address])
        log = CosmicLogger.new(:environment => @environment,
                               Logger::WARN => [:jira, :warn],
                               Logger::ERROR => [:jira, :error],
                               Logger::FATAL => [:jira, :error])
        @jira.logger = log
        @jira.login(@config[:auth][:username], @config[:auth][:password])
      end
    end

    def get_project(key)
      @monitor.synchronize do
        @jira.getProjectByKey(key)
      end
    end

    def issueify(issue_or_key)
      if issue_or_key.is_a?(Jira4R::V2::RemoteIssue)
        issue_or_key
      elsif @environment.in_dry_run_mode
        notify(:msg => "Would fetch issue #{issue_or_key.to_s} from JIRA server #{@config[:address]} as user #{@config[:auth][:username]}",
               :tags => [:jira, :dryrun])
        nil
      else
        @monitor.synchronize do
          @jira.getIssue(issue_or_key.to_s)
        end
      end
    end

    def get_resolution_id(resolution_name)
      @monitor.synchronize do
        @jira.getResolutions().each do |resolution|
          if resolution.name == resolution_name
            return resolution.id
          end
        end
      end
      raise "The resolution #{resolution_name} does not seem to be supported"
    end

    def perform_workflow_action(issue, action_name, args_array = [])
      resolve_action_id = nil
      @monitor.synchronize do
        @jira.getAvailableActions(issue.key.upcase).each do |action|
          if action.name == action_name
            resolve_action_id = action.id
            break
          end
        end
      end
      raise "The workflow action #{action_name} does not seem to be supported" unless resolve_action_id
      @monitor.synchronize do
        @jira.progressWorkflowAction(issue.key.upcase, resolve_action_id, args_array)
      end
    end
  end
end
