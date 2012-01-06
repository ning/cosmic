.. _`Net::SSH and Net::SCP`: http://net-ssh.github.com/

SSH
===

With the SSH plugin Cosmic scripts can execute commands on remote hosts and upload files to/download files from them.

It uses the `Net::SSH and Net::SCP`_ libraries::

    gem install net-ssh net-scp

The plugin only requires configuration if ssh authentication with the remote host requires username/password instead of ssh keys::

    ssh:
      <authentication configuration as explained above>

Using it is fairly straightforward::

    require 'cosmic/galaxy'
    require 'cosmic/ssh'

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

In this sample script, we first find all ``echo`` services on galaxy and then run ``uname -a`` on them. Then we upload a local file (passed in as a commandline argument) to the same path on the remote service. The script also prints out the progress of the upload while it is uploading the file.
