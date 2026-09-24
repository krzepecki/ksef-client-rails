# frozen_string_literal: true

module Ksef
  # Polling helper for async operations: auth, sessions, export, enrollment, permissions.
  # The block returns {.pending} to keep waiting (backoff + Retry-After); any other value is the
  # result. Backoff is a deliberate improvement over both SDKs, which poll only in their tests.
  module Polling
    # "Operation in progress" signal — optionally carries retry_after (seconds) from the server.
    Pending = Struct.new(:retry_after, keyword_init: true)

    module_function

    # @param retry_after [Numeric, nil] suggested delay before the next attempt (from Retry-After)
    # @return [Pending]
    def pending(retry_after: nil)
      Pending.new(retry_after: retry_after)
    end

    # Polls with exponential backoff until the block returns a value other than {.pending}.
    #
    # @param timeout [Numeric] maximum total wait time (s)
    # @param interval [Numeric] initial delay between attempts (s)
    # @param max_interval [Numeric] upper bound for the delay (s)
    # @param backoff [Numeric] delay growth multiplier
    # @param logger [Logger, nil]
    # @param description [String] operation description for logs and the timeout message
    # @yieldreturn [Pending, Object] {.pending} to continue, anything else is the final result
    # @return [Object] the value returned by the block
    # @raise [Ksef::PollingTimeout] once +timeout+ is exceeded
    def run(timeout: 300, interval: 2.0, max_interval: 30.0, backoff: 1.5, logger: nil, description: "operation")
      start = clock
      current = interval.to_f
      last = nil
      loop do
        result = yield
        return result unless result.is_a?(Pending)

        last = result
        elapsed = clock - start
        if elapsed >= timeout
          raise PollingTimeout.new("Wait limit exceeded (#{timeout}s) for: #{description}",
                                   last_status: describe(last))
        end

        wait = wait_seconds(result, current, timeout - elapsed)
        logger&.debug("[ksef] polling #{description}: waiting #{wait.round(1)}s (elapsed #{elapsed.round(1)}s)")
        sleep(wait) if wait.positive?
        current = [current * backoff, max_interval.to_f].min
      end
    end

    def wait_seconds(pending, current, remaining)
      wait = (pending.retry_after || current).to_f
      [wait, remaining].min
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def describe(pending)
      pending.retry_after ? "pending(retry_after=#{pending.retry_after})" : "pending"
    end
  end
end
