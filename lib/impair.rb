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

  # Which relay carries a protocol. QUIC is UDP and everything else here is
  # TCP, so the choice is mechanical, but every benchmark comparing an HTTP/3
  # arm against HTTP/2 and HTTP/1.1 arms was writing its own conditional:
  #
  #   relay_class = (name == "quicsilver") ? Impair::Udp : Impair::Tcp
  #
  # Three copies of that is three places to get it wrong, and the comparison
  # only means anything if both arms are on the same link.
  KINDS = {
    udp: :Udp, quic: :Udp, "HTTP/3" => :Udp,
    tcp: :Tcp, "HTTP/2" => :Tcp, "HTTP/1.1" => :Tcp, "HTTP/1.0" => :Tcp
  }.freeze

  # The relay class for a transport or an ALPN-ish protocol name.
  #
  #   Impair.relay_class(:udp)       # => Impair::Udp
  #   Impair.relay_class("HTTP/2")   # => Impair::Tcp
  def self.relay_class(kind)
    name = KINDS[kind] || KINDS[kind.to_s] || (kind.respond_to?(:to_sym) ? KINDS[kind.to_sym] : nil)
    raise ArgumentError, "unknown relay kind #{kind.inspect}; expected one of #{KINDS.keys.inspect}" unless name

    const_get(name)
  end

  # Start the relay for +kind+. Takes and returns exactly what
  # Relay::ClassMethods.start does, including the block form, so the only
  # thing this adds is not having to name the class.
  #
  #   Impair.relay("HTTP/3", target_host: host, target_port: port, loss: 100) do |relay|
  #     measure(relay.port)
  #   end
  def self.relay(kind, *args, **options, &block)
    relay_class(kind).start(*args, **options, &block)
  end
end

require_relative "impair/config"
require_relative "impair/counts"
require_relative "impair/trace"
require_relative "impair/script"
require_relative "impair/link"
require_relative "impair/relay"
require_relative "impair/scenario"
require_relative "impair/playback"
require_relative "impair/tcp"
require_relative "impair/tcp/congestion"
require_relative "impair/udp"
