.. _`JMX resources`: http://docs.oracle.com/javase/tutorial/jmx/index.html
.. _`jmx4r gem`: https://github.com/jmesnil/jmx4r

JMX
===

The JMX plugin allows Cosmic scripts to interact with exposes `JMX resources`_ exposed by services running on the JVM.

This plugin requires JRuby and the `jmx4r gem`_::

    gem install jmx4r

The only configuration for the plugin is for authentication in cases where the JMX resources require it::

    jmx:
      <authentication configuration as explained above>

The plugin supports reading and setting attributes as well as invoking operations. For instance::

    require 'cosmic/galaxy'
    require 'cosmic/jmx'

    services = with galaxy do
      select :type => /^echo$?/
    end
    with jmx do
      mbeans = services.collect {|service| get_mbean :host => service.host, :port => 12345, :name => 'some.company:name=MyMBean'}
      mbeans.each do |mbean|
        old_value = get_attribute :mbean => mbean, :attribute => 'SomeAttribute'
        set_attribute :mbean => mbean, :attribute => 'SomeAttribute', :value => old_value + 1

        invoke :mbean => mbean, :operation => 'DoSomething', :args => [ 'test' ]
      end
    end

This collects ``some.company:name=MyMBean`` mbeans from all ``echo`` servers on galaxy, then increments the ``SomeAttribute`` attribute and finally invokes the ``DoSomething`` operation with a single string argument.
