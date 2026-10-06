# frozen_string_literal: true

require "test_helper"

# Loss by ordinal. The relay must lose exactly the named packets, in the
# named direction, and nothing else when loss: 0.
class TestScript < Minitest::Test
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

  # --- construction -----------------------------------------------------------

  def test_a_range_names_consecutive_ordinals
    script = Impair::Script.drop(client: 2..4)

    assert_equal [false, true, true, true], script.losses[:client]
    assert_equal [], script.losses[:server]
    assert_equal [2, 3, 4], script.dropped(:client)
  end

  def test_an_array_names_scattered_ordinals
    script = Impair::Script.drop(client: [1, 3, 5])

    assert_equal [true, false, true, false, true], script.losses[:client]
  end

  def test_a_single_integer_and_a_mix_are_accepted
    assert_equal [false, false, true], Impair::Script.drop(server: 3).losses[:server]
    assert_equal [1, 2, 3, 7], Impair::Script.drop(client: [1..3, 7]).dropped(:client)
  end

  def test_ordinals_are_one_based_and_positive
    assert_raises(ArgumentError) { Impair::Script.drop(client: 0) }
    assert_raises(ArgumentError) { Impair::Script.drop(client: -1) }
    assert_raises(ArgumentError) { Impair::Script.drop(client: [1.5]) }
  end

  def test_to_s_summarises_runs
    assert_equal "Script(client: 2-7, server: 1,3)", Impair::Script.drop(client: 2..7, server: [1, 3]).to_s
    assert_equal "Script(nothing)", Impair::Script.drop.to_s
  end

  # --- on the wire -----------------------------------------------------------

  def test_exactly_the_named_client_packets_are_lost
    relay = build_relay(loss: 0, replay: Impair::Script.drop(client: [2, 3, 5]))
    received = udp_exchange(relay, 8)
    counts = relay.stop

    assert_equal 3, counts.client.dropped
    assert_equal 0, counts.server.dropped
    # Ordinals are 1-based, payloads are 0-based: packets 2, 3, 5 are
    # payloads packet-1, packet-2, packet-4.
    lost = %w[packet-1 packet-2 packet-4]
    assert_equal (0...8).map { |i| "packet-#{i}" } - lost, received.map(&:strip).sort
  ensure
    relay&.stop
  end

  def test_server_direction_is_scripted_independently
    relay = build_relay(loss: 0, replay: Impair::Script.drop(server: 1..2))
    received = udp_exchange(relay, 5)
    counts = relay.stop

    assert_equal 0, counts.client.dropped
    assert_equal 2, counts.server.dropped
    assert_equal 3, received.size
  ensure
    relay&.stop
  end

  # With loss: 0 and the script exhausted, nothing more is lost: the script
  # is the whole story, not a prefix on a random one.
  def test_past_the_script_nothing_is_lost_when_loss_is_zero
    relay = build_relay(loss: 0, replay: Impair::Script.drop(client: 1))
    received = udp_exchange(relay, 50)
    counts = relay.stop

    assert_equal 1, counts.client.dropped
    assert_equal 49, received.size
    assert_equal 1, counts.client.replayed
  ensure
    relay&.stop
  end

  # A script is replayable on TCP too: ordinal n is the nth segment.
  def test_tcp_loses_the_named_segment
    echo = Echo::Tcp.new
    relay = Impair::Tcp.new(target_host: "127.0.0.1", target_port: echo.port, host: "127.0.0.1",
      loss: 0, delay: 0.01, mss: 1000, replay: Impair::Script.drop(client: 2)).start
    tcp_roundtrip(relay, "x" * 4000, mss: 1000)
    counts = relay.stop

    assert_equal 1, counts.client.dropped
    assert_equal 0, counts.rto
  ensure
    relay&.stop
    echo&.close
  end
end
