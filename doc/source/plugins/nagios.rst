.. _`Nagix`: https://github.com/ning/nagix

Nagios
======

Nagios currently doesn't provide a simple way to interact with it remotely. To help with this, Ning has a project called `Nagix`_ that provides a REST server and CLI for Nagios. Tools can then interact with the REST server remotely to access status information or issue commands against a Nagios instance.

The Nagios plugin interacts with a Nagix instance and provides a simplified interface to retrieve status information about hosts and enable/disable notifications for hosts and their services. In order to use it, you'll first have to install the json gem::

    gem install json

Currently the only piece of configuration necessary is the host url for the Nagix server::

    nagios:
      nagix_host: <full host url for the Nagix server, e.g. http://nagix.example.com:8080>

Scripts can then interact with the Nagios server::

    require 'cosmic/nagios'

    with nagios do
      was_enabled = enabled? :host => ARGV[0]
      disable :host => ARGV[0], :service => ARGV[1]
      ...
      enable  :host => ARGV[0], :service => ARGV[1] if was_enabled
    end
