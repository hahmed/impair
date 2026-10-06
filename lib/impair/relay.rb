# frozen_string_literal: true

module Impair
  # What Udp and Tcp share above the Link: lifecycle, counts, runtime control,
  # and self-verification.
  module Relay
    def self.included(base) = base.extend(ClassMethods)

    module ClassMethods
      # Build and start in one step. With a block, yields the running relay
      # and stops it afterwards, raise or not, returning the counts.
      def start(...)
        relay = new(...).start
        return relay unless block_given?

        begin
          yield relay
        ensure
          relay.stop
        end
        relay.counts
      end
    end

    attr_reader :port

    def config = @link.config
    def counts = @link.counts
    def trace = @link.trace

    def update(**changes)
      @link.update(**changes)
      self
    end

    def blackhole(seconds)
      @link.blackhole(seconds)
      self
    end

    # What the relay never got to make a decision about.
    #
    # The kernel drops datagrams that arrive while the receive buffer is full,
    # before the relay sees them. Those are invisible to every counter here:
    # they thin forwarded and dropped together, so loss_rate stays flat at the
    # advertised figure while the actual link loses far more. A relay that
    # cannot keep up reports a healthy 2% on a link losing 26%.
    #
    # So a caller that knows how many packets it offered must check. Pass a
    # total, or per direction. Counting every decision is only a guarantee for
    # decisions the relay was handed.
    def shortfall(total = nil, client: nil, server: nil)
      raise ArgumentError, "pass a total or client:/server:" if total.nil? && client.nil? && server.nil?

      tally = if total
        counts.combined
      else
        [client && counts.client, server && counts.server].compact.reduce(:+)
      end
      offered = total || (client.to_i + server.to_i)
      seen = tally.total + tally.overrun
      unreceived = offered - seen
      missing = unreceived + tally.overrun
      { offered: offered, observed: tally.total, overrun: tally.overrun,
        unreceived: unreceived, missing: missing,
        rate: offered.zero? ? 0.0 : missing.fdiv(offered) }
    end

    # Raises unless the relay saw essentially everything that was sent. Use
    # this to gate a published throughput number.
    def verify!(total = nil, tolerance: 0.01, **directions)
      result = shortfall(total, **directions)
      return result if result[:rate] <= tolerance

      raise Error, format(
        "relay lost %d of %d packets before impairing them (%.1f%%): %d never received " \
        "(kernel buffer), %d overran the processing queue. Measured link loss is not the " \
        "configured loss.%s Lower the offered rate.",
        result[:missing], result[:offered], result[:rate] * 100,
        result[:unreceived], result[:overrun],
        respond_to?(:rcvbuf) ? " rcvbuf=#{rcvbuf}." : ""
      )
    end
  end
end
