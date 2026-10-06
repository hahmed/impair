# frozen_string_literal: true

module Impair
  # Conditions that change while the benchmark runs, on a schedule.
  #
  # A seed makes a run repeatable; a scenario makes a *changing* run
  # repeatable. "Loss rises to 1-in-20 at t=2s, the link goes dark for half
  # a second at t=5s, and the client's NAT rebinds at t=8s" is one object,
  # and the same object drives the HTTP/3 arm and the TCP arm.
  #
  #   scenario = Impair::Scenario.new do
  #     at(2.0) { |relay| relay.update(loss: 20) }
  #     at(5.0) { |relay| relay.blackhole(0.5) }
  #     at(8.0) { |relay| relay.rebind if relay.respond_to?(:rebind) }
  #     every(0.1) { |relay, t| relay.update(delay: 0.02 + wave(t, amplitude: 0.015, period: 6)) }
  #   end
  #
  #   relay = Impair::Udp.start(..., scenario: scenario)
  #   # ... or ...
  #   relay.run(scenario)
  #
  # +at+ fires once. +every+ fires on a tick from t=0 until the relay stops,
  # and is how a waveform is expressed: +wave+, +sawtooth+, +square+ and
  # +triangle+ (speedbump's four) return a value for a time, and the block
  # decides which Config key it modulates. Blocks receive the relay and the
  # elapsed seconds; +at+ blocks may omit the time.
  #
  # Time is since the scenario started, not since the relay did, so a
  # scenario can be started after warm-up. +counts.scenario_events+ is how
  # many actions fired, so an experiment can assert the schedule ran.
  class Scenario
    Action = Struct.new(:at, :every, :block)

    attr_reader :actions

    def initialize(&definition)
      @actions = []
      instance_eval(&definition) if definition
    end

    def at(seconds, &block)
      raise ArgumentError, "at needs a non-negative time" unless seconds.is_a?(Numeric) && seconds >= 0

      @actions << Action.new(seconds, nil, block)
      self
    end

    def every(seconds, &block)
      raise ArgumentError, "every needs a positive interval" unless seconds.is_a?(Numeric) && seconds.positive?

      @actions << Action.new(0.0, seconds, block)
      self
    end

    # --- shapes ---------------------------------------------------------------
    #
    # Each is zero-mean over a period and swings ±amplitude, so adding one
    # to a base value oscillates around that base. Compose by adding.

    def wave(t, amplitude:, period:)
      Math.sin(t.fdiv(period) * 2 * Math::PI) * amplitude
    end

    def sawtooth(t, amplitude:, period:)
      phase = (t % period).fdiv(period)
      (phase * 2 - 1) * amplitude
    end

    def square(t, amplitude:, period:)
      ((t % period) < period.fdiv(2) ? 1 : -1) * amplitude
    end

    def triangle(t, amplitude:, period:)
      phase = (t % period).fdiv(period)
      (1 - (phase * 4 - 2).abs) * amplitude
    end

    # --- running --------------------------------------------------------------

    # Drives +relay+ until +stop+ or the relay stops. Returns the Run.
    def run(relay)
      Run.new(self, relay).start
    end

    # One execution of a scenario against one relay: a thread walking the
    # schedule. Separate from the Scenario so the same schedule can run
    # against two relays.
    class Run
      def initialize(scenario, relay)
        @scenario = scenario
        @relay = relay
        @running = false
      end

      def start
        @running = true
        @started = now
        @thread = Thread.new { walk }
        self
      end

      def stop
        @running = false
        @thread&.join(1)
        self
      end

      def elapsed = now - @started

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # One-shots in time order, with tickers interleaved by their next due
      # time. Sleeps until the earliest due action rather than polling.
      def walk
        pending = @scenario.actions.map { |a| [a.at, a] }
        until pending.empty? || !@running
          pending.sort_by!(&:first)
          due, action = pending.first
          wait = due - elapsed
          sleep(wait) if wait.positive?
          break unless @running

          fire(action, due)
          if action.every
            pending[0] = [due + action.every, action]
          else
            pending.shift
          end
        end
      rescue StandardError => e
        warn "Impair::Scenario: #{e.class}: #{e.message}" if $VERBOSE
      end

      def fire(action, t)
        action.block.arity == 1 ? action.block.call(@relay) : action.block.call(@relay, t)
        @relay.counts.scenario_events += 1
      end
    end
  end
end
