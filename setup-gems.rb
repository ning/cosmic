#!/usr/bin/env ruby
require 'rubygems'
require 'rubygems/dependency_installer'

# A simple helper script for setting up the current ruby env with all gems that cosmic can use
# Note that some gems require jruby or 1.9 mode
# In addition to the standard gems, it will also install any files passed as commandline arguments
# This is useful for e.g. the galaxy and f5 gems which are not in rubygems.org

def install_dep(dep)
  puts "Installing #{dep}"
  Gem::DependencyInstaller.new.install(dep)
end

JRUBY = defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby'
RUBY_19 = RUBY_VERSION =~ /^1.9/

['rake', 'yard', 'jeweler', 'highline', 'net-ldap', 'chef', 'tomdz-soap4r', 'tomdz-jira4r', 'nokogiri', 'mail', 'json', 'net-ssh', 'net-scp', 'atomic'].each do |dep|
  install_dep(dep)
end

if RUBY_19
  ['cinch', 'celluloid'].each do |dep|
    install_dep(dep)
  end
end
if JRUBY
  ['jmx4r'].each do |dep|
    install_dep(dep)
  end
end

if ARGV.length > 0
  ARGV.each do |arg|
    install_dep(arg)
  end
end
