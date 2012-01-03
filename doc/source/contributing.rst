.. _`Yard`: http://yardoc.org/
.. _`Markdown`: http://daringfireball.net/projects/markdown/
.. _`Sphinx`: http://sphinx.pocoo.org/

Contributing
************

Writing new plugins
===================

Writing Cosmic plugins is fairly straightforward, but in order to keep the API consistent, there are a few rules and suggestions

Ruby 1.8.x vs. 1.9, Ruby vs. JRuby
----------------------------------

In general, plugins should work with both Ruby & JRuby, 1.8.7 and 1.9.x versions, unless 1.9 or JRuby are absolutely needed. In particular, Ruby 1.9-specific syntax should be avoided unless the plugin requires Ruby 1.9.

Cosmic environment integration
------------------------------

Plugins should use the environment's authentication system (if they need authentication) as much as possible. Likewise, plugins should not log directly to a file or ``stdout``/``stderr``, but instead generate messages tagged with standard tags such as ``:debug``, ``:info`` and ``:error``, plus the plugin's name so that scripts and other plugins can operate on all messages from a given plugin.

In addition, if the plugin consumes messages, then the plugin should implement methods called ``connect`` and ``disconnect`` to provide a user with a consistent API. See the IRC and JIRA plugins for examples.

Cosmic also supports running multiple plugin instances under different names, potentially pointed to the same remote service. It is desirable if plugins support this mode and still be independent of each other.

Dry-run mode
------------

Plugins should always support dry-run mode, even if they only consume messages. E.g the IRC plugin will not actually connect to the IRC server and write messages to channels. Instead, plugins should generate messages tagged as ``:dryrun`` that state what the plugin would do. The exception to this rule is if the plugin needs to for instance query a remote service for the current state of the world. E.g. the Galaxy plugin will issue ``show`` commands to Galaxy even in dry-run mode, so that it can return the services to the script.

Threading
---------

Cosmic is deliberately single-threaded unless it can't be avoided. This means that for instance the message bus will only return from the notify method once all listeners have been notified. Therefore, self referential code such as listening for its own messages should be avoided.

Error handling
--------------

For now, error handling is up to the plugin. All built-in plugins simply pass the error from the underlying library up to the calling script (unless they can handle the error). No error wrapping is performed, primarily because Ruby has unchecked errors anyways.

Plugin API
----------

Plugins should extend the plugin base class which gives them the optional sections capability.
Public methods in the plugin are considered its API and thus should be documented (with `Yard`_ using `Markdown`_ syntax).
All API methods that have arguments, should only take parameter hashes with symbols as keys. This keeps the API consistent and expressive (named parameters).
API method names should be actions and so the names should be or at least use verbs (e.g. ``take_snapshot`` instead of ``snapshot``).
API methods should objects that are useful to the script. For instance, a lot of the JIRA plugin methods deal with JIRA issues. All of these methods return an object representing the JIRA issue which can be passed in again to other methods on the plugin.

Documentation
-------------

Please provide documentation for the plugin in `Sphinx`_ format.
