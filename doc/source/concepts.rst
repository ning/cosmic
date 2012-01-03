Concepts
********

Plugins
=======

The Cosmic core provides little in terms of actual deployment support, all that is contained in the plugins. Each Cosmic plugin is a wrapper around an existing ruby library or external API that simplifies interaction with the service specifically for deployments. This also means that you won't have access to all capabilities of that service, only to those that make sense for deploying machines/services. However, plugins usually provide access to the underlying library/API so that you can interact with that directly if necessary.

Authentication system
=====================

Cosmic provides built-in support for authentication that can be used by all plugins. The goal there is to perform deployments as a specific person and not using some general account such as ``root`` or ``eng`` or something like that. This allows to track deployments more accurately and also to have more fine-grained control over who can perform which deployment steps. 

Cosmic itself can currently authenticate against an LDAP server, and then pull credentials from there to authenticate other services, or use the LDAP credentials themselves for LDAP-enabled services. Depending on the service setup, this would allow a single-sign-on style deployment where the person performing the deployment only has to authenticate once at the start of the deployment, and from then on all other steps would be automatically authenticated by Cosmic.

Messages
========

The environment that Cosmic plugins run in, provides the ability to send and listen to messages. These messages are basically tagged strings. A plugin then can express interest in messages with specific tags. In addition, deployment scripts can wire some plugins to specific tags, e.g.::

    irc.connect :channel => '#test', :to => [:info, :galaxy]
    notify :msg => 'A message, yay !', :tags => :info

This example wires a specific IRC channel, ``#test``, to all messages that are tagged ``:info`` or ``:galaxy``, and then sends an explicit message tagged as ``:info``, which because of the wiring will then be posted by the IRC plugin to that channel.

Cosmic plugins usually either produce messages (these are typically the plugins that perform actual deployment steps) or consume message (e.g. for keeping record of the deployment progress).

Dry-run
=======

One of the core concepts of Cosmic is the dry-run mode. When it is turned on (via configuration or commandline switch), then all plugins will omit messages that by default are output to standard out, instead of performing the actions. In effect, the script will output the steps it would take, but not actually perform these steps.

DSL
===

Cosmic adds only a few pieces of syntactic sugar, all geared at eliminating syntactic noise and keeping the scripts short and to the point.

``with`` constructs
-------------------

Cosmic borrows the ``with`` construct from languages such as JavaScript or Pascal and provides it in two flavors::

    with irc do
      write :msg => 'Hello world', :channels => '#test'
    end

or::

    with_available irc do
      write :msg => 'Hello world', :channels => '#test'
    end

Both of these are equivalent to::

    irc.write :msg => 'Hello world', :channels => '#cosmic'

They differ in how they handle the case that the object, in the example above the ``irc`` plugin, is not available. This is explained in more detail below in the description of optional sections.

The benefit of the ``with`` constructs is that multiple calls to methods on the same object can be grouped into one ``with`` statement which reduces the noise and makes the code more readable. It also makes it more obvious that the methods are called on the same object.

The other benefit is that this makes optional sections possible as explained below.

Simplified plugin interaction
-----------------------------

Within the context of a Cosmic environment instance, plugins can simply be instantiated and used by their name::

    cosmic = Cosmic::Environment.from_config_file

    with cosmic do
      with irc do
        write :msg => 'Hello world', :channels => '#test'
      end
      ...
      with irc do
        write :msg => 'Goodbye world', :channels => '#test'
      end
    end

This will automatically create an IRC instance in the first ``with irc`` block using the environment's configuration (as explained below) and use it. The plugin then gets cached under that name ``irc``, so that the second block will simply use the same instance.

Optional sections
-----------------

Optional sections are groups of statements that get executed if a certain plugin is defined, otherwise they are ignored. Usually you would use ``if`` or ``unless`` statements in Ruby. Cosmic provides a shortcut syntax that makes this more concise::

    with irc? do
      write :msg => 'Hello world', :channels => '#test'
    end

or::

    irc?.write :msg => 'Hello world', :channels => '#test'

vs.::

    with_available irc? do
      write :msg => 'Hello world', :channels => '#test'
    end

The question mark after the plugin's short name directs Cosmic to not fail if the plugin is not configured. Note that this does not matter to all plugins. Some plugins such as the ``ssh`` plugin don't require any configuration (though they might have optional configuration) and thus would always be available. If however a name is used that does not map to a plugin (e.g. ``my-ssh``), then a configuration section for that name is required and optional sections apply.

The first two forms above (``with`` section and direct invocation) will actually execute the code, but they will do so against a so-called honey pot. This has the benefit that any code in the ``with`` block that does not use the plugin itself, will still get executed.

The third form will only execute the code in the block if the plugin is actually available.

One common use case for these forms is using the same deployment script in production and QA or development environments. Some services would only be configured in the production environment, so in the script they would be referenced with a ``?``.

Optional error handling
-----------------------

In a similar way to optional sections, Cosmic allows to make potential errors raised by a method call optional. The typical use case for this would be to differenciate required functionality from optional functionality that should not affect the deployment. For example in::

    with irc do
      write msg: 'Hello world', channels: '#test'
    end

if the call to ``write`` causes an error, for instance because the connection to the IRC server was dropped, then this would cause the deployment script to fail even if it is actually not critical to the deployment itself. If instead you write this as::

    with irc do
      write? :msg => 'Hello world', :channels => '#test'
    end

then an error raised by the ``write`` method will be emitted as an error message (see below) but otherwise ignored and the deployment can continue.
