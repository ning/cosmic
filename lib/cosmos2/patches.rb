if defined?(RUBY_ENGINE) && RUBY_ENGINE == "jruby" && RUBY_VERSION =~ /^1.9/
  require 'net/protocol'

  # monkey patch to fix https://jira.codehaus.org/browse/JRUBY-5529
  Net::BufferedIO.class_eval do
    BUFSIZE = 1024 * 16

    def rbuf_fill
      timeout(@read_timeout) do
        @rbuf << @io.sysread(BUFSIZE)
      end
    end
  end
end
