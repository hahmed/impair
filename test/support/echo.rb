# frozen_string_literal: true

require "socket"
require "timeout"

# Real sockets, not stubs. The thing under test *is* socket behaviour; a relay
# that passes a mocked suite and mangles the return path in practice proves
# nothing.
module Echo
  class Udp
    attr_reader :port, :received

    def initialize
      @socket = UDPSocket.new
      @socket.bind("127.0.0.1", 0)
      @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 8 * 1024 * 1024)
      @port = @socket.addr[1]
      @received = 0
      @thread = Thread.new do
        loop do
          data, addr = @socket.recvfrom(65_535)
          @received += 1
          @socket.send(data, 0, addr[3], addr[1])
        end
      rescue IOError, Errno::EBADF
        nil
      end
    end

    def close
      @socket.close unless @socket.closed?
      @thread.kill
    end
  end

  class Tcp
    attr_reader :port, :connections

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @connections = 0
      @clients = []
      @thread = Thread.new do
        loop do
          client = @server.accept
          @connections += 1
          @clients << client
          Thread.new do
            client.setsockopt(:IPPROTO_TCP, :TCP_NODELAY, 1)
            while (chunk = client.readpartial(65_535))
              client.write(chunk)
            end
          rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
            nil
          ensure
            client.close rescue nil
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end
    end

    def close
      @server.close unless @server.closed?
      @clients.each { |c| c.close rescue nil }
      @thread.kill
    end
  end
end

module RelayHelpers
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def timed
    started = monotonic
    yield
    monotonic - started
  end

  # Send +count+ datagrams through +relay+ and collect what comes back, for up
  # to +wait+ seconds. Returns the payloads received, in arrival order.
  def udp_exchange(relay, count, size: 16, wait: 0.5)
    client = UDPSocket.new
    client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 8 * 1024 * 1024)
    count.times { |i| client.send("packet-#{i}".ljust(size), 0, "127.0.0.1", relay.port) }

    received = []
    deadline = monotonic + wait
    while (remaining = deadline - monotonic).positive?
      ready = IO.select([client], nil, nil, remaining)
      break unless ready

      received << client.recvfrom(65_535).first
      break if received.size == count
    end
    received
  ensure
    client&.close
  end

  # Write +payload+ through a TCP relay and read it all back.
  def tcp_roundtrip(relay, payload, timeout: 5)
    client = TCPSocket.new("127.0.0.1", relay.port)
    client.setsockopt(:IPPROTO_TCP, :TCP_NODELAY, 1)
    client.write(payload)
    Timeout.timeout(timeout) { client.read(payload.bytesize) }
  ensure
    client&.close
  end
end
