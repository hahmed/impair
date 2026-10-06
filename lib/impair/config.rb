# frozen_string_literal: true

module Impair
  # One Config, both relays, same units. The whole point is comparing two
  # protocols on the same link, which is only true if "the same link" is one
  # object with one meaning on both sides.
  #
  # loss and reorder are 1-in-N, the way MsQuic's emulated-performance runs
  # express them. Zero disables. Delays are one-way seconds; TCP's stall per
  # lost segment is one round trip, derived as 2 * delay rather than
  # configured separately, because two knobs for one quantity is how the two
  # arms drift apart.
  #
  # burst is the mean length of a loss burst (Gilbert-Elliott). The overall
  # loss rate stays 1/loss whether burst is on or off, so loss: 50 means 2%
  # either way; burst only changes how the 2% clusters.
  #
  # corrupt, max_size and rate follow smoltcp's FaultInjector
  # (src/phy/fault_injector.rs, 0BSD). rate is a policer: packets per
  # interval, over-budget discarded. bandwidth is a shaper: bytes per second,
  # over-budget queued up to +queue+ bytes, then discarded. Use the shaper to
  # see queueing delay and congestion control; use the policer to see loss.
  #
  # mss, congestion and rto_min apply to TCP only. mss sets what counts as one
  # segment for the loss decision. congestion turns on the sender's reaction
  # to loss: an isolated loss halves the window (RFC 5681 3.2); three or more
  # consecutive losses leave no duplicate acks to trigger fast retransmit, so
  # the connection waits out the retransmission timer (rto_min, Linux's 200ms
  # floor), collapses its window to one segment and slow-starts back. Off,
  # every loss is a one-RTT stall and nothing more. corrupt, reorder and
  # max_size are accepted by TCP and ignored, because a byte stream cannot
  # carry them.
  Config = Struct.new(
    :loss, :burst, :reorder, :reorder_delay, :delay, :jitter, :corrupt, :max_size,
    :rate, :rate_interval, :bandwidth, :queue, :mss, :congestion, :rto_min, :seed,
    keyword_init: true
  ) do
    def initialize(loss: 0, burst: 0, reorder: 0, reorder_delay: 0.03, delay: 0, jitter: 0,
      corrupt: 0, max_size: 0, rate: 0, rate_interval: 0.1, bandwidth: 0, queue: 64_000,
      mss: 1460, congestion: true, rto_min: 0.2, seed: 1234)
      super
      validate!
    end

    def impairing?
      [loss, reorder, corrupt, max_size, rate, bandwidth].any?(&:positive?) ||
        [delay, jitter].any?(&:positive?)
    end

    def rtt = delay * 2

    def loss_rate = loss.positive? ? 1.0 / loss : 0.0

    def validate!
      %i[loss burst reorder corrupt max_size rate mss].each do |k|
        v = self[k]
        raise ArgumentError, "#{k} must be a non-negative integer, got #{v.inspect}" unless v.is_a?(Integer) && v >= 0
      end
      %i[reorder_delay delay jitter rate_interval bandwidth queue rto_min].each do |k|
        v = self[k]
        raise ArgumentError, "#{k} must be a non-negative number, got #{v.inspect}" unless v.is_a?(Numeric) && v >= 0
      end
      raise ArgumentError, "burst needs loss" if burst.positive? && loss.zero?
      raise ArgumentError, "mss must be positive" unless mss.positive?
      self
    end

    def with(**changes) = self.class.new(**to_h.merge(changes))
  end
end
