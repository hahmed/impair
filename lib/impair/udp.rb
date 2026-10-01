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
    attr_reader :port, :counts

    def initialize(target_host:, target_port:, host: "127.0.0.1", port: 0, **options)
      @target_host = target_host
      @target_port = target_port
      @config = Config.new(**options)
      @counts = Counts.new
      @random = Random.new(@config.seed)
      # UDPSocket.new defaults to IPv4, so an IPv6 bind needs the family
      # stated. localhost resolves to ::1 first on macOS, which is where the
      # server under test binds.
      @socket = UDPSocket.new(family_for(host))
      @socket.bind(host, port)
      @port = @socket.addr[1]
      @upstream = UDPSocket.new(family_for(target_host))
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
      @threads = [
        Thread.new { pump_from_client },
        Thread.new { pump_from_server },
        Thread.new { run_timers }
      ]
      self
    end

    def stop
      @running = false
      @timer_mutex.synchronize { @timer_wake.broadcast }
      @socket.close unless @socket.closed?
      @upstream.close unless @upstream.closed?
      @threads&.each { |thread| thread.join(1) }
      @counts
    end

    private

    def pump_from_client
      while @running
        data, addr = @socket.recvfrom(65_535)
        @client = [addr[3], addr[1]]
        deliver(data) { |payload| @upstream.send(payload, 0, @target_host, @target_port) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def pump_from_server
      while @running
        data, = @upstream.recvfrom(65_535)
        next unless @client

        deliver(data) { |payload| @socket.send(payload, 0, *@client) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    # Drop, throttle, corrupt, delay, or pass. Order matters: a packet the link
    # never carried cannot also be corrupted.
    def deliver(data, &send)
      if drop? || too_large?(data) || throttled?
        @counts.dropped += 1
        return
      end

      data = corrupt(data) if corrupt?
      @counts.forwarded += 1

      if reorder?
        @counts.reordered += 1
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
    def corrupt(data)
      flipped = data.dup
      index = @random.rand(flipped.bytesize)
      flipped.setbyte(index, flipped.getbyte(index) ^ (1 << @random.rand(8)))
      @counts.corrupted += 1
      flipped
    end

    # Over the limit is dropped rather than fragmented, which is what a path
    # with a smaller MTU and no fragmentation does.
    def too_large?(data)
      return false unless @config.max_size.positive?
      return false if data.bytesize <= @config.max_size

      @counts.oversized += 1
      true
    end

    # A token bucket refilled every rate_interval, as smoltcp does it: packets
    # per interval rather than bytes per second, so the unit matches loss.
    def throttled?
      return false unless @config.rate.positive?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now - @refilled_at > @config.rate_interval
        @bucket = @config.rate
        @refilled_at = now
      end

      if @bucket.positive?
        @bucket -= 1
        return false
      end

      @counts.throttled += 1
      true
    end

    def family_for(host) = host.include?(":") ? Socket::AF_INET6 : Socket::AF_INET

    def drop? = @config.loss.positive? && @random.rand(@config.loss).zero?

    def reorder? = @config.reorder.positive? && @random.rand(@config.reorder).zero?

    def corrupt? = @config.corrupt.positive? && @random.rand(@config.corrupt).zero?
  end
end
