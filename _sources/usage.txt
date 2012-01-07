.. _`cosmic-standalone`: https://github.com/ning/cosmic-standalone

How to use Cosmic
*****************

Cosmic can be used in three ways: via the commandline tool ``cosmic`` that gets installed as part of the gem, as a library from your own ruby scripts, or via a standalone executable.

Commandline tool
================

The commandline tool ``cosmic`` is installed as part of the cosmic gem. It provides a simple ruby commandline script that automatically creates a Cosmic environment and then executes your script in it. This means that your script shouldn't instantiate the Cosmic environment and instead should simply depend on it being available::

    require 'cosmic/irc'

    with irc do
      write :msg => ARGV[0], :channels => '#test'
    end
    ...

You will still have to require all plugins that you want to use - Cosmic will not require them automatically.

The above script ``irc-test.rb`` could then be invoked as::

    cosmic irc-test.rb 'Hello World'

You can get a list of supported options via the ``-h``/``--help`` option:

    Usage: cosmic [options] <script> [<commandline arguments for the script>]
        -h, --help                       Display this screen
        -d, --dry-run                    Runs the script(s) in dry-run mode
        -c, --config-file PATH           Specifies the config file to use
        -v, --verbose                    Turns on verbose output

Standalone tool
===============

This is a separate project `cosmic-standalone`_ that bundles the gem with all plugins that it is allowed to bundle (some are omitted due to license restrictions) with jruby into an executable jar file. You can simply download the executable and, provided you jave Java 6 or newer installed, run as is. See the documentation for that project for more details about which plugins are included and which have to be installed separately.

Using Cosmic in your own scripts
================================

You can also require the cosmic gem in your scripts. You will then have to create the Cosmic environment yourself, e.g.::

    require 'cosmic'
    require 'cosmic/irc'

    cosmic = Cosmic::Environment.from_config_file

    with cosmic do
      with irc do
        write :msg => 'Hello world', :channels => '#test'
      end
      ...
    end
