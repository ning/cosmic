.. _`Mail gem`: https://github.com/mikel/mail

E-mail
======

This plugin allows Cosmic scripts to send email. It uses the `Mail gem`_::

    gem install mail

The plugin can either use a running Postfix or Sendmail daemon in which case no further configuration is necessary. Or you configure the mail delivery method in the configuration file::

    mail:
      delivery_method: <smtp or sendmail>
      smtp:
        address: <mail server; defaults to localhost>
        port: <mail send port; defaults to 25>
        domain: <the mail domain; defaults to localhost.localdomain>
        authentication: <plain, login, cram_md5; off by default>
        enable_starttls_auto: <true or false; true is default>
      sendmail:
        location: <absolute path to sendmail, defaults to /usr/sbin/sendmail>
      <authentication configuration as explained above>

Usage is straightforward::

    require 'cosmic/mail'

    with mail do
      send :from => 'me@example.com',
           :to => 'you@example.com',
           :subject => 'Test 1',
           :body => 'Test 1'

      send do
        from    'me@example.com'
        to      'you@example.com'
        subject 'Test 2'

        text_part do
          body 'This is plain text'
        end

        html_part do
          content_type 'text/html; charset=UTF-8'
          body '<h1>This is HTML</h1>'
        end
      end
    end

The first send call uses the simple API which only suppors subject & plain text body sending. The second send call uses the mail creation support via blocks provided by the `Mail gem`_ to send a multipart email with both text and html bodies.
