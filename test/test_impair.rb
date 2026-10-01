# frozen_string_literal: true

require "test_helper"

# Against real sockets rather than stubs. The thing under test *is* the socket
# behaviour: a relay that forwards correctly in a unit test and mangles the
# return path in practice would pass a mocked version of all of this.
class TestImpair < Minitest::Test
  def setup
    @echo = UDPSocket.new
    @echo.bind("127.0.0.1", 0)
    @echo_port = @echo.addr[1]
    @echo_thread = Thread.new do
      loop do
        data, addr = @echo.recvfrom(65_535)
        @echo.send(data, 0, addr[3], addr[1])
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def teardown
    @relay&.stop
    @echo.close unless @echo.closed?
    @echo_thread&.kill
  end

  def test_a_clean_relay_delivers_every_datagram
    counts = exchange(50, loss: 0)

    assert_equal 0, counts.dropped
    # Both directions pass through the relay and both are counted, so 50
    # datagrams echoed back is 100 forwarded packets.
    assert_equal 100, counts.forwarded
    assert_in_delta 0.0, counts.loss_rate, 0.0001
  end

  # The assertion the benchmarks depend on: the advertised impairment has to
  # actually happen. A relay that silently forwards everything reports "loss
  # changed nothing", which is indistinguishable from a real finding.
  def test_loss_drops_datagrams_at_about_the_advertised_rate
    counts = exchange(200, loss: 4)

    assert_operator counts.dropped, :>, 0
    assert_in_delta 0.25, counts.loss_rate, 0.1
  end

  # Same seed, same decisions — but only in one direction.
  #
  # Both directions draw from one RNG, so the order of draws depends on how the
  # return traffic interleaves with the outbound, which the scheduler decides.
  # Against the echo server this test fails by one or two drops in a hundred.
  # So it targets a sink that never replies, which is the only configuration in
  # which the seed is a guarantee rather than a tendency. See README.
  def test_the_seed_makes_loss_reproducible_in_one_direction
    sink = UDPSocket.new
    sink.bind("127.0.0.1", 0)
    sink_port = sink.addr[1]

    first = exchange(100, loss: 4, seed: 99, target_port: sink_port).dropped
    second = exchange(100, loss: 4, seed: 99, target_port: sink_port).dropped

    assert_operator first, :>, 0
    assert_equal first, second
  ensure
    sink&.close
  end

  # Twenty datagrams through a 50ms relay should all be back after roughly one
  # delay each way, not twenty. Sleeping in the pump instead of deferring makes
  # every packet wait behind the one before it, which is the bug this pins: a
  # 25ms link measured 450ms that way.
  #
  # Has to time the round trip the client actually sees. Timing the relay's own
  # bookkeeping proves nothing, because the pump runs on its own thread and the
  # sender returns immediately either way.
  def test_delay_is_not_paid_serially_per_datagram
    relay = Impair::Udp.new(
      target_host: "127.0.0.1", target_port: @echo_port, host: "127.0.0.1",
      loss: 0, delay: 0.05
    ).start
    client = UDPSocket.new

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    20.times { |i| client.send("packet-#{i}", 0, "127.0.0.1", relay.port) }
    20.times { client.recvfrom(65_535) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # Two 50ms hops is 100ms; serialised would be 2s.
    assert_operator elapsed, :>, 0.1
    assert_operator elapsed, :<, 0.6
  ensure
    client&.close
    relay&.stop
  end

  private

  # Sends +count+ datagrams through a relay in front of the echo server and
  # returns the relay's counts.
  def exchange(count, target_port: @echo_port, **options)
    @relay&.stop
    @relay = Impair::Udp.new(
      target_host: "127.0.0.1", target_port: target_port, host: "127.0.0.1", **options
    ).start

    client = UDPSocket.new
    count.times { |i| client.send("packet-#{i}", 0, "127.0.0.1", @relay.port) }
    sleep 0.3
    client.close

    @relay.counts
  end
end
