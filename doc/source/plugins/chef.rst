.. _`Chef`: http://www.opscode.com/chef/
.. _`Chef Solo`: http://wiki.opscode.com/display/chef/Chef+Solo
.. _`Chef gem`: https://rubygems.org/gems/chef

Chef
====

This plugin allows Cosmic scripts to interact with `Chef`_ in scripts. Currently this interaction is limited to retrieving information about nodes that Chef knows about, and to apply roles to hosts. Support for `Chef Solo`_ is planned.

The plugin uses the `Chef gem`_::

    gem install chef

Please note that chef currently does not support JRuby.

Currently the only available functionality is to retrieve information about a node that Chef knows about::

    require 'cosmic/galaxy'
    require 'cosmic/chef'
    require 'pp'

    with chef do
      pp get_info(:host => 'foo')
    end

This will print a hash with all data that Chef has about that particular host.
