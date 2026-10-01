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
    attr_reader :port, :counts, :rcvbuf

    # rcvbuf is requested, not guaranteed: the OS clamps to kern.ipc.maxsockbuf
    # (macOS) or net.core.rmem_max (Linux). The applied value is read back and
    # exposed, because a silently clamped buffer is the failure this guards
    # against. See #shortfall.
    def initialize(target_host:, target_port:, host: "127.0.0.1", port: 0,
      rcvbuf: 8 * 1024 * 1024, **options)
      @target_host = target_host
      @target_port = target_port
      @config = Config.new(**options)
      @counts = Counts.new
      @counts_mutex = Mutex.new
      @rate_mutex = Mutex.new
      # One RNG per direction. A single shared RNG is drawn from both pumps, so
      # the sequence each direction sees depends on how the scheduler
      # interleaves them, which makes seed a tendency rather than a guarantee.
      # Interleaving does not bias the loss *rate* -- every draw is still
      # 1-in-N -- but it does make a run unrepeatable.
      @random = { client: Random.new(@config.seed), server: Random.new(@config.seed ^ 0xffff) }
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
      @bucket = 0
      @refilled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @timers = []
      @timer_mutex = Mutex.new
      @timer_wake = ConditionVariable.new
    end

    def start
      @running = true
      @inbox = { client: SizedQueue.new(8192), server: SizedQueue.new(8192) }
      @threads = [
        Thread.new { receive_from_client },
        Thread.new { receive_from_server },
        Thread.new { process(:client) { |p| @upstream.send(p, 0, @target_host, @target_port) } },
        Thread.new { process(:server) { |p| @socket.send(p, 0, *@client) } },
        Thread.new { run_timers }
      ]
      self
    end

    # Drains in-flight work before reporting, so forwarded counts packets that
    # were actually sent rather than packets that were merely decided on.
    def stop(drain: 0.5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + drain
      sleep 0.01 while pending? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      @running = false
      @inbox&.each_value { |q| q.close }
      @timer_mutex.synchronize { @timer_wake.broadcast }
      @socket.close unless @socket.closed?
      @upstream.close unless @upstream.closed?
      @threads&.each { |thread| thread.join(1) }
      @counts
    end

    # What the relay never got to make a decision about.
    #
    # The kernel drops datagrams that arrive while the receive buffer is full,
    # before the relay sees them. Those are invisible to every counter here:
    # they thin forwarded and dropped together, so loss_rate stays flat at the
    # advertised figure while the actual link loses far more. A relay that
    # cannot keep up reports a healthy 2% on a link losing 26%.
    #
    # So a caller that knows how many packets it offered must check. Counting
    # every decision is only a guarantee for decisions the relay was handed.
    def shortfall(offered)
      seen = @counts.total + @counts.overrun
      missing = offered - seen
      { offered: offered, observed: @counts.total, overrun: @counts.overrun,
        unreceived: missing, missing: missing + @counts.overrun,
        rate: offered.zero? ? 0.0 : (missing + @counts.overrun).fdiv(offered) }
    end

    # Raises unless the relay saw essentially everything that was sent. Use
    # this to gate a published throughput number.
    def verify!(offered, tolerance: 0.01)
      result = shortfall(offered)
      return result if result[:rate] <= tolerance

      raise Error, format(
        "relay lost %d of %d packets before impairing them (%.1f%%): %d never received " \
        "(kernel buffer), %d overran the processing queue. Measured link loss is not the " \
        "configured loss. rcvbuf=%d. Lower the offered rate.",
        result[:missing], offered, result[:rate] * 100,
        result[:unreceived], result[:overrun], @rcvbuf
      )
    end

    private

    def pending?
      return false unless @inbox

      @inbox.each_value.any? { |q| !q.empty? } || @timer_mutex.synchronize { @timers.any? }
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
      bump(:overrun)
    end

    def process(direction, &send)
      while (data = @inbox[direction].pop)
        deliver(data, direction, &send)
      end
    rescue IOError, Errno::EBADF, ClosedQueueError
      nil
    end

    def apply_rcvbuf(socket, bytes)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, bytes)
      socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
    rescue StandardError
      0
    end

    def bump(field)
      @counts_mutex.synchronize { @counts[field] += 1 }
    end

    # Drop, throttle, corrupt, delay, or pass. Order matters: a packet the link
    # never carried cannot also be corrupted.
    def deliver(data, direction, &send)
      if drop?(direction) || too_large?(data) || throttled?
        bump(:dropped)
        return
      end

      data = corrupt(data, direction) if corrupt?(direction)
      bump(:forwarded)

      if reorder?(direction)
        bump(:reordered)
        send_later(data, @config.reorder_delay, &send)
        return
      end

      # Delay must not block the pump. Sleeping here serialises every packet
      # behind the last one, which turns a 25ms link into a 450ms one and looks
      # like the protocol's fault.
      if @config.delay.positive?
        send_later(data, @config.delay, &send)
        return
      end

      send.call(data)
    end

    # One timer thread with a queue ordered by deadline, rather than a thread
    # per packet. A thread each was costing more than the delay it implemented
    # once a few thousand packets were in flight.
    def send_later(data, after, &send)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + after
      @timer_mutex.synchronize do
        @timers << [deadline, data, send]
        @timers.sort_by!(&:first)
        @timer_wake.signal
      end
    end

    def run_timers
      loop do
        due = @timer_mutex.synchronize do
          return unless @running

          if @timers.empty?
            @timer_wake.wait(@timer_mutex, 0.05)
            next
          end

          wait = @timers.first.first - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if wait > 0
            @timer_wake.wait(@timer_mutex, wait)
            next
          end

          @timers.shift
        end
        next unless due

        _, data, send = due
        begin
          send.call(data)
        rescue IOError, Errno::EBADF
          nil
        end
      end
    end

    # A single bit flip, which smoltcp picks as the most likely corruption and
    # the hardest to detect. QUIC authenticates every packet, so the peer
    # discards it: corruption and loss look alike on the wire and differ in
    # whether the sender learns anything.
    def corrupt(data, direction)
      rng = @random[direction]
      flipped = data.dup
      index = rng.rand(flipped.bytesize)
      flipped.setbyte(index, flipped.getbyte(index) ^ (1 << rng.rand(8)))
      bump(:corrupted)
      flipped
    end

    # Over the limit is dropped rather than fragmented, which is what a path
    # with a smaller MTU and no fragmentation does.
    def too_large?(data)
      return false unless @config.max_size.positive?
      return false if data.bytesize <= @config.max_size

      bump(:oversized)
      true
    end

    # A token bucket refilled every rate_interval, as smoltcp does it: packets
    # per interval rather than bytes per second, so the unit matches loss.
    #
    # Note this is a policer, not a shaper: over-budget packets are discarded
    # rather than queued, so it cannot produce queueing delay or bufferbloat.
    def throttled?
      return false unless @config.rate.positive?

      over = @rate_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now - @refilled_at > @config.rate_interval
          @bucket = @config.rate
          @refilled_at = now
        end

        if @bucket.positive?
          @bucket -= 1
          false
        else
          true
        end
      end
      return false unless over

      bump(:throttled)
      true
    end

    def family_for(host) = host.include?(":") ? Socket::AF_INET6 : Socket::AF_INET

    def drop?(dir) = @config.loss.positive? && @random[dir].rand(@config.loss).zero?

    def reorder?(dir) = @config.reorder.positive? && @random[dir].rand(@config.reorder).zero?

    def corrupt?(dir) = @config.corrupt.positive? && @random[dir].rand(@config.corrupt).zero?
  end
end
