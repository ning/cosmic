Introduction
************

Cosmic is a Ruby library and commandline tool for service deployment automation. The core
idea is that deployments of machines & services should be scripted so that they are reproducible
and easier to understand. Cosmic' aim is to help writing these scripts by providing a simplified
interface to services commonly used during deployment plus a little bit of DSL sugar to keep the
scripts concise and easy to understand. The DSL part is kept to a minimum however, Cosmic scripts
are still normal Ruby scripts with all the benfits that that brings.

Cosmic itself requires Ruby 1.8.7 or newer, however some plugins require Ruby 1.9 (e.g. the IRC
plugin) or JRuby (e.g. the JMX plugin).

Cosmic is licensed under the Apache Software License, version 2.

Example
*******

The following is an example of a Cosmic script that updates a hypothetical ``echo`` service via
``galaxy``:

    require 'highline/import'
    require 'cosmic/galaxy'
    require 'cosmic/irc'

    version = ARGV[0]

    raise "No version specified" if version.nil? || version == ''

    info_channel = config[:deployments][:irc][:info_channel] || nil
    trace_channel = config[:deployments][:irc][:status_channel] || nil

    galaxy_service_regex = /^echo(\/.*)?$/

    services = galaxy.select :type => galaxy_service_regex
    snapshot = galaxy.take_snapshot

    unless galaxy.config[:relaxed_versioning]
      # Filter services that are already on the version
      services = services.reject do |agent|
        agent.version == version
      end
    end

    with_available irc? do
      connect :channel => info_channel, :to => [:info, :error], :prefix => "[#{version}] " if info_channel
      connect :channel => trace_channel, :to => [:info, :trace, :warn, :error], :prefix => "[#{version}] " if trace_channel
    end

    notify :msg => "Starting deployment of #{version}", :tags => :info

    begin
      first_service, *remaining_services = *services
      update :service => first_service, :to => version
      start :service => first_service

      if in_dry_run_mode
        response = 'c'
      elsif remaining_services.empty?
        response = ask("Service #{first_service.host} (#{first_service.type}) updated & restarted, [c]ontinue or [r]evert ?") { |q| q.in = 'cr' }
      else
        response = ask("Service #{first_service.host} (#{first_service.type}) updated & restarted, [c]ontinue, [r]evert, [a]bort ?") { |q| q.in = 'cra' }
      end
      case response.downcase
        when 'c'
          notify :msg => "Continuing deployment of #{version}", :tags => :info

          update :services => services, :to => version
          start :services => services

          notify :msg => "Finished deployment of #{version}", :tags => :info
        when 'r'
          notify :msg => "Reverting #{first_service.host} (#{first_service.type})", :tags => :info

          with galaxy do
            revert :service => first_service, :to => snapshot
            start :service => first_service
          end

          notify :msg => "Reverted deployment of #{version}", :tags => :info
        else
          notify :msg => "Aborted deployment of #{version}", :tags => :info
      end
    rescue => e
      puts "#{$!}\n\t" + e.backtrace.join("\n\t")
      notify :msg => "Encountered error: #{e}; rolling back #{version}", :tags => :error
      with galaxy do
        revert? :services => services, :to => snapshot
      end
      notify :msg => "Rolled back deployment of #{version}", :tags => :info
    ensure
      with_available irc? do
        leave :channel => trace_channel, :msg => 'Bye' if trace_channel
        leave :channel => info_channel, :msg => 'Bye' if info_channel
      end
    end

Typically, scripts for services will look very similar and lend themselves well to extracting
a environment-specific DSL/library on top of Cosmic which would reduce the length of these scripts
significantly. 

.. toctree::
   :maxdepth: 2

   concepts
   usage
   configuration
   plugins
   recipes
   contributing
