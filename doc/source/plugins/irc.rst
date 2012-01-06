.. _`Cinch library`: https://github.com/cinchrb/cinch

IRC
===

The Cosmic IRC plugin allows Cosmic scripts to interact with an IRC server. The IRC support however is limited to posting messages and similar things, it intentionally does not provide a full IRC bot that can be interacted with.

The plugin uses the `Cinch library`_ and thus requires (J)Ruby 1.9. You'll need to install the cinch and atomic gems in order to be able to use the plugin::

    gem install cinch atomic

The plugin configuration looks like this::

    irc:
      host:                   <IRC server; default is localhost>
      port:                   <IRC server port; default is 6667>
      nick:                   <IRC nick to use; default is cosmic>
      connection_timeout_sec: <Connection timeout; default is 60>
      <authentication configuration as explained above>

The IRC plugin is typically used to post status updates to specific IRC channels. Code for that would look like::

    with irc do
      write :msg => 'Starting deployment', :channels => '#status'
      connect :channel => '#status', :to => :info
    end
    ...
    with irc do
      write :msg => 'Deployment finished', :channels => '#status'
      leave :channel => '#status', :msg => 'Bye'
    end

In this example, the script first writes an explicit message to the ``#status`` IRC channel, and then connects that channel to all messages tagged as ``:info``. After the deployment has been completed, the script then writes another message to the IRC channel and leaves the channel (which will automatically disconnect it from the message bus).
