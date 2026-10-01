# frozen_string_literal: true

require "test_helper"

class TestTcp < Minitest::Test
  include RelayHelpers
  include SharedRelayTests

  def setup
    @echo = Echo::Tcp.new
  end

  def teardown
    @echo.close
  end

  def build_relay(**config)
    Impair::Tcp.new(target_host: "127.0.0.1", target_port: @echo.port, host: "127.0.0.1", **config).start
  end

  # One "thing" is one connection carrying a small payload, all opened at
  # once -- the TCP analogue of a burst of datagrams. Returns one entry per
  # successful round trip, so the shared tests can count them.
  def exchange(relay, count, wait: 2)
    Array.new(count) { |i| Thread.new { tcp_roundtrip(relay, "hello-#{i}", timeout: wait) } }
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
  def test_loss_never_damages_the_stream
    relay = build_relay(loss: 3, rtt: 0.01)
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
    relay = build_relay(loss: 10, rtt: 0.05, seed: 5)
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
    skip "BUG: Tcp#pump sleeps inline per chunk"
    relay = build_relay(delay: 0.025)
    elapsed = timed { tcp_roundtrip(relay, Random.new(4).bytes(100_000)) }

    assert_operator elapsed, :<, 0.3, "#{elapsed}s for 100 KB at 25ms one-way"
  ensure
    relay&.stop
  end

  def test_loss_is_decided_per_segment_not_per_read
    relay = build_relay(loss: 2, rtt: 0.001, mss: 1000)
    tcp_roundtrip(relay, "x" * 20_000) # 20 segments in, 20 out

    assert_in_delta 40, relay.counts.forwarded, 4
  ensure
    relay&.stop
  end

  # Both arms must express the same link the same way. Tcp currently takes
  # rtt separately, so a caller must remember rtt == 2 * delay themselves.
  def test_stall_per_loss_is_two_times_delay
    skip "TODO: derive stall from Config#delay; drop rtt kwarg"
    relay = build_relay(loss: 1, delay: 0.025, mss: 1000) # every segment stalls
    elapsed = timed { tcp_roundtrip(relay, "x" * 10_000) }

    # 10 segments each way, each stalled 50ms, plus 25ms transit each way.
    assert_operator elapsed, :>, 1.0
  ensure
    relay&.stop
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
    skip "TODO: Tcp#reset"
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
    skip "TODO: Tcp#reset"
    relay = build_relay
    tcp_roundtrip(relay, "before")
    relay.reset

    assert_equal "after", tcp_roundtrip(relay, "after")
  ensure
    relay&.stop
  end

  def test_connections_are_counted
    skip "TODO: Counts#connections"
    relay = build_relay
    exchange(relay, 3)

    assert_equal 3, relay.counts.connections
  ensure
    relay&.stop
  end
end
