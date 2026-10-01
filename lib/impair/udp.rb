# frozen_string_literal: true

require "socket"

module Impair
  # A UDP relay. QUIC is UDP, so damaging datagrams here is the same thing the
  # network would do: a dropped datagram is a lost packet, and the protocol's
  # own loss recovery is what we are trying to observe.
  #
  # One client address at a time, which is all a benchmark needs and keeps the
  # return path unambiguous.
  class Udp
    include Relay

    attr_reader :rcvbuf

    # rcvbuf is requested, not guaranteed: the OS clamps to kern.ipc.maxsockbuf
    # (macOS) or net.core.rmem_max (Linux). The applied value is read back and
    # exposed, because a silently clamped buffer is the failure this guards
    # against. See Relay#shortfall.
    def initialize(target_host:, target_port:, host: "127.0.0.1", port: 0,
      rcvbuf: 8 * 1024 * 1024, **options)
      @target_host = target_host
      @target_port = target_port
      @link = Link.new(Config.new(**options))
      # UDPSocket.new defaults to IPv4, so an IPv6 bind needs the family
      # stated. localhost resolves to ::1 first on macOS, which is where the
      # server under test binds.
      @socket = UDPSocket.new(family_for(host))
      @socket.bind(host, port)
      @port = @socket.addr[1]
      @upstream = UDPSocket.new(family_for(target_host))
      @rcvbuf = [@socket, @upstream].map { |s| apply_rcvbuf(s, rcvbuf) }.min
      @client = nil
      @running = false
    end

    def start
      @running = true
      @link.start
      @inbox = { client: SizedQueue.new(8192), server: SizedQueue.new(8192) }
      @threads = [
        Thread.new { receive_from_client },
        Thread.new { receive_from_server },
        Thread.new { process(:client) { |p| @upstream.send(p, 0, @target_host, @target_port) } },
        Thread.new { process(:server) { |p| @socket.send(p, 0, *@client) } }
      ]
      self
    end

    # Drains in-flight work before reporting, so forwarded counts packets that
    # were actually sent rather than packets that were merely decided on.
    def stop(drain: 0.5)
      return counts unless @running

      deadline = @link.now + drain
      sleep 0.01 while pending? && @link.now < deadline

      @running = false
      @inbox&.each_value(&:close)
      @link.stop
      @socket.close unless @socket.closed?
      @upstream.close unless @upstream.closed?
      @threads&.each { |thread| thread.join(1) }
      counts
    end

    private

    def pending?
      @inbox.each_value.any? { |q| !q.empty? } || @link.pending?
    end

    # Receive loops do nothing but drain the socket. Deciding and sending
    # inline means a blocking send syscall stalls the receive loop, and
    # anything arriving during that stall is dropped by the kernel and never
    # counted. Buffer size alone does not fix that -- at 1200B datagrams a
    # recv/decide/send loop still falls behind a saturating sender.
    def receive_from_client
      while @running
        data, addr = @socket.recvfrom(65_535)
        @client = [addr[3], addr[1]]
        enqueue(:client, data)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    def receive_from_server
      while @running
        data, = @upstream.recvfrom(65_535)
        next unless @client

        enqueue(:server, data)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    # Non-blocking, because a blocking push stalls the receive loop and the
    # kernel then discards whatever arrives during the stall -- the same
    # failure the split was meant to fix, only self-inflicted and equally
    # invisible. Dropping here instead keeps it countable.
    def enqueue(direction, data)
      @inbox[direction].push(data, true)
    rescue ThreadError
      @link.bump(direction, :overrun)
    end

    def process(direction, &send)
      while (data = @inbox[direction].pop)
        deliver(direction, data, &send)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    # Admit, then schedule. Delay must not block the pump: sleeping here
    # serialises every packet behind the last one, which turns a 25ms link
    # into a 450ms one and looks like the protocol's fault.
    def deliver(direction, data, &send)
      data = @link.admit(direction, data) or return
      queued = @link.shape(direction, data.bytesize) or return
      @link.bump(direction, :forwarded)

      wait = @link.latency(direction) + queued
      if @link.reorder?(direction)
        @link.bump(direction, :reordered)
        wait += config.reorder_delay
      end

      if wait.positive?
        @link.after(wait) { send.call(data) }
      else
        send.call(data)
      end
    end

    def apply_rcvbuf(socket, bytes)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, bytes)
      socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
    rescue StandardError
      0
    end

    def family_for(host) = host.include?(":") ? Socket::AF_INET6 : Socket::AF_INET
  end
end
