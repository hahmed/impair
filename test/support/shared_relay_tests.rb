# frozen_string_literal: true

# Behaviour every relay owes the caller regardless of transport. Including
# classes provide:
#
#   build_relay(**config)   -> started relay in front of an echo server
#   exchange(relay, count)  -> send count things through it, return what came back
#
# Assertions are on what the client observes -- bytes back, time taken --
# rather than on relay internals, so the engine can be refactored underneath.
module SharedRelayTests
  def test_binds_an_ephemeral_port
    relay = build_relay
    assert_operator relay.port, :>, 0
  ensure
    relay&.stop
  end

  def test_class_start_builds_and_starts
    relay = self.class::RELAY.start(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1")
    assert_operator relay.port, :>, 0
    assert_equal 5, exchange(relay, 5).size
  ensure
    relay&.stop
  end

  def test_block_form_stops_and_returns_counts
    port = nil
    counts = self.class::RELAY.start(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1") do |relay|
      port = relay.port
      exchange(relay, 5)
    end

    assert_kind_of Impair::Counts, counts
    assert_equal 10, counts.forwarded
    assert_raises(Errno::ECONNREFUSED, Errno::ECONNRESET, Timeout::Error, IOError) { probe_closed(port) }
  end

  def test_block_form_stops_on_raise
    relay_ref = nil
    assert_raises(RuntimeError) do
      self.class::RELAY.start(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1") do |relay|
        relay_ref = relay
        raise "benchmark blew up"
      end
    end
    assert_same relay_ref.counts, relay_ref.stop # already stopped: idempotent return
  end

  def test_a_clean_relay_loses_nothing
    relay = build_relay
    sent = 50
    back = exchange(relay, sent)

    assert_equal sent, back.size
    assert_equal 0, relay.counts.dropped
  ensure
    relay&.stop
  end

  def test_stop_returns_counts_and_is_idempotent
    relay = build_relay
    exchange(relay, 5)

    counts = relay.stop
    assert_kind_of Impair::Counts, counts
    assert_same counts, relay.stop
  end

  def test_delay_adds_about_one_rtt_not_one_per_packet
    relay = build_relay(delay: 0.05)
    elapsed = timed { exchange(relay, 20) }

    # 50ms each way is 100ms. Paid serially it would be 2s.
    assert_operator elapsed, :>, 0.09
    assert_operator elapsed, :<, 0.5
  ensure
    relay&.stop
  end

  def test_update_changes_impairment_mid_run
    relay = build_relay(loss: 2)
    exchange(relay, 100)
    before = relay.counts.dropped
    assert_operator before, :>, 0

    relay.update(loss: 0)
    exchange(relay, 100)

    assert_equal before, relay.counts.dropped
  ensure
    relay&.stop
  end

  def test_update_returns_self_for_chaining
    relay = build_relay
    assert_same relay, relay.update(delay: 0.01)
  ensure
    relay&.stop
  end

  # The recovery experiment: cut the link, restore it, watch the protocol
  # climb back. Everything in the hole is lost; everything after gets through.
  def test_blackhole_swallows_everything_then_heals
    relay = build_relay
    relay.blackhole(0.3)

    during = exchange(relay, 20, wait: 0.1)
    assert_empty during
    assert_equal 20, relay.counts.blackholed

    sleep 0.3
    after = exchange(relay, 20)
    assert_equal 20, after.size
  ensure
    relay&.stop
  end

  def test_blackhole_is_not_counted_as_link_loss
    relay = build_relay(loss: 0)
    relay.blackhole(0.2)
    exchange(relay, 10, wait: 0.05)

    assert_equal 0, relay.counts.dropped
    assert_in_delta 0.0, relay.counts.loss_rate, 1e-9
  ensure
    relay&.stop
  end

  def test_counts_are_split_by_direction
    relay = build_relay
    exchange(relay, 10)

    assert_equal 10, relay.counts.client.forwarded
    assert_equal 10, relay.counts.server.forwarded
    assert_equal 20, relay.counts.forwarded
  ensure
    relay&.stop
  end

  def test_shortfall_is_direction_aware
    relay = build_relay
    exchange(relay, 10)
    relay.stop

    result = relay.shortfall(client: 10, server: 10)
    assert_equal 0, result[:missing]
    assert_equal 0, relay.shortfall(client: 10)[:missing]
  end

  # --- trace / replay ---------------------------------------------------

  def test_trace_records_one_event_per_packet
    relay = build_relay(loss: 3, trace: true)
    exchange(relay, 30)
    relay.stop

    assert_equal relay.counts.total, relay.trace.size
    assert_equal relay.counts.dropped, relay.trace.count { |e| e.action == :dropped }
    event = relay.trace.first
    assert_includes %i[client server], event.direction
    assert_kind_of Float, event.t
    assert_operator event.bytes, :>, 0
  ensure
    relay&.stop
  end

  def test_trace_is_off_by_default
    relay = build_relay
    exchange(relay, 5)
    assert_nil relay.trace
  ensure
    relay&.stop
  end

  # The fairness guarantee. Two runs with the same seed drift once return
  # traffic interleaves differently; two runs on the same replay cannot.
  def test_replay_reproduces_the_exact_loss_pattern
    first = build_relay(loss: 3, trace: true)
    exchange(first, 40)
    first.stop

    second = build_relay(loss: 0, replay: first.trace)
    exchange(second, 40)
    second.stop

    assert_operator first.counts.dropped, :>, 0
    assert_equal first.counts.client.dropped, second.counts.client.dropped
    assert_equal first.trace.losses[:client].size, second.counts.client.replayed
    assert_equal first.trace.losses[:server].size, second.counts.server.replayed
  end

  def test_replay_falls_back_to_config_when_exhausted
    script = Impair::Trace.new
    script.losses = { client: [true, false], server: [] }

    relay = build_relay(loss: 0, replay: script)
    exchange(relay, 10)

    assert_equal 1, relay.counts.client.dropped
    assert_equal 2, relay.counts.client.replayed
    assert_equal 0, relay.counts.server.replayed
  ensure
    relay&.stop
  end

  def test_verify_passes_on_a_quiet_link
    relay = build_relay
    exchange(relay, 10)
    relay.stop

    assert relay.verify!(client: 10, server: 10)
  end
end
