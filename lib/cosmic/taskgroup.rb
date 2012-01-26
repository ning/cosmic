require 'cosmic'
require 'logger'

if RUBY_VERSION < '1.9'
  desc = defined?(RUBY_DESCRIPTION) ? RUBY_DESCRIPTION : "ruby #{RUBY_VERSION} (#{RUBY_RELEASE_DATE})"
  abort <<-end_message

    Taskgroups require Ruby 1.9 or newer. You're running #{desc}
    Please upgrade to use it.

  end_message
end

require_with_hint 'celluloid', "In order to use taskgroups please run 'gem install celluloid'"

# Unfortunately we can't set a logger per actor/future
Celluloid.logger = Logger.new(STDOUT)
Celluloid.logger.level = Logger::ERROR

module Cosmic
  # Represents a group of tasks to be executed in parallel.
  class TaskGroup
    # The error type raised from methods in this class.
    class TaskError < StandardError; end

    # Creates a new task group.
    def initialize
      @tasks = []
      @futures = nil
    end

    # Adds a task. Note that you can't add tasks after the group has been started.
    #
    # @yield A block of arity 0 representing the task to execute later
    # @return [void]
    def add(&block)
      raise TaskError, "Can't add a task after the group has been started" unless @futures.nil?
      @tasks << block
      nil
    end

    # Starts all tasks.
    #
    # @return [void]
    def start
      return unless @futures.nil?
      @futures = @tasks.map do |task|
        Celluloid::Future.new(&task)
      end
    end

    # Waits for all tasks to finish.
    #
    # @return [Array<Object>] The return values of the tasks (if any)
    def wait_for
      raise TaskError, "The group hasn't been started yet" if @futures.nil?
      @futures.map do |future|
        future.value
      end
    end
  end
end
