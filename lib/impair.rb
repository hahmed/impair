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
end

require_relative "impair/config"
require_relative "impair/counts"
require_relative "impair/trace"
require_relative "impair/link"
require_relative "impair/relay"
require_relative "impair/tcp"
require_relative "impair/tcp/congestion"
require_relative "impair/udp"
