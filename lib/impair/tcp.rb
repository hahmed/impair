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
  # So loss here is a stall of the whole stream for one round trip, decided per
  # segment-sized chunk. That is the same currency as the UDP side, where a
  # dropped datagram costs its stream one round trip, which makes the two
  # comparable: same loss probability per packet, same cost per loss, and the
  # difference left over is the protocol's.
  #
  # What it does not reproduce: congestion window collapse, spurious
  # retransmits, SACK behaviour, or the sender learning anything. It emulates
  # the head-of-line stall, not TCP's full reaction to loss.
  class Tcp
    attr_reader :port, :counts

    # loss is 1-in-N segments, each costing the whole stream one rtt. mss sets
    # what counts as a segment, so the probability is per packet rather than
    # per read, which would depend on the relay's buffer size instead of the
    # network.
    def initialize(target_host:, target_port:, host: "127.0.0.1", port: 0,
      loss: 0, rtt: 0.05, mss: 1460, delay: 0, seed: 1234)
      @target_host = target_host
      @target_port = target_port
      @loss = loss
      @rtt = rtt
      @mss = mss
      @delay = delay
      @random = Random.new(seed)
      @counts = Counts.new
      @server = TCPServer.new(host, port)
      @port = @server.addr[1]
      @running = false
      @mutex = Mutex.new
    end

    def start
      @running = true
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
      @running = false
      @server.close unless @server.closed?
      @acceptor&.join(1)
      @counts
    end

    private

    def serve(client)
      upstream = TCPSocket.new(@target_host, @target_port)
      # Without this, Nagle holds a sub-MSS write until the previous segment is
      # acknowledged. The relay writes at most one MSS at a time, so every
      # write is a candidate, and the result is tens of milliseconds of delay
      # attributed to the protocol under test rather than to the relay.
      [client, upstream].each { |s| s.setsockopt(:IPPROTO_TCP, :TCP_NODELAY, 1) rescue nil }
      pumps = [
        Thread.new { pump(client, upstream) },
        Thread.new { pump(upstream, client) }
      ]
      pumps.each(&:join)
    rescue StandardError
      nil
    ensure
      client.close rescue nil
      upstream&.close rescue nil
    end

    # Read at most one segment at a time so that the loss decision is made per
    # segment. A single 64 KiB read would be 45 segments on the wire and one
    # roll of the dice.
    def pump(from, to)
      while (chunk = from.readpartial(@mss))
        @mutex.synchronize { @counts.forwarded += 1 }

        if lost?
          @mutex.synchronize { @counts.dropped += 1 }
          # The gap stalls everything behind it, which is the whole point.
          sleep(@rtt)
        end

        sleep(@delay) if @delay.positive?
        to.write(chunk)
      end
    rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::EBADF
      nil
    ensure
      to.close_write rescue nil
    end

    def lost? = @loss.positive? && @mutex.synchronize { @random.rand(@loss).zero? }
  end

end
