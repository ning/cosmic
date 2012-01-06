.. _`Galaxy`: https://github.com/ning/galaxy

Galaxy
======

This plugin makes the `Galaxy`_ software deployment tool available to Cosmic scripts.

Cosmic requires Galaxy version 2.5.1 or newer, or 2.5.1.1 for Ruby/JRuby 1.9 compatibility. You can install Galaxy via::

    gem install galaxy

The plugin is configured as follows::

    galaxy:
      host:               <The gonsole host; default is localhost>
      port:               <The galaxy port; default is 4440>
      relaxed_versioning: <Whether to use relaxed versioning; default is false>

Galaxy itself does not support authentication, so no such configuration is necessary for it.

The Galaxy plugin makes it straightforward to use Galaxy commands from within Cosmic scripts and it adds additional functionality not readily available in Galaxy (e.g. reverting to a previous snapshot). A simple Cosmic script using Galaxy would look like::

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

This script first connects an IRC channel to all messages created by the Galaxy plugin. Next it takes a snapshot of the current state of the Galaxy environment and then selects all services of type ``echo``. It then tries to update these services and in case of failure, attempts to revert them to the previous snapshot. Finally it starts the services.
