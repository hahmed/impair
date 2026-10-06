# frozen_string_literal: true

require "test_helper"

class TestUdp < Minitest::Test
  include RelayHelpers
  include SharedRelayTests

  RELAY = Impair::Udp

  def setup
    @echo = Echo::Udp.new
  end

  def teardown
    @echo.close
  end

  def build_relay(target_port: @echo.port, **config)
    Impair::Udp.new(target_host: "127.0.0.1", target_port: target_port, host: "127.0.0.1", **config).start
  end

  def exchange(relay, count, **options) = udp_exchange(relay, count, **options)

  # A closed UDP port has nothing to refuse; prove it by getting nothing back.
  def probe_closed(port)
    c = UDPSocket.new
    c.send("x", 0, "127.0.0.1", port)
    raise Timeout::Error unless IO.select([c], nil, nil, 0.2)

    c.recvfrom(64)
  ensure
    c&.close
  end

  # --- flows ----------------------------------------------------------------
  #
  # A browser opens six TCP connections and one QUIC connection. For the
  # six-against-one comparison the relay has to carry six clients, and the
  # server has to see six peers, not one shared source port.

  def test_each_client_gets_its_own_replies
    relay = build_relay
    clients = Array.new(3) { UDPSocket.new.tap { |c| c.connect("127.0.0.1", relay.port) } }

    clients.each_with_index { |c, i| 5.times { |n| c.send("client#{i}-#{n}", 0) } }
    got = clients.map do |c|
      Array.new(5) do
        raise Timeout::Error, "reply never came" unless IO.select([c], nil, nil, 1)

        c.recvfrom(64)[0]
      end.sort
    end

    clients.each_index do |i|
      assert_equal Array.new(5) { |n| "client#{i}-#{n}" }.sort, got[i], "client #{i} got someone else's replies"
    end
  ensure
    clients&.each(&:close)
    relay&.stop
  end

  def test_the_server_sees_one_peer_per_client
    relay = build_relay
    clients = Array.new(6) { UDPSocket.new.tap { |c| c.connect("127.0.0.1", relay.port) } }
    clients.each { |c| c.send("x", 0) }
    clients.each { |c| IO.select([c], nil, nil, 1) && c.recvfrom(64) }

    assert_equal 6, @echo.peers.size, "server saw #{@echo.peers.size} peers for 6 clients"
    assert_equal 6, relay.counts.connections
  ensure
    clients&.each(&:close)
    relay&.stop
  end

  # All flows share the one link, so the loss is the link's and each flow
  # sees the advertised rate rather than a share of it.
  def test_flows_share_the_link
    relay = build_relay(loss: 10, seed: 7)
    clients = Array.new(4) { UDPSocket.new.tap { |c| c.connect("127.0.0.1", relay.port) } }
    clients.each { |c| 250.times { c.send("x" * 100, 0) } }
    sleep 0.3
    counts = relay.stop

    assert_in_delta 0.10, counts.client.dropped.fdiv(counts.client.forwarded + counts.client.dropped), 0.03
  ensure
    clients&.each(&:close)
  end

  # --- loss -----------------------------------------------------------------

  # The assertion the benchmarks depend on: the advertised impairment has to
  # actually happen. A relay that silently forwards everything reports "loss
  # changed nothing", which is indistinguishable from a real finding.
  def test_loss_drops_at_about_the_advertised_rate
    relay = build_relay(loss: 4)
    exchange(relay, 500)

    assert_operator relay.counts.dropped, :>, 0
    assert_in_delta 0.25, relay.counts.loss_rate, 0.05
  ensure
    relay&.stop
  end

  def test_the_seed_makes_a_run_reproducible_in_both_directions
    first = build_relay(loss: 4, seed: 99)
    exchange(first, 200)
    first.stop

    second = build_relay(loss: 4, seed: 99)
    exchange(second, 200)
    second.stop

    assert_operator first.counts.dropped, :>, 0
    assert_equal first.counts.to_h, second.counts.to_h
  end

  # Independent loss hits every stream a little. Bursty loss hits a few
  # streams hard, which is the case that separates HTTP/3 from HTTP/1: one
  # burst stalls every stream on a TCP connection, and only the affected
  # streams on QUIC. The overall rate must not change when burst is on.
  def test_burst_loss_clusters_drops_without_changing_the_rate
    relay = build_relay(loss: 20, burst: 8, seed: 3)
    exchange(relay, 2000)

    assert_in_delta 0.05, relay.counts.loss_rate, 0.02
    assert_operator relay.counts.longest_burst, :>=, 4
  ensure
    relay&.stop
  end

  # --- delay ----------------------------------------------------------------

  def test_jitter_spreads_arrival_times
    relay = build_relay(delay: 0.02, jitter: 0.015)
    client = UDPSocket.new
    arrivals = []
    20.times do |i|
      sent = monotonic
      client.send("p#{i}", 0, "127.0.0.1", relay.port)
      client.recvfrom(64)
      arrivals << monotonic - sent
    end

    spread = arrivals.max - arrivals.min
    assert_operator spread, :>, 0.01, "constant delay should not be this tight: #{arrivals.inspect}"
  ensure
    client&.close
    relay&.stop
  end

  # --- reorder --------------------------------------------------------------

  def test_reorder_delivers_out_of_sequence
    relay = build_relay(reorder: 3, reorder_delay: 0.05, seed: 1)
    back = exchange(relay, 30, wait: 0.4)

    assert_equal 30, back.size, "reorder must not lose anything"
    assert_operator relay.counts.reordered, :>, 0
    refute_equal back, back.sort_by { |p| p[/\d+/].to_i }, "nothing arrived out of order"
  ensure
    relay&.stop
  end

  # --- corrupt / size -------------------------------------------------------

  def test_corrupt_flips_exactly_one_bit
    relay = build_relay(corrupt: 1, seed: 1) # every packet
    back = exchange(relay, 1)

    assert_equal 1, back.size
    original = "packet-0".ljust(16)
    # Corrupted on the way in and again on the way out: two flips.
    differing_bits = original.bytes.zip(back.first.bytes).sum { |a, b| (a ^ b).to_s(2).count("1") }
    assert_equal 2, differing_bits
  ensure
    relay&.stop
  end

  def test_oversized_datagrams_are_dropped_not_fragmented
    relay = build_relay(max_size: 100)
    small = exchange(relay, 5, size: 50)
    large = exchange(relay, 5, size: 200)

    assert_equal 5, small.size
    assert_empty large
    assert_equal 5, relay.counts.oversized
  ensure
    relay&.stop
  end

  # --- rate -----------------------------------------------------------------

  def test_rate_discards_over_budget_packets
    relay = build_relay(rate: 10, rate_interval: 1.0)
    back = exchange(relay, 50)

    assert_operator back.size, :<=, 10
    assert_operator relay.counts.throttled, :>, 0
  ensure
    relay&.stop
  end

  # A shaper queues; a policer discards. Over a shaped link a burst arrives
  # late and complete. Over a policed one it arrives on time and short.
  def test_bandwidth_queues_instead_of_discarding
    relay = build_relay(bandwidth: 100_000) # 100 KB/s
    elapsed = timed do
      back = exchange(relay, 50, size: 1000, wait: 2) # 50 KB ≈ 0.5s
      assert_equal 50, back.size
    end

    assert_operator elapsed, :>, 0.4
    assert_equal 0, relay.counts.dropped
  ensure
    relay&.stop
  end

  # --- self-verification ----------------------------------------------------

  def test_shortfall_reports_what_the_relay_never_saw
    relay = build_relay(target_port: Echo::Udp.new.port) # sink that echoes to nowhere useful
    exchange(relay, 100, wait: 0.2)
    relay.stop

    result = relay.shortfall(300) # claim we sent more than we did
    assert_equal 300, result[:offered]
    assert_operator result[:missing], :>, 0
    assert_raises(Impair::Error) { relay.verify!(300) }
  end

  def test_verify_passes_when_everything_was_seen
    relay = build_relay
    exchange(relay, 100)
    relay.stop

    assert relay.verify!(200) # both directions
  end

  def test_rcvbuf_is_read_back_from_the_socket
    relay = build_relay(rcvbuf: 256 * 1024)
    assert_operator relay.rcvbuf, :>=, 256 * 1024
  ensure
    relay&.stop
  end

  def test_many_datagrams_are_all_seen
    relay = build_relay
    sent = 5_000
    exchange(relay, sent, size: 1200, wait: 1.0)
    relay.stop

    result = relay.shortfall(sent + @echo.received)
    assert_equal 0, result[:missing], result.inspect
  end
end
