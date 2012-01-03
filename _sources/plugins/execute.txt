.. _`Open4 gem`: https://github.com/ahoward/open4

Execute
=======

This plugin allows Cosmic scripts to run simple commands on the current machine. For non-JRuby platforms, it uses the `Open4 gem`_::

    gem install open4

When using JRuby, it will instead use ``IO:open4`` which comes as part of JRuby.

The plugin does not require any configuration.

Usage is straightforward::

    require 'cosmic/execute'

    with execute do
      status, output = exec :cmd => 'ls -la'
      puts "Completed with status #{status}:"
      puts output
    end

This simply runs ``ls -la`` and then prints the status code of the command and its output (``stdout`` and ``stderr`` combined) to ``stdout``.
