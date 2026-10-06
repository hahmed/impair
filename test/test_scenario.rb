# frozen_string_literal: true

require "test_helper"

# A schedule of changes to a running relay. The relay must change when the
# schedule says, every arm must see the same schedule, and the shapes must
# be what they claim.
class TestScenario < Minitest::Test
  include RelayHelpers

  def setup
    @echo = Echo::Udp.new
  end

  def teardown
    @echo.close
  end

  def build_relay(**config)
    Impair::Udp.new(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1", **config).start
  end

  # --- schedule ---------------------------------------------------------------

  def test_at_fires_once_at_the_named_time
    fired = []
    scenario = Impair::Scenario.new do
      at(0.05) { |relay| fired << [:a, relay.config.loss] }
      at(0.15) { |relay| fired << [:b, relay.config.loss] }
    end
    relay = build_relay(loss: 0)
    relay.run(scenario)
    sleep 0.25

    assert_equal [[:a, 0], [:b, 0]], fired
    assert_equal 2, relay.counts.scenario_events
  ensure
    relay&.stop
  end

  def test_at_changes_the_link_on_schedule
    scenario = Impair::Scenario.new { at(0.1) { |relay| relay.update(loss: 1) } }
    relay = build_relay(loss: 0)
    relay.run(scenario)

    before = udp_exchange(relay, 20, wait: 0.05)
    sleep 0.1
    after = udp_exchange(relay, 20, wait: 0.2)

    assert_equal 20, before.size, "lost packets before the schedule said so"
    assert_equal 0, after.size, "schedule did not apply: loss: 1 drops everything"
  ensure
    relay&.stop
  end

  def test_every_ticks_until_stop
    ticks = []
    scenario = Impair::Scenario.new { every(0.05) { |_relay, t| ticks << t } }
    relay = build_relay
    relay.run(scenario)
    sleep 0.28
    relay.stop
    seen = ticks.size
    sleep 0.1

    assert_includes 5..6, seen, "expected ~5 ticks in 280ms at 50ms, got #{seen}"
    assert_equal seen, ticks.size, "ticks continued after stop"
    assert_in_delta 0.0, ticks.first, 0.02
    assert_in_delta 0.05, ticks[1] - ticks[0], 0.02
  end

  def test_blocks_may_take_the_relay_alone
    got = nil
    scenario = Impair::Scenario.new { at(0.01) { |relay| got = relay } }
    relay = build_relay
    relay.run(scenario)
    sleep 0.05

    assert_same relay, got
  ensure
    relay&.stop
  end

  # The same object drives two relays. That is the point: one schedule, two
  # arms, no drift.
  def test_one_scenario_drives_two_relays
    scenario = Impair::Scenario.new { at(0.05) { |relay| relay.update(loss: 1) } }
    a = build_relay(loss: 0)
    b = build_relay(loss: 0)
    a.run(scenario)
    b.run(scenario)
    sleep 0.15

    assert_equal 1, a.config.loss
    assert_equal 1, b.config.loss
  ensure
    a&.stop
    b&.stop
  end

  def test_start_takes_a_scenario
    scenario = Impair::Scenario.new { at(0.02) { |relay| relay.update(loss: 1) } }
    counts = Impair::Udp.start(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1",
      loss: 0, scenario: scenario) do |relay|
      sleep 0.08
      assert_equal 1, relay.config.loss
    end

    assert_equal 1, counts.scenario_events
  end

  def test_stop_ends_the_schedule
    fired = 0
    scenario = Impair::Scenario.new { at(0.2) { fired += 1 } }
    relay = build_relay
    relay.run(scenario)
    relay.stop
    sleep 0.3

    assert_equal 0, fired
  end

  def test_at_and_every_validate
    assert_raises(ArgumentError) { Impair::Scenario.new { at(-1) {} } }
    assert_raises(ArgumentError) { Impair::Scenario.new { every(0) {} } }
  end

  # --- shapes -----------------------------------------------------------------
  #
  # Zero-mean, ±amplitude, period-periodic. Checked at the points where each
  # shape is unambiguous.

  def test_wave
    s = Impair::Scenario.new
    assert_in_delta 0.0, s.wave(0, amplitude: 1, period: 4), 1e-9
    assert_in_delta 1.0, s.wave(1, amplitude: 1, period: 4), 1e-9
    assert_in_delta 0.0, s.wave(2, amplitude: 1, period: 4), 1e-9
    assert_in_delta(-1.0, s.wave(3, amplitude: 1, period: 4), 1e-9)
    assert_in_delta 0.0, s.wave(4, amplitude: 1, period: 4), 1e-9
  end

  def test_sawtooth
    s = Impair::Scenario.new
    assert_in_delta(-1.0, s.sawtooth(0, amplitude: 1, period: 4), 1e-9)
    assert_in_delta 0.0, s.sawtooth(2, amplitude: 1, period: 4), 1e-9
    assert_in_delta 0.5, s.sawtooth(3, amplitude: 1, period: 4), 1e-9
    assert_in_delta(-1.0, s.sawtooth(4, amplitude: 1, period: 4), 1e-9)
  end

  def test_square
    s = Impair::Scenario.new
    assert_equal 1, s.square(0, amplitude: 1, period: 4)
    assert_equal 1, s.square(1.9, amplitude: 1, period: 4)
    assert_equal(-1, s.square(2, amplitude: 1, period: 4))
    assert_equal 1, s.square(4, amplitude: 1, period: 4)
  end

  def test_triangle
    s = Impair::Scenario.new
    assert_in_delta(-1.0, s.triangle(0, amplitude: 1, period: 4), 1e-9)
    assert_in_delta 0.0, s.triangle(1, amplitude: 1, period: 4), 1e-9
    assert_in_delta 1.0, s.triangle(2, amplitude: 1, period: 4), 1e-9
    assert_in_delta 0.0, s.triangle(3, amplitude: 1, period: 4), 1e-9
    assert_in_delta(-1.0, s.triangle(4, amplitude: 1, period: 4), 1e-9)
  end

  def test_shapes_scale_by_amplitude
    s = Impair::Scenario.new
    assert_in_delta 0.015, s.wave(1.5, amplitude: 0.015, period: 6), 1e-9
  end

  # A ticker modulating delay is the speedbump case: the link's RTT swings
  # over time and the relay's config follows it.
  def test_every_can_modulate_delay_with_a_wave
    scenario = Impair::Scenario.new do
      every(0.02) { |relay, t| relay.update(delay: 0.05 + wave(t, amplitude: 0.05, period: 0.2)) }
    end
    relay = build_relay(delay: 0.05)
    relay.run(scenario)
    seen = []
    12.times { seen << relay.config.delay; sleep 0.02 }
    relay.stop

    assert_operator seen.max, :>, 0.08, "delay never rose: #{seen.map { |d| d.round(3) }}"
    assert_operator seen.min, :<, 0.02, "delay never fell: #{seen.map { |d| d.round(3) }}"
  end
end
