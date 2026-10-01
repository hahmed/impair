# frozen_string_literal: true

module Impair
  # What happened to every packet, in order, and the loss decisions on their
  # own so another run can replay them.
  #
  # A seed makes a run repeatable only as far as the scheduler cooperates:
  # both directions draw from their own RNG, but how many packets the server
  # sends back depends on what the client got through, so two protocols on
  # the same seed still see different draws. A replay removes the RNG from
  # the loss decision entirely. Feed one trace to the HTTP/1 arm and the
  # HTTP/3 arm and the loss pattern is identical by construction; whatever
  # difference remains is the protocol.
  class Trace
    include Enumerable

    Event = Struct.new(:t, :direction, :seq, :action, :bytes, :wait, keyword_init: true)

    # Per direction, true for each lost? decision that came out lost.
    attr_accessor :losses

    def initialize
      @events = []
      @losses = { client: [], server: [] }
      @seq = { client: 0, server: 0 }
      @mutex = Mutex.new
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def record(direction, action, bytes, wait = 0.0)
      @mutex.synchronize do
        @events << Event.new(
          t: Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started,
          direction: direction, seq: @seq[direction] += 1,
          action: action, bytes: bytes, wait: wait
        )
      end
    end

    def decide(direction, lost)
      @mutex.synchronize { @losses[direction] << lost }
    end

    def each(&) = @events.each(&)
    def size = @events.size
    def empty? = @events.empty?

    def to_csv
      lines = ["t,direction,seq,action,bytes,wait"]
      each { |e| lines << format("%.6f,%s,%d,%s,%d,%.6f", e.t, e.direction, e.seq, e.action, e.bytes, e.wait) }
      lines.join("\n") << "\n"
    end
  end
end
