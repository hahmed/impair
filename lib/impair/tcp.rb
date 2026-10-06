# frozen_string_literal: true

require "socket"

module Impair
  # A TCP relay that emulates packet loss by its consequence.
  #
  # Bytes cannot be dropped here. TCP's reliability lives below a userspace
  # relay, so removing bytes from the stream corrupts it rather than emulating
  # a lost packet, which is why Toxiproxy offers latency and slicing but never
  # loss.
  #
  # What can be reproduced exactly is what loss does to the receiver. When a
  # segment is lost, the receiving kernel holds every byte that arrives after
  # the gap until the retransmission fills it, roughly one round trip later
  # with fast retransmit, and the application is handed nothing in the
  # meantime. Every stream multiplexed on that connection waits, whether or not
  # its own data was in the missing segment. RFC 9114 1.1: "a lost or reordered
  # packet causes all active transactions to experience a stall regardless of
  # whether that transaction was directly impacted by the lost packet."
  #
  # So loss here is a stall of the whole stream for one round trip (2 * delay),
  # decided per segment-sized chunk. That is the same currency as the UDP side,
  # where a dropped datagram costs its stream one round trip, which makes the
  # two comparable: same loss probability per packet, same cost per loss, and
  # the difference left over is the protocol's. It follows that loss on a
  # zero-delay link costs nothing here, which is also true of the real thing.
  #
  # It also reproduces the part of the sender's reaction that matters for a
  # burst. One lost segment is recovered by fast retransmit, one RTT. Three or
  # more in a row leave no duplicate acks to trigger it, so the sender waits
  # for the retransmission timer (RFC 6298, floored at rto_min), then
  # collapses its window to one segment and slow-starts back, so the segments
  # after the burst are paced by the window rather than the link. Lose the
  # probe too and the timer doubles. Without this the TCP arm shrugs off the
  # bursts that trigger persistent congestion on the QUIC side, and the
  # comparison is rigged.
  #
  # An isolated loss also costs the sender half its window (RFC 5681 3.2:
  # ssthresh = max(FlightSize / 2, 2 * SMSS), and cwnd is set to it on fast
  # recovery), and the window then grows by one segment per round trip. Under
  # scattered loss this is most of what TCP pays: it spends its life in
  # congestion avoidance, never near its initial window, so every segment is
  # paced by a window the losses keep cutting. Without it the arm charged only
  # the stall, and at 1-in-50 that is the smaller cost.
  #
  # What it does not reproduce: SACK, spurious retransmits, or the sender's
  # bandwidth estimate. corrupt, reorder, max_size and rate are accepted for
  # Config parity and ignored.
  class Tcp
    include Relay

    def initialize(target_host:, target_port:, host: "127.0.0.1", port: 0,
      trace: false, replay: nil, **options)
      @target_host = target_host
      @target_port = target_port
      @link = Link.new(Config.new(**options), trace: trace, replay: replay)
      @server = TCPServer.new(host, port)
      @port = @server.addr[1]
      @connections = []
      @connections_mutex = Mutex.new
      @running = false
    end

    def start
      @running = true
      @link.start
      @acceptor = Thread.new do
        while @running
          # Pass the socket as an argument. A while-loop local is one variable
          # shared by every iteration, so a block that closes over it can see
          # the *next* accepted socket if accept returns before the thread
          # starts -- two threads then serve one connection and another is
          # never read at all.
          Thread.new(@server.accept) { |client| serve(client) }
        end
      rescue IOError, Errno::EBADF
        nil
      end
      self
    end

    def stop
      return counts unless @running

      @running = false
      @server.close unless @server.closed?
      @acceptor&.join(1)
      @link.stop
      each_connection { |c, u| [c, u].each { |s| s.close rescue nil } }
      counts
    end

    # Send RST on every live connection, the way a middlebox or a crashed peer
    # does. SO_LINGER with a zero timeout makes close() reset instead of FIN.
    # New connections are accepted as before.
    def reset
      each_connection do |client, upstream|
        [client, upstream].each do |s|
          s.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii")) rescue nil
          s.close rescue nil
        end
        counts.reset += 1
      end
      self
    end

    private

    def each_connection(&)
      @connections_mutex.synchronize { @connections.dup }.each(&)
    end

    def serve(client)
      upstream = TCPSocket.new(@target_host, @target_port)
      # Without this, Nagle holds a sub-MSS write until the previous segment is
      # acknowledged. The relay writes at most one MSS at a time, so every
      # write is a candidate, and the result is tens of milliseconds of delay
      # attributed to the protocol under test rather than to the relay.
      [client, upstream].each { |s| s.setsockopt(:IPPROTO_TCP, :TCP_NODELAY, 1) rescue nil }
      @connections_mutex.synchronize do
        @connections << [client, upstream]
        counts.connections += 1
      end
      pumps = [
        Thread.new { pump(:client, client, upstream) },
        Thread.new { pump(:server, upstream, client) }
      ]
      pumps.each(&:join)
    rescue StandardError
      nil
    ensure
      @connections_mutex.synchronize { @connections.delete([client, upstream]) }
      client.close rescue nil
      upstream&.close rescue nil
    end

    # Read one segment at a time so the loss decision is per segment: a single
    # 64 KiB read would be 45 segments on the wire and one roll of the dice.
    #
    # Reading never sleeps. Each segment gets a deadline and a writer thread
    # delivers it then, in order. Sleeping here instead charged the delay once
    # per segment rather than once per link: 100 KB at 25ms took 1.75s.
    def pump(direction, from, to)
      outbox = Queue.new
      writer = Thread.new { write_deferred(outbox, to) }
      last_deadline = 0.0
      cc = Congestion.new(config)

      while (chunk = from.readpartial(config.mss))
        deadline = [@link.now + @link.latency(direction), last_deadline].max

        if @link.blackholed?
          # Nothing crosses until the hole heals, then everything behind it
          # arrives at once, which is what a retransmit after an outage does.
          @link.bump(direction, :blackholed)
          deadline = [deadline, @link.blackhole_until].max
        end

        # A lost segment is counted as dropped, not forwarded, same as a lost
        # datagram: the link lost that packet. That TCP then retransmits it
        # is the stall, which is what the deadline carries.
        action = :forwarded
        if @link.lost?(direction)
          # The gap stalls everything behind it, which is the whole point.
          action = :dropped
          stall, rto = cc.lost
          @link.bump(direction, :rto) if rto
          deadline += stall
        else
          deadline += cc.delivered
        end

        queued = @link.shape(direction, chunk.bytesize)
        if queued
          deadline += queued
        else
          # Shaper queue overflowed. TCP would retransmit; charge an RTT.
          deadline += config.rtt
        end

        @link.bump(direction, action)
        @link.record(direction, action, chunk.bytesize, deadline - @link.now)
        last_deadline = deadline
        outbox << [deadline, chunk]
      end
    rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::EBADF
      nil
    ensure
      outbox.close
      writer.join
    end

    # The sender's window, per direction per connection. An isolated loss
    # halves it; a run long enough to defeat fast retransmit charges the RTO
    # and collapses it to one segment. Afterwards each delivered segment is
    # paced by the window: a window of w segments drains in one RTT, so each
    # costs rtt / w. Growth is slow start up to ssthresh, one segment per RTT
    # beyond it (RFC 5681 3.1), and the ceiling is the initial window, because
    # the relay has no bandwidth estimate to grow past it.
    class Congestion
      FAST_RETRANSMIT_THRESHOLD = 3 # dupacks needed; a run this long has none
      INITIAL_WINDOW = 10.0 # segments, RFC 6928
      MIN_WINDOW = 2.0 # RFC 5681 3.2: ssthresh = max(FlightSize / 2, 2 * SMSS)

      attr_reader :cwnd, :ssthresh

      def initialize(config)
        @config = config
        @on = config.congestion
        @run = 0
        @cwnd = INITIAL_WINDOW
        @ssthresh = Float::INFINITY
      end

      # Returns [stall_seconds, rto_fired?].
      #
      # A run of losses is one timer event, not one per segment. Every
      # segment in the run was in flight when the timer expired, and all of
      # them go out again with the retransmit, so the loss that defeats fast
      # retransmit pays the RTO and the rest of the run pays nothing more. A
      # link model that says "lost" ten times in a row is describing one
      # window, not ten probes.
      #
      # Not modelled: exponential backoff when the probe itself is lost. The
      # loss pattern cannot say which segment is the probe, so charging it
      # would mean charging it for every segment in the window, which is how
      # a 10-segment burst came to cost 25 seconds. One RTO per burst is the
      # floor of what TCP pays, and still an order of magnitude more than the
      # one-RTT stall it was charged before.
      def lost
        @run += 1
        return [@config.rtt, false] unless @on

        if @run == 1
          # Fast retransmit: one RTT, and the window halves. Charged on the
          # first loss of a run only; a run is one congestion event.
          @ssthresh = [@cwnd / 2, MIN_WINDOW].max
          @cwnd = @ssthresh
          return [@config.rtt, false]
        end
        return [@config.rtt, false] if @run < FAST_RETRANSMIT_THRESHOLD
        return [0.0, false] if @run > FAST_RETRANSMIT_THRESHOLD

        # The timer fired. ssthresh was already set on the first loss of the
        # run; the window now goes to one segment (RFC 5681 3.1).
        @cwnd = 1.0
        [[@config.rto_min, @config.rtt * 2].max, true]
      end

      # Returns the pacing cost of delivering one segment under the window.
      def delivered
        @run = 0
        return 0.0 unless @on && @cwnd < INITIAL_WINDOW

        cost = @config.rtt / @cwnd
        # Slow start doubles per RTT (one segment per ack, so +1 per segment);
        # congestion avoidance adds one per RTT (+1/cwnd per segment).
        increment = @cwnd < @ssthresh ? 1.0 : 1.0 / @cwnd
        @cwnd = [@cwnd + increment, INITIAL_WINDOW].min
        cost
      end
    end

    def write_deferred(outbox, to)
      while (item = outbox.pop)
        deadline, chunk = item
        wait = deadline - @link.now
        sleep(wait) if wait.positive?
        to.write(chunk)
      end
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::EBADF
      nil
    ensure
      to.close_write rescue nil
    end
  end
end
