# frozen_string_literal: true

require "socket"

require_relative "impair/version"

# Network impairment in userspace, for measuring what a damaged link does to a
# protocol.
#
# The problem this solves: on macOS, dummynet does not shape the loopback
# interface, so an induced-loss experiment reports "loss changes nothing" while
# quietly dropping no packets at all. Kernel shaping also applies host-wide,
# which is a blunt instrument for one benchmark. Everything portable is TCP
# only, and QUIC is UDP.
#
# So this sits between client and server as a relay and damages what passes
# through:
#
#   client ──▶ Impair::Udp ──▶ server
#
# Design follows MsQuic's DuoNic, which drives its emulated-performance runs
# with a loss denominator, a reorder denominator, a reorder delay and a seed
# (scripts/emulated-performance.ps1 in the MsQuic tree). Denominators rather than
# percentages, because "one packet in 50" is how loss is reasoned about, and a
# seed because a benchmark you cannot repeat is an anecdote.
#
# Counts every decision, so an experiment can assert the impairment happened
# rather than trusting that it did.
module Impair
  Error = Class.new(StandardError)

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
  # mss applies to TCP only, where it sets what counts as one segment for the
  # loss decision. corrupt, reorder and max_size are accepted by TCP and
  # ignored, because a byte stream cannot carry them.
  Config = Struct.new(
    :loss, :burst, :reorder, :reorder_delay, :delay, :jitter, :corrupt, :max_size,
    :rate, :rate_interval, :bandwidth, :queue, :mss, :seed, keyword_init: true
  ) do
    def initialize(loss: 0, burst: 0, reorder: 0, reorder_delay: 0.03, delay: 0, jitter: 0,
      corrupt: 0, max_size: 0, rate: 0, rate_interval: 0.1, bandwidth: 0, queue: 64_000,
      mss: 1460, seed: 1234)
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
      %i[reorder_delay delay jitter rate_interval bandwidth queue].each do |k|
        v = self[k]
        raise ArgumentError, "#{k} must be a non-negative number, got #{v.inspect}" unless v.is_a?(Numeric) && v >= 0
      end
      raise ArgumentError, "burst needs loss" if burst.positive? && loss.zero?
      raise ArgumentError, "mss must be positive" unless mss.positive?
      self
    end

    def with(**changes) = self.class.new(**to_h.merge(changes))
  end

  # Every decision in one direction. +dropped+ is link loss (random or burst)
  # and nothing else: oversized, throttled, overflow and blackholed are each
  # their own count so three mechanisms do not collapse into one number.
  #
  # +overrun+ is the relay dropping on its own floor rather than the link's:
  # the processing queue was full. Distinct from everything above.
  Tally = Struct.new(:forwarded, :dropped, :reordered, :corrupted, :oversized, :throttled,
    :overflow, :blackholed, :overrun, :replayed, :longest_burst, keyword_init: true) do
    def initialize(**kw)
      super(**members.to_h { |m| [m, 0] }.merge(kw))
    end

    def discarded = dropped + oversized + throttled + overflow + blackholed

    def total = forwarded + discarded

    def loss_rate = (forwarded + dropped).zero? ? 0.0 : dropped.fdiv(forwarded + dropped)

    def +(other)
      Tally.new(**members.to_h { |m| [m, m == :longest_burst ? [self[m], other[m]].max : self[m] + other[m]] })
    end
  end

  # Per-direction tallies plus summed totals, so relay.counts.dropped still
  # reads as "the link" while relay.counts.client.dropped says which way.
  class Counts
    attr_reader :client, :server
    attr_accessor :connections, :reset

    def initialize
      @client = Tally.new
      @server = Tally.new
      @connections = 0
      @reset = 0
    end

    def [](direction) = direction == :client ? @client : @server

    def combined = @client + @server

    Tally.members.each { |m| define_method(m) { combined[m] } }
    %i[discarded total loss_rate].each { |m| define_method(m) { combined.public_send(m) } }

    def to_h = { client: @client.to_h, server: @server.to_h, connections: @connections, reset: @reset }

    def ==(other) = other.is_a?(Counts) && to_h == other.to_h

    def to_s
      t = combined
      parts = ["forwarded=#{t.forwarded}", format("dropped=%d (%.2f%%)", t.dropped, t.loss_rate * 100)]
      %i[reordered corrupted oversized throttled overflow blackholed overrun].each do |m|
        parts << "#{m}=#{t[m]}" if t[m].positive?
      end
      parts << "longest_burst=#{t.longest_burst}" if t.longest_burst > 1
      parts << "connections=#{connections}" if connections.positive?
      parts << "reset=#{reset}" if reset.positive?
      parts.join(" ")
    end
  end
end

require_relative "impair/trace"
require_relative "impair/link"
require_relative "impair/tcp"
require_relative "impair/udp"
