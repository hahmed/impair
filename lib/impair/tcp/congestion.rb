# frozen_string_literal: true

module Impair
  class Tcp
    # The sender's window, per direction per connection. An isolated loss
    # halves it; a run long enough to defeat fast retransmit charges the RTO
    # and collapses it to one segment. Afterwards each delivered segment is
    # paced by the window: a window of w segments drains in one RTT, so each
    # costs rtt / w. Growth is slow start up to ssthresh, one segment per RTT
    # beyond it (RFC 5681 3.1), and the ceiling is the initial window, because
    # the relay has no bandwidth estimate to grow past it.
    class Congestion
      FAST_RETRANSMIT_THRESHOLD = 3 # dupacks needed; a run this long has none
      INITIAL_WINDOW = 10.0 # segments, RFC 6928
      MIN_WINDOW = 2.0 # RFC 5681 3.2: ssthresh = max(FlightSize / 2, 2 * SMSS)

      attr_reader :cwnd, :ssthresh

      def initialize(config)
        @config = config
        @on = config.congestion
        @run = 0
        @cwnd = INITIAL_WINDOW
        @ssthresh = Float::INFINITY
      end

      # Returns [stall_seconds, rto_fired?].
      #
      # A run of losses is one timer event, not one per segment. Every
      # segment in the run was in flight when the timer expired, and all of
      # them go out again with the retransmit, so the loss that defeats fast
      # retransmit pays the RTO and the rest of the run pays nothing more. A
      # link model that says "lost" ten times in a row is describing one
      # window, not ten probes.
      #
      # Not modelled: exponential backoff when the probe itself is lost. The
      # loss pattern cannot say which segment is the probe, so charging it
      # would mean charging it for every segment in the window, which is how
      # a 10-segment burst came to cost 25 seconds. One RTO per burst is the
      # floor of what TCP pays, and still an order of magnitude more than the
      # one-RTT stall it was charged before.
      def lost
        @run += 1
        return [@config.rtt, false] unless @on

        if @run == 1
          # Fast retransmit: one RTT, and the window halves. Charged on the
          # first loss of a run only; a run is one congestion event.
          @ssthresh = [@cwnd / 2, MIN_WINDOW].max
          @cwnd = @ssthresh
          return [@config.rtt, false]
        end
        return [@config.rtt, false] if @run < FAST_RETRANSMIT_THRESHOLD
        return [0.0, false] if @run > FAST_RETRANSMIT_THRESHOLD

        # The timer fired. ssthresh was already set on the first loss of the
        # run; the window now goes to one segment (RFC 5681 3.1).
        @cwnd = 1.0
        [[@config.rto_min, @config.rtt * 2].max, true]
      end

      # Returns the pacing cost of delivering one segment under the window.
      def delivered
        @run = 0
        return 0.0 unless @on && @cwnd < INITIAL_WINDOW

        cost = @config.rtt / @cwnd
        # Slow start doubles per RTT (one segment per ack, so +1 per segment);
        # congestion avoidance adds one per RTT (+1/cwnd per segment).
        increment = @cwnd < @ssthresh ? 1.0 : 1.0 / @cwnd
        @cwnd = [@cwnd + increment, INITIAL_WINDOW].min
        cost
      end
    end
  end
end
