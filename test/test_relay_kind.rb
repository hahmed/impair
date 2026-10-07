# frozen_string_literal: true

require "test_helper"

class TestRelayKind < Minitest::Test
  def test_udp_kinds
    [:udp, :quic, "HTTP/3", "udp"].each do |kind|
      assert_equal Impair::Udp, Impair.relay_class(kind), "#{kind.inspect} should be UDP"
    end
  end

  def test_tcp_kinds
    [:tcp, "HTTP/2", "HTTP/1.1", "HTTP/1.0", "tcp"].each do |kind|
      assert_equal Impair::Tcp, Impair.relay_class(kind), "#{kind.inspect} should be TCP"
    end
  end

  def test_unknown_kind_names_what_it_accepts
    error = assert_raises(ArgumentError) { Impair.relay_class("SCTP") }
    assert_includes error.message, "SCTP"
    assert_includes error.message, "HTTP/3"
  end

  # The point of the factory is that the same call site serves both arms of a
  # comparison, so the block form has to behave identically to Relay.start.
  def test_relay_block_form_returns_counts_and_stops
    server = UDPSocket.new
    server.bind("127.0.0.1", 0)

    counts = Impair.relay(:udp, target_host: "127.0.0.1", target_port: server.addr[1]) do |relay|
      assert_predicate relay.port, :positive?
    end

    assert_respond_to counts, :combined
  ensure
    server&.close
  end
end
