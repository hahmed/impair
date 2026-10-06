# frozen_string_literal: true

module Impair
  # One scenario playing against one relay: a thread that sleeps until the
  # next action is due, fires it, and repeats. The schedule belongs to the
  # Scenario; the clock belongs here, so two playbacks of one scenario do not
  # share a start time.
  class Playback
    attr_reader :started

    def initialize(scenario, relay)
      @relay = relay
      @started = now
      @pending = scenario.actions.map { |action| [action.at, action] }
      @thread = Thread.new { play }
    end

    def elapsed = now - @started

    def running? = @thread.alive?

    def stop
      @thread.kill
      @thread.join(1)
      self
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Earliest due first. One-shots leave the list when fired; tickers go
    # back in at their next due time.
    def play
      while (due, action = @pending.min_by(&:first))
        sleep [due - elapsed, 0].max
        fire(action, due)
        @pending.delete([due, action])
        @pending << [due + action.every, action] if action.every
      end
    rescue StandardError => e
      warn "Impair::Playback: #{e.class}: #{e.message}" if $VERBOSE
    end

    def fire(action, t)
      action.block.arity == 1 ? action.block.call(@relay) : action.block.call(@relay, t)
      @relay.counts.scenario_events += 1
    end
  end
end
