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

  def test_verify_passes_on_a_quiet_link
    relay = build_relay
    exchange(relay, 10)
    relay.stop

    assert relay.verify!(client: 10, server: 10)
  end
end
