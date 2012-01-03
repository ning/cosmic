Introduction
************

Cosmic is a Ruby library and commandline tool for service deployment automation. The core idea is that deployments of machines & services should be scripted so that they are reproducable and easier to understand. Cosmic' aim is to help writing these scripts by providing a simplified interface to services commonly used during deployment plus a little bit of DSL sugar to keep the scripts concise and easy to understand. The DSL part is kept to a minimum however, Cosmic scripts are still normal Ruby scripts with all the benfits that that brings.

Cosmic itself requires Ruby 1.8.7 or newer, however some plugins require Ruby 1.9 (e.g. the IRC plugin) or JRuby (e.g. the JMX plugin).

.. toctree::
   :maxdepth: 2

   concepts
   usage
   configuration
   plugins
   recipes
   contributing
