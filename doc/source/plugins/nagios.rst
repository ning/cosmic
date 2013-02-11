.. _`mk_livestatus`: http://mathias-kettner.de/checkmk_livestatus.html


Nagios
======

The only somewhat official way to control Nagios remotely involves running `mk_livestatus`_ and
then establishing an ssh connection to the Nagios server and talking to the unix socket that
mk_livestatus maintains.

The configuration values for the plugin are::

    nagios:
      host: <full host url for the Nagios server, e.g. http://nagios.example.com:8080>
      mk_livestatus_socket_path: <full path to the mk_livestatus socket, e.g. /var/lib/nagios/rw/live>
      <authentication configuration as explained for the ssh plugin>

Scripts can then interact with the Nagios server::

    require 'cosmic/nagios'

    with nagios do
      was_enabled = enabled? :host => ARGV[0]
      disable :host => ARGV[0], :service => ARGV[1]
      ...
      enable  :host => ARGV[0], :service => ARGV[1] if was_enabled
    end
