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

  # loss and reorder are 1-in-N, the way MsQuic's emulated-performance runs
  # express them. Zero disables. Delays are seconds.
  #
  # corrupt, max_size and rate follow smoltcp's FaultInjector
  # (src/phy/fault_injector.rs, 0BSD), the closest prior art for this: a device
  # that "alters packets traversing through it to simulate adverse network
  # conditions". Its lesson is that loss alone is a thin experiment. A
  # corrupted packet fails differently from a missing one, an oversized packet
  # exposes a path MTU assumption, and a rate limit produces queueing.
  Config = Struct.new(
    :loss, :reorder, :reorder_delay, :delay, :corrupt, :max_size,
    :rate, :rate_interval, :seed, keyword_init: true
  ) do
    def initialize(loss: 0, reorder: 0, reorder_delay: 0.03, delay: 0, corrupt: 0,
      max_size: 0, rate: 0, rate_interval: 0.1, seed: 1234)
      super
    end

    def impairing?
      [loss, reorder, corrupt, max_size, rate].any?(&:positive?) || delay.positive?
    end
  end

  # overrun is the relay dropping on its own floor rather than the link's: the
  # processing queue was full, so a received packet was discarded before any
  # impairment decision was made. Distinct from dropped, which is the link.
  Counts = Struct.new(:forwarded, :dropped, :reordered, :corrupted, :oversized, :throttled,
    :overrun, keyword_init: true) do
    def initialize(forwarded: 0, dropped: 0, reordered: 0, corrupted: 0, oversized: 0,
      throttled: 0, overrun: 0)
      super
    end

    def total = forwarded + dropped

    # What the caller advertised versus what actually happened. An experiment
    # should check this rather than assume.
    def loss_rate = total.zero? ? 0.0 : dropped.fdiv(total)

    def to_s
      parts = ["forwarded=#{forwarded}", format("dropped=%d (%.2f%%)", dropped, loss_rate * 100)]
      parts << "reordered=#{reordered}" if reordered.positive?
      parts << "corrupted=#{corrupted}" if corrupted.positive?
      parts << "oversized=#{oversized}" if oversized.positive?
      parts << "throttled=#{throttled}" if throttled.positive?
      parts << "overrun=#{overrun}" if overrun.positive?
      parts.join(" ")
    end
  end

end

require_relative "impair/tcp"
require_relative "impair/udp"
