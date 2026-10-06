# frozen_string_literal: true

module Impair
  # Every decision in one direction. +dropped+ is link loss (random or burst)
  # and nothing else: oversized, throttled, overflow and blackholed are each
  # their own count so three mechanisms do not collapse into one number.
  #
  # +overrun+ is the relay dropping on its own floor rather than the link's:
  # the processing queue was full. Distinct from everything above.
  Tally = Struct.new(:forwarded, :dropped, :reordered, :corrupted, :oversized, :throttled,
    :overflow, :blackholed, :overrun, :replayed, :rto, :longest_burst, keyword_init: true) do
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
    attr_accessor :connections, :reset, :rebinds, :scenario_events

    def initialize
      @client = Tally.new
      @server = Tally.new
      @connections = 0
      @reset = 0
      @rebinds = 0
      @scenario_events = 0
    end

    def [](direction) = direction == :client ? @client : @server

    def combined = @client + @server

    Tally.members.each { |m| define_method(m) { combined[m] } }
    %i[discarded total loss_rate].each { |m| define_method(m) { combined.public_send(m) } }

    def to_h
      { client: @client.to_h, server: @server.to_h, connections: @connections, reset: @reset,
        rebinds: @rebinds, scenario_events: @scenario_events }
    end

    def ==(other) = other.is_a?(Counts) && to_h == other.to_h

    def to_s
      t = combined
      parts = ["forwarded=#{t.forwarded}", format("dropped=%d (%.2f%%)", t.dropped, t.loss_rate * 100)]
      %i[reordered corrupted oversized throttled overflow blackholed overrun rto].each do |m|
        parts << "#{m}=#{t[m]}" if t[m].positive?
      end
      parts << "longest_burst=#{t.longest_burst}" if t.longest_burst > 1
      parts << "connections=#{connections}" if connections.positive?
      parts << "reset=#{reset}" if reset.positive?
      parts << "rebinds=#{rebinds}" if rebinds.positive?
      parts << "scenario_events=#{scenario_events}" if scenario_events.positive?
      parts.join(" ")
    end
  end
end
