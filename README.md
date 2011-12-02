# Overview

Cosmos2 is a Ruby library and commandline tool for service deployment automation. The core idea is that deployments of machines & services should be scripted so that they are reproducable and easier to understand. Cosmos2' aim is to help writing these scripts by providing a simplified interface to services commonly used during deployment plus a little bit of DSL sugar to keep the scripts concise and easy to understand. The DSL part is kept to a minimum however, Cosmos2 scripts are still normal Ruby scripts with all the benfits that that brings.

Cosmos2 itself requires Ruby 1.8.7 or newer, however some plugins require Ruby 1.9 (e.g. the IRC plugin) or JRuby (e.g. the JMX plugin).

# Concepts

## Plugins

The Cosmos2 core provides little in terms of actual deployment support, all that is contained in the plugins. Each Cosmos2 plugin is a wrapper around an existing ruby library or external API that simplifies interaction with the service specifically for deployments. This also means that you won't have access to all capabilities of that service, only to those that make sense for deploying machines/services. However, plugins usually provide access to the underlying library/API so that you can interact with that directly if necessary.

## Authentication system

Cosmos2 provides built-in support for authentication that can be used by all plugins. The goal there is to perform deployments as a specific person and not using some general account such as `root` or `eng` or something like that. This allows to track deployments more accurately and also to have more fine-grained control over who can perform which deployment steps. 

Cosmos2 itself can currently authenticate against an LDAP server, and then pull credentials from there to authenticate other services, or use the LDAP credentials themselves for LDAP-enabled services. Depending on the service setup, this would allow a single-sign-on style deployment where the person performing the deployment only has to authenticate once at the start of the deployment, and from then on all other steps would be automatically authenticated by Cosmos2.

## Messages

The environment that Cosmos2 plugins run in, provides the ability to send and listen to messages. These messages are basically tagged strings. A plugin then can express interest in messages with specific tags. In addition, deployment scripts can wire some plugins to specific tags, e.g.:

    irc.connect :channel => '#test', :to => [:info, :galaxy]
    notify :msg => 'A message, yay !', :tags => :info

This example wires a specific IRC channel, `#test`, to all messages that are tagged `:info` or `:galaxy`, and then sends an explicit message tagged as `:info`, which because of the wiring will then be posted by the IRC plugin to that channel.

Cosmos2 plugins usually either produce messages (these are typically the plugins that perform actual deployment steps) or consume message (e.g. for keeping record of the deployment progress).

## Dry-run

One of the core concepts of Cosmos2 is the dry-run mode. When it is turned on (via configuration or commandline switch), then all plugins will omit messages that by default are output to standard out, instead of performing the actions. In effect, the script will output the steps it would take, but not actually perform these steps.

## DSL

Cosmos2 adds only a few pieces of syntactic sugar, all geared at eliminating syntactic noise and keeping the scripts short and to the point.

### `with` construct

Cosmos2 borrows the `with` construct from languages such as JavaScript or Pascal:

    with irc do
      write :msg => 'Hello world', :channels => '#test'
    end

This is equivalent to

    irc.write :msg => 'Hello world', :channels => '#cosmos'

The benefit of this is that multiple calls to methods on the same object can be grouped into one `with` statement which reduces the noise and makes the code more readable. It also makes it more obvious that the methods are called on the same object.

The other benefit is that this makes optional sections possible as explained below.

### Simplified plugin interaction

Within the context of a cosmos2 environment instance, plugins can simply be instantiated and used by their name.

    cosmos2 = Cosmos2::Environment.from_config_file

    with cosmos2 do
      with irc do
        write :msg => 'Hello world', :channels => '#test'
      end
      ...
      with irc do
        write :msg => 'Goodbye world', :channels => '#test'
      end
    end

This will automatically create an IRC instance in the first `with irc` block using the environment's configuration (as explained below) and use it. The plugin then gets cached under that name `irc`, so that the second block will simply use the same instance.

### Optional sections

Optional sections are groups of statements that get executed if a certain plugin is defined, otherwise they are ignored. Usually you would use `if` or `unless` statements in Ruby. Cosmos2 provides a shortcut syntax that makes this more concise:

    with irc? do
      write :msg => 'Hello world', :channels => '#test'
    end

