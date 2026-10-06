# frozen_string_literal: true

require "test_helper"

class TestTcp < Minitest::Test
  include RelayHelpers
  include SharedRelayTests

  RELAY = Impair::Tcp

  def setup
    @echo = Echo::Tcp.new
  end

  def teardown
    @echo.close
  end

  def build_relay(**config)
    config[:mss] ||= 1000 if config.key?(:replay)
    Impair::Tcp.new(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1", **config).start
  end

  def probe_closed(port) = TCPSocket.new("127.0.0.1", port).close

  # One "thing" is one connection carrying a small payload, all opened at
  # once -- the TCP analogue of a burst of datagrams. Returns one entry per
  # successful round trip, so the shared tests can count them.
  def exchange(relay, count, wait: 2)
    Array.new(count) { |i| Thread.new { Thread.current.report_on_exception = false; tcp_roundtrip(relay, "hello-#{i}", timeout: wait) } }
      .map { |t| t.value rescue nil }.compact
  end

  # --- integrity --------------------------------------------------------------

  def test_bytes_arrive_intact_across_segment_boundaries
    relay = build_relay
    payload = Random.new(1).bytes(100_000)

    assert_equal payload, tcp_roundtrip(relay, payload)
  ensure
    relay&.stop
  end

  # TCP cannot drop bytes here, so loss must never show up as corruption.
  # congestion: false, because 1-in-3 is a dead link and this test is about
  # bytes, not timers.
  def test_loss_never_damages_the_stream
    relay = build_relay(loss: 3, delay: 0.005, congestion: false)
    payload = Random.new(2).bytes(50_000)

    assert_equal payload, tcp_roundtrip(relay, payload)
    assert_operator relay.counts.dropped, :>, 0
  ensure
    relay&.stop
  end

  # Pins the accept-loop race: a while-local captured by Thread.new let two
  # threads serve one socket and orphan another. Showed up at ~1 in 50 under
  # load, which is exactly the shape of flake people blame on the test.
  def test_a_burst_of_connections_is_served_exactly_once_each
    relay = build_relay
    back = exchange(relay, 200)

    assert_equal 200, back.size
    assert_equal 200, @echo.connections
    assert_equal 400, relay.counts.forwarded
  ensure
    relay&.stop
  end

  def test_concurrent_connections_do_not_cross_streams
    relay = build_relay
    payloads = Array.new(8) { |i| "conn-#{i}-" * 2000 }
    results = payloads.map { |p| Thread.new { tcp_roundtrip(relay, p) } }.map(&:value)

    assert_equal payloads, results
  ensure
    relay&.stop
  end

  # --- loss as a stall --------------------------------------------------------

  # Loss on the TCP arm is a head-of-line stall for one RTT per lost segment.
  # 100 KB is ~70 segments; at 1-in-10 that is ~7 stalls of 50ms each way.
  def test_loss_costs_one_rtt_per_lost_segment
    relay = build_relay(loss: 10, delay: 0.025, seed: 5)
    payload = Random.new(3).bytes(100_000)

    elapsed = timed { tcp_roundtrip(relay, payload) }
    stalls = relay.counts.dropped

    # Stalls in opposite directions overlap in wall time, so the floor is
    # half the sum. Tightens to the full sum once counts are per-direction.
    assert_operator stalls, :>, 3
    assert_operator elapsed, :>, stalls * 0.05 / 2 * 0.8, "stalls were not paid: #{elapsed}s for #{stalls} stalls"
  ensure
    relay&.stop
  end

  # Same bug the UDP side fixed: sleeping in the pump charges the delay once
  # per segment rather than once per link. 100 KB at 25ms one-way should take
  # ~50ms plus transfer, not 70 segments x 25ms = 1.75s.
  def test_delay_is_not_paid_per_segment
    relay = build_relay(delay: 0.025)
    elapsed = timed { tcp_roundtrip(relay, Random.new(4).bytes(100_000)) }

    assert_operator elapsed, :<, 0.3, "#{elapsed}s for 100 KB at 25ms one-way"
  ensure
    relay&.stop
  end

  def test_loss_is_decided_per_segment_not_per_read
    relay = build_relay(loss: 2, delay: 0.0005, mss: 1000)
    tcp_roundtrip(relay, "x" * 20_000) # 20 segments in, 20 out

    assert_in_delta 40, relay.counts.total, 4
    assert_in_delta 0.5, relay.counts.loss_rate, 0.2
  ensure
    relay&.stop
  end

  # Both arms must express the same link the same way. Tcp currently takes
  # rtt separately, so a caller must remember rtt == 2 * delay themselves.
  def test_stall_per_loss_is_two_times_delay
    # Every segment lost, so the HOL stall is the whole cost. Congestion off:
    # with it on this is a link that never delivers and RTOs forever, which is
    # correct and not what this test is about.
    relay = build_relay(loss: 1, delay: 0.025, mss: 1000, congestion: false)
    elapsed = timed { tcp_roundtrip(relay, "x" * 10_000) }

    # 10 segments each way, each stalled one 50ms RTT. The two directions
    # pipeline, so the floor is one direction's worth of stalls.
    assert_operator elapsed, :>, 0.5
    assert_equal 20, relay.counts.dropped
  ensure
    relay&.stop
  end

  # --- congestion -------------------------------------------------------------
  #
  # One lost segment is a fast retransmit: one RTT, the whole connection.
  # Three or more in a row and there are no duplicate acks to trigger it, so
  # the sender waits for the retransmission timer (RFC 6298; Linux floors it
  # at 200ms) and then collapses cwnd to one segment and slow-starts back.
  # Without this the TCP arm shrugs off exactly the bursts that hurt QUIC.

  def test_an_isolated_loss_costs_one_rtt
    relay = build_relay(loss: 0, delay: 0.01, replay: script(client: [false, true, false, false]))
    elapsed = timed { tcp_roundtrip(relay, "x" * 4000, mss: 1000) }

    # 20ms RTT for the stall + 20ms transit. Nowhere near an RTO.
    assert_operator elapsed, :<, 0.15
    assert_equal 0, relay.counts.rto
  ensure
    relay&.stop
  end

  # RFC 5681 3.2: an isolated loss halves the window as well as stalling.
  # The 20 segments after it are then paced by a 5-segment window growing one
  # per RTT, where before they went out at link speed. Same bytes, same loss
  # position; only the sender's reaction differs.
  def test_an_isolated_loss_halves_the_window
    one_then_clean = [false, true] + [false] * 20
    with_cc = build_relay(loss: 0, delay: 0.02, replay: script(client: one_then_clean))
    a = timed { tcp_roundtrip(with_cc, "x" * 22_000, mss: 1000) }
    with_cc.stop

    without = build_relay(loss: 0, delay: 0.02, congestion: false, replay: script(client: one_then_clean))
    b = timed { tcp_roundtrip(without, "x" * 22_000, mss: 1000) }
    without.stop

    assert_operator a - b, :>, 0.05, "halving added only #{((a - b) * 1000).round}ms"
    assert_equal 0, with_cc.counts.rto, "an isolated loss is not an RTO"
  end

  # Scattered loss keeps the window cut. Every third segment lost means the
  # window is halved before it ever grows back, so the connection lives in
  # congestion avoidance and each segment pays for it.
  def test_scattered_loss_keeps_the_window_small
    pattern = Array.new(30) { |i| i % 3 == 1 }
    with_cc = build_relay(loss: 0, delay: 0.02, replay: script(client: pattern))
    a = timed { tcp_roundtrip(with_cc, "x" * 30_000, mss: 1000) }
    with_cc.stop

    without = build_relay(loss: 0, delay: 0.02, congestion: false, replay: script(client: pattern))
    b = timed { tcp_roundtrip(without, "x" * 30_000, mss: 1000) }
    without.stop

    assert_operator a - b, :>, 0.1, "congestion avoidance added only #{((a - b) * 1000).round}ms"
  end

  def test_a_burst_triggers_an_rto
    relay = build_relay(loss: 0, delay: 0.01, replay: script(client: [true, true, true, false]))
    elapsed = timed { tcp_roundtrip(relay, "x" * 4000, mss: 1000) }

    assert_equal 1, relay.counts.client.rto
    assert_operator elapsed, :>=, 0.2, "RTO floor not paid: #{elapsed}"
  ensure
    relay&.stop
  end

  def test_cwnd_collapse_slows_the_segments_after_an_rto
    # Same bytes, same loss positions; the only difference is what comes
    # after. With collapse the next segments are paced by a 1-MSS window
    # growing by one per RTT, so 8 segments after the burst take ~3 RTTs more
    # than they would unimpaired.
    burst_then_clean = [true, true, true] + [false] * 8
    with_cc = build_relay(loss: 0, delay: 0.02, replay: script(client: burst_then_clean))
    a = timed { tcp_roundtrip(with_cc, "x" * 11_000, mss: 1000) }
    with_cc.stop

    without = build_relay(loss: 0, delay: 0.02, congestion: false, replay: script(client: burst_then_clean))
    b = timed { tcp_roundtrip(without, "x" * 11_000, mss: 1000) }
    without.stop

    assert_operator a - b, :>, 0.08, "collapse added only #{((a - b) * 1000).round}ms"
  end

  # Ten lost in a row is one window, not ten probes: one RTO, not ten.
  def test_a_long_burst_pays_one_rto_not_one_per_segment
    relay = build_relay(loss: 0, delay: 0.01, replay: script(client: [true] * 10 + [false]))
    elapsed = timed { tcp_roundtrip(relay, "x" * 11_000, mss: 1000) }

    assert_equal 1, relay.counts.client.rto
    assert_operator elapsed, :<, 0.6, "#{elapsed}s for one burst"
  ensure
    relay&.stop
  end

  # Two separate bursts are two timer events.
  def test_separate_bursts_each_pay
    pattern = [true] * 3 + [false] * 3 + [true] * 3 + [false]
    relay = build_relay(loss: 0, delay: 0.01, replay: script(client: pattern))
    tcp_roundtrip(relay, "x" * (pattern.size * 1000), mss: 1000)

    assert_equal 2, relay.counts.client.rto
  ensure
    relay&.stop
  end

  def test_congestion_can_be_switched_off
    relay = build_relay(loss: 0, delay: 0.01, congestion: false, replay: script(client: [true] * 5))
    elapsed = timed { tcp_roundtrip(relay, "x" * 5000, mss: 1000) }

    assert_equal 0, relay.counts.rto
    assert_operator elapsed, :<, 0.2
  ensure
    relay&.stop
  end

  def script(client: [], server: [])
    Impair::Trace.new.tap { |t| t.losses = {client: client, server: server} }
  end

  # --- Nagle ------------------------------------------------------------------

  # The relay writes one segment at a time. Without TCP_NODELAY the trailing
  # sub-MSS write waits for the ACK of the full segment before it, which is
  # the delayed-ACK timer: 40ms on Linux, more on macOS, charged to the
  # protocol under test. Write-write-read is the pattern that triggers it.
  def test_sub_mss_tail_is_not_held_by_nagle
    relay = build_relay
    tcp_roundtrip(relay, "warm") # connection setup out of the timing
    elapsed = timed { tcp_roundtrip(relay, "x" * 3000) } # 1460 + 1460 + 80

    assert_operator elapsed, :<, 0.03, "tail segment held for #{(elapsed * 1000).round}ms"
  ensure
    relay&.stop
  end

  # --- faults -----------------------------------------------------------------

  def test_reset_kills_live_connections
    relay = build_relay
    client = TCPSocket.new("127.0.0.1", relay.port)
    client.write("hello")
    client.read(5)

    relay.reset

    assert_raises(Errno::ECONNRESET, EOFError, Errno::EPIPE) do
      client.write("still there?")
      client.read(1) or raise EOFError
    end
    assert_equal 1, relay.counts.reset
  ensure
    client&.close
    relay&.stop
  end

  def test_new_connections_work_after_reset
    relay = build_relay
    tcp_roundtrip(relay, "before")
    relay.reset

    assert_equal "after", tcp_roundtrip(relay, "after")
  ensure
    relay&.stop
  end

  def test_connections_are_counted
    relay = build_relay
    exchange(relay, 3)

    assert_equal 3, relay.counts.connections
  ensure
    relay&.stop
  end
end
