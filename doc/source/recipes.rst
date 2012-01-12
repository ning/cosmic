.. _`highline`: https://github.com/JEG2/highline

Recipes
*******

Passing arguments to scripts
----------------------------

Cosmic follows standard conventions for separating its own arguments from arguments to the script::

    cosmic <cosmic args> <script name> -- <script args>

E.g.::

    cosmic -c ~/.cosmicrc my-script.rb -- -v -t 'foo'

Configuration for scripts
-------------------------

Scripts can have their own configuration in the cosmic configuration file. Simply add a section to it, e.g.::

    < cosmic configuration >
    scripts:
      myscript:
        arg: foo

and then read it out in the script via the ``cosmic`` instance (which is in scope automatically for scripts run via the ``cosmic`` executable)::

    arg = cosmic.config[:scripts][:myscript][:arg]

Using the same script in different environments
-----------------------------------------------

Suppose you have two environments, staging and production, and you want to run the same script in both. The simplest way to achieve that is to use two different configuration files, e.g. ``.cosmic-staging`` and ``.cosmic-production`` and pass the configuration to use via the ``-c`` commandline option.

In the configuration file you would then configure the plugins appropriately. For services that are not present in an environment (or that you don't want to use), you'd simply not include a configuration section in the corresponding configuration file, and use the ``?`` operator in the script.

E.g. let's say we want to interact with IRC only in the production environment. Then in your script you'd use the ``irc`` plugin like so::

    with irc? do
      ...
    end

and only have configuration for the ``irc`` plugin in the production environment. This will still execute the block, however it will be executed against a so-called ``HoneyPot`` instance that stands in for the ``irc`` instance in this case. This instance will accept all calls to it, then simply not do anything other than return itself.

This will work in a lot of cases, but sometimes it might cause odd errors. In those cases you can either check if the object you are working with is a honey pot::

    with jira? do
      issue = create ...
      unless issue.is_honey_pot
        ...
      end
    end

or use ``with_available`` which will only run the code if the plugin is actually available::

    with_available jira? do
      issue = create ...
      ...
    end

Dealing with dry-run mode
-------------------------

Sometimes it is unavoidable to make the script aware of whether dry-run mode is enabled or not. Typically this is the case when the script relies on the data returned by some action that is not performed during dry-run mode. For instance::

    require 'cosmic/jira'

    issue = with jira? do
      create_issue :project => 'COS', :type => 'New Feature', :summary => "foo", :description => "bar"
    end

    puts "Issue is: #{issue.key}"

In dry-run mode, ``issue`` will be ``nil`` which leads to an error on the ``puts`` line::

    NoMethodError: undefined method `key' for nil:NilClass

There are two basic strategies to deal with this: check values for ``nil`` and react appropriately, or execute code blocks only if dry-run mode is not enabled.

The former could look like this::

    require 'cosmic/jira'

    issue = with jira? do
      create_issue :project => 'COS', :type => 'New Feature', :summary => "foo", :description => "bar"
    end

    puts "Issue is: #{issue.key}" if issue

The latter makes use of the implicitly available ``cosmic`` environment instance::

    require 'cosmic/jira'

    unless cosmic.in_dry_run_mode
      issue = with jira? do
        create_issue :project => 'COS', :type => 'New Feature', :summary => "foo", :description => "bar"
      end

      puts "Issue is: #{issue.key}" if issue
    end

Continue/abort scripts
----------------------

Sometimes you want to write a script that performs a single action first, then asks the user whether to continue or not, and then either aborts (or rolls back the changes) or continues. Cosmic uses the `highline`_ gem which makes things like that easy. For example, let's say you want to update a bunch of services via galaxy. Without any user interaction, this could look like::

    require 'cosmic/galaxy'

    with galaxy do
      services = select :type => ...
      update :services => services, :to => ...
      restart :services => services
    end

This will update all selected services without any user interaction. Now if you want to update only the first one, and then give the user the ability to check that the update was fine and potentially abort or roll back the update, you could use code like this:

    require 'cosmic/galaxy'
    require 'highline/import'

    services = galaxy.select :type => ...
    first_service, *remaining_services = *services

    with galaxy do
      update :service => first_service, :to => ...
      restart :service => first_service
    end

    response = ask("Service #{first_service.host} updated & restarted, [c]ontinue, [r]evert, [a]bort ?") { |q| q.in = 'cra' }
    case response.downcase
      when 'c'
        with galaxy do
          update :services => remaining_services, :to => ...
          restart :services => remaining_services
        end
      when 'r'
        with galaxy do
          revert :service => first_service, :to => services
        end
    end
