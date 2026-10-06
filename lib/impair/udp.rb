# frozen_string_literal: true

require "socket"

module Impair
  # A UDP relay. QUIC is UDP, so damaging datagrams here is the same thing the
  # network would do: a dropped datagram is a lost packet, and the protocol's
  # own loss recovery is what we are trying to observe.
  #
  # Each client address gets its own upstream socket, so the server sees as
  # many peers as there are clients. A browser opens six TCP connections to an
  # origin and one QUIC connection; the comparison that matters is six against
  # one, and it needs the relay to carry six. A single shared upstream would
  # fold them into one source port and the server would see one peer.
  #
  # Every flow shares the one link, so the loss, delay and shaper are the
  # link's, not the flow's: six connections through a 1-in-50 link each see
  # 1-in-50, and all six are shaped by the same bandwidth.
  class Udp
    include Relay

    attr_reader :rcvbuf

    # One client's path through the relay: where it came from and the upstream
    # socket that carries it to the server, with its own receiver so the reply
    # can be routed back.
    Flow = Struct.new(:client, :upstream, :receiver)

    # rcvbuf is requested, not guaranteed: the OS clamps to kern.ipc.maxsockbuf
    # (macOS) or net.core.rmem_max (Linux). The applied value is read back and
    # exposed, because a silently clamped buffer is the failure this guards
    # against. See Relay#shortfall.
    def initialize(target_host:, target_port:, host: "127.0.0.1", port: 0,
      rcvbuf: 8 * 1024 * 1024, trace: false, replay: nil, **options)
      @target_host = target_host
      @target_port = target_port
      @link = Link.new(Config.new(**options), trace: trace, replay: replay)
      # UDPSocket.new defaults to IPv4, so an IPv6 bind needs the family
      # stated. localhost resolves to ::1 first on macOS, which is where the
      # server under test binds.
      @socket = UDPSocket.new(family_for(host))
      @socket.bind(host, port)
      @port = @socket.addr[1]
      @requested_rcvbuf = rcvbuf
      @rcvbuf = apply_rcvbuf(@socket, rcvbuf)
      @flows = {}
      @flows_mutex = Mutex.new
      @running = false
    end

    def start
      @running = true
      @link.start
      @inbox = { client: SizedQueue.new(8192), server: SizedQueue.new(8192) }
      @threads = [
        Thread.new { receive_from_clients },
        Thread.new { process(:client) { |flow, p| flow.upstream.send(p, 0, @target_host, @target_port) } },
        Thread.new { process(:server) { |flow, p| @socket.send(p, 0, *flow.client) } }
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
      each_flow do |flow|
        flow.upstream.close unless flow.upstream.closed?
        flow.receiver&.join(1)
      end
      @threads&.each { |thread| thread.join(1) }
      counts
    end

    # Change the source port the server sees for every client, the way a NAT
    # does when its mapping expires (RFC 4787 4.3) or a phone moves from
    # Wi-Fi to cellular. Each flow's upstream socket is replaced by a fresh
    # one, so the server's next packet from this client arrives from a port
    # it has never seen. QUIC validates the new path and carries on (RFC
    # 9000 9); a TCP connection would simply be gone, which is why the TCP
    # relay has no equivalent and offers +reset+ instead.
    #
    # Packets already scheduled for delivery go out on the new socket, since
    # they read the flow's socket at send time: a rebind mid-delay is a
    # rebind, not a loss.
    def rebind
      each_flow do |flow|
        fresh = UDPSocket.new(family_for(@target_host))
        apply_rcvbuf(fresh, @requested_rcvbuf)
        old = flow.upstream
        flow.upstream = fresh
        # Closing the old socket ends its receiver, which exits on EBADF.
        old.close unless old.closed?
        flow.receiver = Thread.new { receive_from_server(flow) }
        counts.rebinds += 1
      end
      self
    end

    private

    def pending?
      @inbox.each_value.any? { |q| !q.empty? } || @link.pending?
    end

    def each_flow(&)
      @flows_mutex.synchronize { @flows.values.dup }.each(&)
    end

    # Receive loops do nothing but drain the socket. Deciding and sending
    # inline means a blocking send syscall stalls the receive loop, and
    # anything arriving during that stall is dropped by the kernel and never
    # counted. Buffer size alone does not fix that -- at 1200B datagrams a
    # recv/decide/send loop still falls behind a saturating sender.
    def receive_from_clients
      while @running
        data, addr = @socket.recvfrom(65_535)
        flow = flow_for([addr[3], addr[1]])
        enqueue(:client, flow, data)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    # Replies for one client. Each flow's upstream socket only ever hears
    # from the server, so whatever arrives belongs to this client. Reads the
    # socket once rather than through the flow each time, so a rebind that
    # swaps flow.upstream leaves this thread on the old socket, where close
    # ends it, while the new receiver takes the new one.
    def receive_from_server(flow)
      socket = flow.upstream
      while @running
        data, = socket.recvfrom(65_535)
        enqueue(:server, flow, data)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    # Finds or opens the flow for a client address. Opening is the first
    # packet's job, the way a NAT allocates a mapping on first use. The
    # receiver thread is started inside the lock so two first packets racing
    # cannot start two.
    def flow_for(client)
      @flows_mutex.synchronize do
        @flows[client] ||= begin
          upstream = UDPSocket.new(family_for(@target_host))
          # The smaller of the two buffers is the one that drops first.
          applied = apply_rcvbuf(upstream, @requested_rcvbuf)
          @rcvbuf = applied if applied.positive? && applied < @rcvbuf
          counts.connections += 1
          Flow.new(client, upstream, nil).tap do |flow|
            flow.receiver = Thread.new { receive_from_server(flow) }
          end
        end
      end
    end

    # Non-blocking, because a blocking push stalls the receive loop and the
    # kernel then discards whatever arrives during the stall -- the same
    # failure the split was meant to fix, only self-inflicted and equally
    # invisible. Dropping here instead keeps it countable.
    def enqueue(direction, flow, data)
      @inbox[direction].push([flow, data], true)
    rescue ThreadError
      @link.bump(direction, :overrun)
    end

    def process(direction, &send)
      while (item = @inbox[direction].pop)
        flow, data = item
        deliver(direction, flow, data, &send)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    # Admit, then schedule. Delay must not block the pump: sleeping here
    # serialises every packet behind the last one, which turns a 25ms link
    # into a 450ms one and looks like the protocol's fault.
    def deliver(direction, flow, data, &send)
      data = @link.admit(direction, data) or return
      queued = @link.shape(direction, data.bytesize) or return
      @link.bump(direction, :forwarded)

      wait = @link.latency(direction) + queued
      if @link.reorder?(direction)
        @link.bump(direction, :reordered)
        wait += config.reorder_delay
      end

      @link.record(direction, :forwarded, data.bytesize, wait)
      if wait.positive?
        @link.after(wait) { send.call(flow, data) }
      else
        send.call(flow, data)
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