or

    irc?.write :msg => 'Hello world', :channels => '#test'

The additional question mark after the plugin short name directs Cosmos to only execute the method call if the IRC plugin is configured. If not, then the method call is ignored.
One common use case for this is using the same deployment script in production and QA or development environments. Some services would only be configured in the production environment, so in the script they would be referenced with a `?`.

### Optional error handling

In a similar way to optional sections, Cosmos2 allows to make potential errors raised by a method call optional. The typical use case for this would be to differenciate required functionality from optional functionality that should not affect the deployment. For example in:

    with irc do
      write msg: 'Hello world', channels: '#test'
    end

if the call to `write` causes an error, for instance because the connection to the IRC server was dropped, then this would cause the deployment script to fail even if it is actually not critical to the deployment itself. If instead you write this as:

    with irc do
      write? :msg => 'Hello world', :channels => '#test'
    end

then an error raised by the `write` method will be emitted as an error message (see below) but otherwise ignored and the deployment can continue.

# How to use Cosmos2

Cosmos2 can be used in three ways: via the commandline tool `cosmos2` that gets installed as part of the gem, as a library from your own ruby scripts, or via a standalone executable.

## Commandline tool

The commandline tool `cosmos2` is installed as part of the cosmos2 gem. It provides a simple ruby commandline script that automatically creates a cosmos2 environment and then executes your script in it. This means that your script shouldn't instantiate the cosmos environment and instead should simply depend on it being available:

    require 'cosmos2/irc'

    with irc do
      write :msg => ARGV[0], :channels => '#test'
    end
    ...

You will still have to require all plugins that you want to use - Cosmos2 will not require them automatically.

The above script `irc-test.rb` could then be invoked as:

    cosmos2 irc-test.rb 'Hello World'

## Standalone tool

