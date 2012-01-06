.. _`net-ldap`: http://net-ldap.rubyforge.org/
.. _`introduction to LDAP`: http://www.ldapman.org/articles/intro_to_ldap.html

Configuration
*************

Cosmic and the plugins are configured via a single YAML file. The default location for the file is ``$HOME/.cosmicrc``, but both the commandline tool and the ``Cosmic::Environment`` constructor support specifying a different file.

The basic environment configuration looks like this::

    auth_type: <Authentication type>
    <Authentication type configuration section>
    plugins:
      <Plugin configuration sections>

For example::

    auth_type: ldap
    ldap:
      host:       my-ldap-server.example.com
      port:       1636
      base:       dc=example,dc=com
      encryption: simple_tls
      auth:
        method:   simple
        username: cn=Directory Manager
        password: my-password
    plugins:
      irc:
        host:      irc.example.com
        port:      6667
        nick:      cosmic
        auth_type: credentials_from_env
        ldap:
          path:          o=irc.example.com,ou=apps,dc=example,dc=com
          password_attr: password

Authentication types
====================

Cosmic currently supports these authentication types:

ldap
^^^^

Cosmic will authenticate with a configured LDAP server before proceeding, using `net-ldap`_. The LDAP configuration has the following form::

    ldap:
      host:       <LDAP host>
      port:       <LDAP port>
      base:       <Base distinguished name of the server, usually an organization or domain component entry>
      encryption: <Encryption type, has to be simple_tls currently>
      auth:
        method:   <The autentication type, either simple or anonymous>
        username: <The LDAP username to authenticate with if simple auth is chosen, e.g. cn=Directory Manager>
        password: <The LDAP password>

If ``simple`` is chosen as the authentication method and username/password are not specified in the config, then Cosmic will prompt the user for username and password before proceeding.

See e.g. this `introduction to LDAP`_ for more info about LDAP.

credentials
^^^^^^^^^^^

With this authentication form, Cosmic will not authenticate itself but provide the credentials to plugins if they use the ``credentials_from_env`` authentication type (see below). The configuration looks like this::

    credentials:
      username: <The username>
      password: <The password>

If username/password are not specified in the config, then Cosmic will prompt the user for username and password before proceeding.

Plugin configuration
====================

All plugins are configured under the ``plugins`` section in the configuration. The configuration generally has this format::

    plugins:
      <Plugin name>:
        plugin_class: <Optional plugin class name>
        <Plugin-specific configuration>

Cosmic uses the plugin name and, if specified, the plugin class to instantiate the plugin and make it available to scripts. For instance, with this configuration section::

    plugins:
      irc:
        <IRC plugin configuration>

Cosmic will use this plugin section if used like this in a Cosmic environment::

    with irc do
      write :msg => 'Hello world', :channels => '#test'
    end

or::

    irc.write :msg => 'Hello world', :channels => '#test'

Since no plugin class is specified, it will search for the plugin under the class names

* ``Cosmic::#{name}``
* ``Cosmic::#{name.upcase}``
* ``Cosmic::#{camel_case_name}``
* ``#{name}``
* ``#{name.upcase}``
* ``#{camel_case_name}``

If it cannot find a plugin class, then it will raise an error unless a ``?`` was used. E.g.::

    with irc? do
      write :msg => 'Hello world', :channels => '#test'
    end

would not fail if no irc configuration section exists or the class could not be found.

The ``plugin_class`` configuration option allows you to specify the plugin class directly, and it also makes it possible to configure more than one plugin of the same type. E.g.::

    plugins:
      irc1:
        plugin_class: Cosmic::IRC
        <First IRC plugin configuration>
      irc2:
        plugin_class: Cosmic::IRC
        <Second IRC plugin configuration>

These two then can be used like so::

    with irc1 do
      write :msg => 'Hello world', :channels => '#test'
    end
    with irc2 do
      write :msg => 'Hello world', :channels => '#test'
    end

Plugin authentication
---------------------

Plugins can perform authentication through the Cosmic environment, or they can handle it themselves. Authenticating through Cosmic has the benefit that it can reduce the number of times that the user is asked for credentials. For instance, assume a plugin for a service that authenticates via LDAP. That plugin can then use the same LDAP credentials that Cosmic asked the user for at the beginning of the deployment session. Likewise, it is possible to store authentication information (e.g. tokens, keys, etc.) in LDAP and have Cosmic fetch it from there on behalf of a plugin.

For plugins, the Cosmic environment currently supports these authentication types:

credentials_from_env
^^^^^^^^^^^^^^^^^^^^

This type is used for cases where the environment stores the credentials and the plugin can simply ask the environment to retrieve them. It is currently only implemented for environments using LDAP authentication. In this case, the plugin's configuration is required to have a ``ldap`` configuration section that specifies the path to the credentials plus the names of the attributes for the username and password::

    plugins:
      irc:
        ...
        auth_type: credentials_from_env
        ldap:
          path:          o=irc.example.com,ou=apps,dc=example,dc=com
          password_attr: password

In this example, the ``o=irc.example.com,ou=apps,dc=example,dc=com`` LDAP entry contains an attribute called ``password`` which contains the password for the LDAP server. No username is specified, so Cosmic will not retrieve it (the IRC plugin doesn't require it if the IRC server doesn't need one).

ldap_credentials
^^^^^^^^^^^^^^^^

The ``ldap_credentials`` type is used for services that authenticate themselves against LDAP. The Cosmic environment in this case is required to use ``ldap`` authentication, and the plugin will simply use the same credentials as the environment, to authenticate.

credentials
^^^^^^^^^^^

This type describes the case where the plugin has its own set of credentials independent from the environment. Cosmic supports the plugin by dealing with the credential configuration or asking the user as necessary. If you choose to configure the credentials in the config file, then put them in a ``credentials`` sub section in the plugin configuration::

    plugins:
      irc:
        ...
        auth_type: credentials
        credentials:
          username: testuser
          password: my-password

Cosmic will ask the user for credentials if the element is not present in the configuration.

keys
^^^^

Some plugins can make use of keys directly (e.g. ssh). For these plugins, Cosmic supports two types of authentication: ``keys`` and ``keys_from_env``. The ``keys`` type simply allows to specify an array of file paths of the keys to use::

    plugins:
      ssh:
        ...
        auth_type: keys
        keys: [<path to key 1>, <path to key 2>, ...]

keys_from_env
^^^^^^^^^^^^^

With this authentication type, plugins ask the Cosmic environment to give them keys via whatever means the environment has configured. This is usually used in conjunction with ``ldap`` authentication for the environment itself, i.e. keys are retrieved from specific paths in the LDAP server. The plugin configuration would then define the paths and attributes to look for the key data::

    plugins:
      ssh:
        ...
        auth_type: keys_from_env
        ldap:
          key_path: <LDAP path to the keys; if not specified, then the entry for the current user is used instead>
          key_attrs: [<key attribute 1>, <key attribute 2>, ...]