This is a separate project [cosmos2-standalone](https://github.com/ning/cosmos2-standalone) that bundles the gem with all plugins that it is allowed to bundle (some are omitted due to license restrictions) with jruby into an executable jar file. You can simply download the executable and, provided you jave Java 6 or newer installed, run as is. See the documentation for that project for more details about which plugins are included and which have to be installed separately.

## Using cosmos2 in your own scripts

You can also require the cosmos2 gem in your scripts. You will then have to create the Cosmos2 environment yourself, e.g.:

    require 'cosmos2'
    require 'cosmos2/irc'

    cosmos2 = Cosmos2::Environment.from_config_file

    with cosmos2 do
      with irc do
        write :msg => 'Hello world', :channels => '#test'
      end
      ...
    end

# Configuration

Cosmos2 and the plugins are configured via a single YAML file. The default location for the file is `$HOME/.cosmos2rc`, but both the commandline tool and the `Cosmos2::Environment` constructor support specifying a different file.

The basic environment configuration looks like this:

    auth_type: <Authentication type>
    <Authentication type configuration section>
    plugins:
      <Plugin configuration sections>

For example:

    auth_type: ldap
    ldap:
      host:       my-ldap-server.example.com
      port:       1636
      base:       dc=example,dc=com
      encryption: simple_tls
      auth:
        method:   simple
        username: cn=Directory Manager
        password: my-password
    plugins:
      irc:
        host:      irc.example.com
        port:      6667
        nick:      cosmos2
        auth_type: credentials_from_env
        ldap:
          path:          o=irc.example.com,ou=apps,dc=example,dc=com
          password_attr: password

## Authentication types

Cosmos2 currently supports these authentication types:

#### ldap

Cosmos2 will authenticate with a configured LDAP server before proceeding, using [net-ldap](http://net-ldap.rubyforge.org/). The LDAP configuration has the following form:

    ldap:
      host:       <LDAP host>
      port:       <LDAP port>
      base:       <Base distinguished name of the server, usually an organization or domain component entry>
      encryption: <Encryption type, has to be simple_tls currently>
      auth:
        method:   <The autentication type, either simple or anonymous>
        username: <The LDAP username to authenticate with if simple auth is chosen, e.g. cn=Directory Manager>
        password: <The LDAP password>

If `simple` is chosen as the authentication method and username/password are not specified in the config, then Cosmos2 will prompt the user for username and password before proceeding.

See e.g. this [introduction to LDAP](http://www.ldapman.org/articles/intro_to_ldap.html) for more info about LDAP.

#### credentials

With this authentication form, Cosmos2 will not authenticate itself but provide the credentials to plugins if they use the `credentials_from_env` authentication type (see below). The configuration looks like this:

    credentials:
      username: <The username>
      password: <The password>

If username/password are not specified in the config, then Cosmos2 will prompt the user for username and password before proceeding.

## Plugin configuration

All plugins are configured under the `plugins` section in the configuration. The configuration generally has this format:

    plugins:
      <Plugin name>:
        plugin_class: <Optional plugin class name>
        <Plugin-specific configuration>

Cosmos2 uses the plugin name and, if specified, the plugin class to instantiate the plugin and make it available to scripts. For instance, with this configuration section:

    plugins:
      irc:
        <IRC plugin configuration>

Cosmos2 will use this plugin section if used like this in a Cosmos2 environment:

    with irc do
      write :msg => 'Hello world', :channels => '#test'
    end

or

    irc.write :msg => 'Hello world', :channels => '#test'

Since no plugin class is specified, it will search for the plugin under the class names

* `Cosmos2::#{name}`
* `Cosmos2::#{name.upcase}`
* `Cosmos2::#{camel_case_name}`
* `#{name}`
* `#{name.upcase}`
* `#{camel_case_name}`

If it cannot find a plugin class, then it will raise an error unless a `?` was used. E.g.

    with irc? do
      write :msg => 'Hello world', :channels => '#test'
    end

would not fail if no irc configuration section exists or the class could not be found.

The `plugin_class` configuration option allows you to specify the plugin class directly, and it also makes it possible to configure more than one plugin of the same type. E.g.

    plugins:
      irc1:
        plugin_class: Cosmos2::IRC
        <First IRC plugin configuration>
      irc2:
        plugin_class: Cosmos2::IRC
        <Second IRC plugin configuration>

These two then can be used like so:

    with irc1 do
      write :msg => 'Hello world', :channels => '#test'
    end
    with irc2 do
      write :msg => 'Hello world', :channels => '#test'
    end

### Plugin authentication

Plugins can perform authentication through the Cosmos2 environment, or they can handle it themselves. Authenticating through Cosmos2 has the benefit that it can reduce the number of times that the user is asked for credentials. For instance, assume a plugin for a service that authenticates via LDAP. That plugin can then use the same LDAP credentials that Cosmos2 asked the user for at the beginning of the deployment session. Likewise, it is possible to store authentication information (e.g. tokens, keys, etc.) in LDAP and have Cosmos2 fetch it from there on behalf of a plugin.

For plugins, the Cosmos2 environment currently supports these authentication types:

#### credentials_from_env

This type is used for cases where the environment stores the credentials and the plugin can simply ask the environment to retrieve them. It is currently only implemented for environments using LDAP authentication. In this case, the plugin's configuration is required to have a `ldap` configuration section that specifies the path to the credentials plus the names of the attributes for the username and password:

    plugins:
      irc:
        ...
        auth_type: credentials_from_env
        ldap:
          path:          o=irc.example.com,ou=apps,dc=example,dc=com
          password_attr: password

In this example, the `o=irc.example.com,ou=apps,dc=example,dc=com` LDAP entry contains an attribute called `password` which contains the password for the LDAP server. No username is specified, so Cosmos2 will not retrieve it (the IRC plugin doesn't require it if the IRC server doesn't need one).

#### ldap_credentials

The `ldap_credentials` type is used for services that authenticate themselves against LDAP. The Cosmos2 environment in this case is required to use `ldap` authentication, and the plugin will simply use the same credentials as the environment, to authenticate.

#### credentials

This type describes the case where the plugin has its own set of credentials independent from the environment. Cosmos2 supports the plugin by dealing with the credential configuration or asking the user as necessary. If you choose to configure the credentials in the config file, then put them in a `credentials` sub section in the plugin configuration:

    plugins:
      irc:
        ...
        auth_type: credentials
        credentials:
          username: testuser
          password: my-password

Cosmos2 will ask the user for credentials if the element is not present in the configuration.

# Individual plugins

The API documentation has more details about the capabilities of the individual plugins. This section gives a brief overview over each of the included plugins and describes their configuration.

## IRC

The Cosmos2 IRC plugin allows Cosmos2 scripts to interact with an IRC server. The IRC support however is limited to posting messages and similar things, it intentionally does not provide a full IRC bot that can be interacted with.

The plugin uses the [Cinch library](https://github.com/cinchrb/cinch) and thus requires (J)Ruby 1.9. You'll need to install the cinch and atomic gems in order to be able to use the plugin:

    gem install cinch atomic

The plugin configuration looks like this:

    irc:
      host:                   <IRC server; default is localhost>
      port:                   <IRC server port; default is 6667>
      nick:                   <IRC nick to use; default is cosmos>
      connection_timeout_sec: <Connection timeout; default is 60>
      <authentication configuration as explained above>

The IRC plugin is typically used to post status updates to specific IRC channels. Code for that would look like:

    with irc do
      write :msg => 'Starting deployment', :channels => '#status'
      connect :channel => '#status', :to => :info
    end
    ...
    with irc do
      write :msg => 'Deployment finished', :channels => '#status'
      leave :channel => '#status', :msg => 'Bye'
    end

In this example, the script first writes an explicit message to the `#status` IRC channel, and then connects that channel to all messages tagged as `:info`. After the deployment has been completed, the script then writes another message to the IRC channel and leaves the channel (which will automatically disconnect it from the message bus).

## JIRA

The JIRA plugin can be used to create and update JIRA issues. For instance, you can use to create issues that track deployments, and add comments for each individual step of the deployment.

This plugin uses the [tomdz-jruby4r gem](https://github.com/tomdz/jira4r) which itself uses the [tomdz-soap4r gem](https://github.com/tomdz/soap4r). These two are forks of forks of the original [soap4r](https://github.com/felipec/soap4r) and [jira4r](https://github.com/remi/jira4r) gems, which have been updated to work with (J)Ruby 1.9 and with each other.

    gem install tomdz-jruby4r tomdz-soap4r

The JIRA plugin is configured as follows:

    jira:
      address: <Url of the JIRA server; default is http://localhost>
      <authentication configuration as explained above>

Similar to the IRC plugin, the JIRA plugin is typically used to update JIRA issues as deployments are performed. For instance, in order to automatically create a JIRA issue for a deployment and update it with comments documenting individual deployment steps, you could use something like:

    issue = with jira do
      issue = create_issue :project => 'DEPL', :type => 'New Feature', :summary => 'New deployment', :description => 'New deployment'
      connect :issue => issue, :to => :info
    end
    ...
    with jira do
      resolve :issue => issue, :comment => 'Deployment completed', :resolution => 'Fixed'
    end

## Galaxy

This plugin makes the [Galaxy](https://github.com/ning/galaxy) software deployment tool available to Cosmos2 scripts.

Cosmos2 requires Galaxy version 2.5.1 or newer, or 2.5.1.1 for Ruby/JRuby 1.9 compatibility. You can install Galaxy via

    gem install galaxy

The plugin is configured as follows:

    galaxy:
      host:               <The gonsole host; default is localhost>
      port:               <The galaxy port; default is 4440>
      relaxed_versioning: <Whether to use relaxed versioning; default is false>

Galaxy itself does not support authentication, so no such configuration is necessary for it.

The Galaxy plugin makes it straightforward to use Galaxy commands from within Cosmos2 scripts and it adds additional functionality not readily available in Galaxy (e.g. reverting to a previous snapshot). A simple Cosmos2 script using Galaxy would look like:

    with irc do
      connect channel: '#status', to: [:galaxy]
    end
    with galaxy do
      snapshot = take_snapshot
      services = select :type => /^echo$?/
      begin
        update :services => services, :to => new_version
      rescue
        revert :services => services, :to => snapshot
      end
      start :services => services
    end

This script first connects an IRC channel to all messages created by the Galaxy plugin. Next it takes a snapshot of the current state of the Galaxy environment and then selects all services of type `echo`. It then tries to update these services and in case of failure, attempts to revert them to the previous snapshot. Finally it starts the services.

## JMX

The JMX plugin allows Cosmos2 scripts to interact with exposes [JMX resources](http://docs.oracle.com/javase/tutorial/jmx/index.html) exposed by services running on the JVM.

This plugin requires JRuby and the [jmx4r](https://github.com/jmesnil/jmx4r) gem:

    gem install jmx4r

The only configuration for the plugin is for authentication in cases where the JMX resources require it:

    jmx:
      <authentication configuration as explained above>

The plugin supports reading and setting attributes as well as invoking operations. For instance

    require 'cosmos2/galaxy'
    require 'cosmos2/jmx'

    services = with galaxy do
      select :type => /^echo$?/
    end
    with jmx do
      mbeans = services.collect {|service| get_mbean :host => service.host, :port => 12345, :name => 'some.company:name=MyMBean'}
      mbeans.each do |mbean|
        old_value = get_attribute :mbean => mbean, :attribute => 'SomeAttribute'
        set_attribute :mbean => mbean, :attribute => 'SomeAttribute', :value => old_value + 1

        invoke :mbean => mbean, :operation => 'DoSomething', :args => [ 'test' ]
      end
    end

This collects `some.company:name=MyMBean` mbeans from all `echo` servers on galaxy, then increments the `SomeAttribute` attribute and finally invokes the `DoSomething` operation with a single string argument.

## F5

The F5 plugin allows Cosmos2 scripts to manipulate certain aspects of [F5 BIG-IP load balancers](https://www.f5.com/products/big-ip/) such as registration of hosts, pool membership, monitoring configuration etc.

It uses the [iControl library](https://devcentral.f5.com/Tutorials/TechTips/tabid/63/articleType/ArticleView/articleId/1086421/Getting-Started-With-Ruby-and-iControl.aspx) version 11.0.0.1 or newer which can be downloaded from F5's developer website.

    gem install f5-icontrol

The configuration for the plugin consists of the load balancer host and the authentication credentials for it:

    primary_lb:
      plugin_class: Cosmos2::F5
      host:         <load balancer host>
      <authentication configuration as explained above>

Typically, you would want to have one plugin entry for each primary load balancer that the Cosmos2 scripts need access to, and use the sync method provided by the plugin, to sync configuration changes to any secondary load balancers.

    require 'cosmos2/galaxy'
    require 'cosmos2/f5'

    services = with galaxy do
      select :type => /^echo$?/
    end

    with primary_lb do
      services.each do |service|
        node = disable :ip => service.ip
        remove_from_pool node.merge { :pool => 'echo-12345' }
        add_to_pool node.merge { : pool => 'echo-23456' }
        enable node
      end
      sync
    end

This sample script determines all `echo` servies from galaxy, then disables them on the primary load balancer, removes them from one pool and adds them to another pool, reenables the services and finally syncs the configuration with any secondary load balancers.

## SSH

With the SSH plugin Cosmos2 scripts can execute commands on remote hosts and upload files to/download files from them.

It uses the [Net::SSH and Net::SCP](http://net-ssh.github.com/) libraries:

    gem install net-ssh net-scp

The plugin only requires configuration if ssh authentication with the remote host requires username/password instead of ssh keys:

    ssh:
      <authentication configuration as explained above>

Using it is fairly straightforward:

    require 'cosmos2/galaxy'
    require 'cosmos2/ssh'

    services = with galaxy do
      select :type => /^echo$?/
    end
    with ssh do
      services.each do |service|
        puts exec :host => service.host, :user => 'eng', :cmd => 'uname -a'

        first = true
        upload :host => service.host, :user => 'eng', :local => ARGV[0] do |ch, name, sent, total|
          print "\r" unless first
          print "#{name}: #{sent}/#{total}"
          first = false
        end
        print "\n"
      end
    end

In this sample script, we first find all `echo` services on galaxy and then run `uname -a` on them. Then we upload a local file (passed in as a commandline argument) to the same path on the remote service. The script also prints out the progress of the upload while it is uploading the file.

## Chef

This plugin allows Cosmos2 scripts to interact with [Chef](http://www.opscode.com/chef/) in scripts. Currently this interaction is limited to retrieving information about nodes that Chef knows about, but support for applying roles to hosts and for [Chef Solo](http://wiki.opscode.com/display/chef/Chef+Solo) is planned.

The plugin uses the [Chef gem](https://rubygems.org/gems/chef):

    gem install chef

Currently the only available functionality is to retrieve information about a node that Chef knows about:

    require 'cosmos2/galaxy'
    require 'cosmos2/chef'
    require 'pp'

    with chef do
      pp get_info(:host => 'foo')
    end

This will print a hash with all data that Chef has about that particular host.

# Planned work

These are the currently planned plugins:

* Exec using [Open3](http://www.ruby-doc.org/stdlib-1.9.2/libdoc/open3/rdoc/Open3.html)
* E-mail using [mail](https://github.com/mikel/mail)
* Nagios probably using [ruby-nagios](https://code.google.com/p/ruby-nagios/)

In addition, these are the planned improvements to existing plugins

* Support in the Chef plugin for applying roles to hosts, plus support for Chef Solo

# Writing new plugins

Writing Cosmos2 plugins is fairly straightforward, but in order to keep the API consistent, there are a few rules and suggestions

## Ruby 1.8.x vs. 1.9, Ruby vs. JRuby

In general, plugins should work with both Ruby & JRuby, 1.8.7 and 1.9.x versions, unless 1.9 or JRuby are absolutely needed. In particular, Ruby 1.9-specific syntax should be avoided unless the plugin requires Ruby 1.9.

## Cosmos2 environment integration

Plugins should use the environment's authentication system (if they need authentication) as much as possible. Likewise, plugins should not log directly to a file or stdout/stderr, but instead generate messages tagged with standard tags such as :debug, :info and :error, plus the plugin's name so that scripts and other plugins can operate on all messages from a given plugin.

In addition, if the plugin consumes messages, then the plugin should implement methods called `connect` and `disconnect` to provide a user with a consistent API. See the IRC and JIRA plugins for examples.

Cosmos2 also supports running multiple plugin instances under different names, potentially pointed to the same remote service. It is desirable if plugins support this mode and still be independent of each other.

## Dry-run mode

Plugins should always support dry-run mode, even if they only consume messages. E.g the IRC plugin will not actually connect to the IRC server and write messages to channels. Instead, plugins should generate messages tagged as `:dryrun` that state what the plugin would do. The exception to this rule is if the plugin needs to for instance query a remote service for the current state of the world. E.g. the Galaxy plugin will issue `show` commands to Galaxy even in dry-run mode, so that it can return the services to the script.

## Threading

Cosmos2 is deliberately single-threaded unless it can't be avoided. This means that for instance the message bus will only return from the notify method once all listeners have been notified. Therefore, self referential code such as listening for its own messages should be avoided.

## Plugin API

Plugins should extend the plugin base class which gives them the optional sections capability.
Public methods in the plugin are considered its API and thus should be documented (with [Yard](http://yardoc.org/) using [Markdown](http://daringfireball.net/projects/markdown/) syntax).
All API methods that have arguments, should only take parameter hashes with symbols as keys. This keeps the API consistent and expressive (named parameters).
API method names should be actions and so the names should be or at least use verbs (e.g. `take_snapshot` instead of `snapshot`).
API methods should objects that are useful to the script. For instance, a lot of the JIRA plugin methods deal with JIRA issues. All of these methods return an object representing the JIRA issue which can be passed in again to other methods on the plugin.

## Error handling

For now, error handling is up to the plugin. All built-in plugins simply pass the error from the underlying library up to the calling script (unless they can handle the error). No error wrapping is performed, primarily because Ruby has unchecked errors anyways.

