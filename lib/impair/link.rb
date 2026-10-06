# frozen_string_literal: true

module Impair
  # The impairment engine both relays share: one Config, one set of counters,
  # one RNG per direction, and every decision about what happens to a packet.
  # Udp and Tcp are transports over this; the only thing they decide for
  # themselves is what "dropping" means on their wire.
  class Link
    Direction = %i[client server].freeze

    attr_reader :config, :counts, :trace

    # trace: true records every decision. replay: a Trace (or anything with
    # #losses) whose loss decisions are used instead of the RNG, per
    # direction, until exhausted; then the configured loss takes over.
    def initialize(config, trace: false, replay: nil)
      @config = config
      @counts = Counts.new
      @trace = Trace.new if trace
      @replay = replay&.losses
      @replay_pos = { client: 0, server: 0 }
      @mutex = Mutex.new
      # One RNG per direction. A single shared RNG drawn from both pumps makes
      # the sequence each direction sees depend on scheduler interleaving:
      # the loss *rate* is unaffected -- every draw is still 1-in-N -- but
      # the run is unrepeatable.
      @random = { client: Random.new(config.seed), server: Random.new(config.seed ^ 0xffff) }
      @burst_state = { client: :good, server: :good }
      @burst_run = { client: 0, server: 0 }
      @free_at = { client: 0.0, server: 0.0 }
      @bucket = 0
      @refilled_at = now
      @blackhole_until = 0.0
      @timers = Heap.new
      @timer_mutex = Mutex.new
      @timer_wake = ConditionVariable.new
      @running = false
    end

    # Swap the whole Config atomically. Readers see old or new, never a mix.
    def update(**changes)
      @config = @config.with(**changes)
      self
    end

    # Swallow everything for +seconds+. Counted as blackholed, not as link
    # loss, so loss_rate still describes the configured impairment.
    def blackhole(seconds)
      @blackhole_until = now + seconds
      self
    end

    def blackholed? = now < @blackhole_until

    attr_reader :blackhole_until

    def rng(direction) = @random[direction]

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def bump(direction, field)
      @mutex.synchronize { @counts[direction][field] += 1 }
    end

    # No-op unless tracing. Callers record forwarded themselves, with the
    # wait, once they know the packet is actually leaving.
    def record(direction, action, bytes, wait = 0.0)
      @trace&.record(direction, action, bytes, wait)
    end

    # Decide whether the link carries this packet. Returns the data to send
    # (possibly corrupted) or nil if it was discarded, in which case it has
    # already been tallied. The caller tallies forwarded once it actually
    # sends. Order matters: a packet the link never carried cannot also be
    # corrupted.
    def admit(direction, data, corruptible: true)
      reason = if blackholed? then :blackholed
      elsif lost?(direction) then :dropped
      elsif too_large?(direction, data) then :oversized
      elsif throttled?(direction) then :throttled
      end
      if reason
        bump(direction, reason)
        record(direction, reason, data.bytesize)
        return nil
      end

      corruptible && roll?(direction, @config.corrupt) ? corrupt(direction, data) : data
    end

    # How long this packet waits before it may leave, beyond base delay: the
    # time it spends behind earlier bytes on a bandwidth-limited link. nil if
    # the queue is full and the packet is discarded (tallied as overflow).
    #
    # A virtual queue: no bytes are held, only the time at which the link is
    # next free. Over-budget packets are scheduled later rather than dropped,
    # which is what produces queueing delay, and what a policer cannot.
    def shape(direction, bytes)
      return 0.0 unless @config.bandwidth.positive?

      @mutex.synchronize do
        t = now
        start = [t, @free_at[direction]].max
        queued_bytes = (start - t) * @config.bandwidth
        if queued_bytes + bytes > @config.queue
          @counts[direction].overflow += 1
          @trace&.record(direction, :overflow, bytes)
          return nil
        end
        @free_at[direction] = start + bytes.fdiv(@config.bandwidth)
        @free_at[direction] - t
      end
    end

    # One-way latency for this packet: delay plus a jitter sample. Uniform
    # in [-jitter, +jitter], clamped at zero.
    def latency(direction)
      base = @config.delay
      return base unless @config.jitter.positive?

      [base + (rng(direction).rand * 2 - 1) * @config.jitter, 0.0].max
    end

    def reorder?(direction) = roll?(direction, @config.reorder)

    # --- timers -------------------------------------------------------------

    def start
      @running = true
      @timer_thread = Thread.new { run_timers }
      self
    end

    def stop
      @running = false
      @timer_mutex.synchronize { @timer_wake.broadcast }
      @timer_thread&.join(1)
      self
    end

    def pending? = @timer_mutex.synchronize { !@timers.empty? }

    def at(deadline, &block)
      @timer_mutex.synchronize do
        @timers.push(deadline, block)
        @timer_wake.signal
      end
    end

    def after(seconds, &block) = at(now + seconds, &block)

    # Bernoulli when burst is off. Gilbert-Elliott when on: a good state that
    # never drops and a bad state that always does, with transition
    # probabilities chosen so the stationary loss rate is still 1/loss and the
    # mean bad-run length is +burst+. Burst loss is where HTTP/3 and HTTP/1
    # separate -- one burst stalls every stream on a TCP connection and only
    # the hit streams on QUIC -- so independent loss understates the gap.
    def lost?(direction)
      lost = decide_loss(direction)
      @trace&.decide(direction, lost)
      track_burst(direction, lost)
      lost
    end

    private

    def decide_loss(direction)
      if @replay && (list = @replay[direction]) && @replay_pos[direction] < list.size
        bump(direction, :replayed)
        pos = @replay_pos[direction]
        @replay_pos[direction] += 1
        return list[pos]
      end

      return false unless @config.loss.positive?
      return roll?(direction, @config.loss) if @config.burst <= 1

      r = 1.0 / @config.loss
      p_bad_to_good = 1.0 / @config.burst
      p_good_to_bad = p_bad_to_good * r / (1 - r)
      rnd = rng(direction).rand

      @mutex.synchronize do
        state = @burst_state[direction]
        @burst_state[direction] = if state == :good
          rnd < p_good_to_bad ? :bad : :good
        else
          rnd < p_bad_to_good ? :good : :bad
        end
        @burst_state[direction] == :bad
      end
    end

    # Measures runs on the decision, whichever path made it. Measuring inside
    # the Gilbert-Elliott branch left replayed losses uncounted: a TCP arm
    # replaying a bursty HTTP/3 trace reported longest_burst 0 while losing
    # the same 1.5% in the same runs.
    def track_burst(direction, lost)
      @mutex.synchronize do
        if lost
          @burst_run[direction] += 1
          t = @counts[direction]
          t.longest_burst = @burst_run[direction] if @burst_run[direction] > t.longest_burst
        else
          @burst_run[direction] = 0
        end
      end
    end

    def roll?(direction, denominator) = denominator.positive? && rng(direction).rand(denominator).zero?

    def too_large?(_direction, data)
      @config.max_size.positive? && data.bytesize > @config.max_size
    end

    # A token bucket refilled every rate_interval, as smoltcp does it: packets
    # per interval. A policer -- over-budget packets are discarded, so this
    # produces loss, not queueing. See #shape for the shaper.
    def throttled?(_direction)
      return false unless @config.rate.positive?

      @mutex.synchronize do
        t = now
        if t - @refilled_at > @config.rate_interval
          @bucket = @config.rate
          @refilled_at = t
        end
        if @bucket.positive?
          @bucket -= 1
          false
        else
          true
        end
      end
    end

    # A single bit flip, which smoltcp picks as the most likely corruption and
    # the hardest to detect. QUIC authenticates every packet, so the peer
    # discards it: corruption and loss look alike on the wire and differ in
    # whether the sender learns anything.
    def corrupt(direction, data)
      r = rng(direction)
      flipped = data.dup
      index = r.rand(flipped.bytesize)
      flipped.setbyte(index, flipped.getbyte(index) ^ (1 << r.rand(8)))
      bump(direction, :corrupted)
      flipped
    end

    def run_timers
      loop do
        block = @timer_mutex.synchronize do
          return unless @running

          if @timers.empty?
            @timer_wake.wait(@timer_mutex, 0.05)
            next
          end
          wait = @timers.peek_deadline - now
          if wait.positive?
            @timer_wake.wait(@timer_mutex, wait)
            next
          end
          @timers.pop
        end
        next unless block

        begin
          block.call
        rescue IOError, Errno::EBADF, Errno::EPIPE, Errno::ECONNRESET
          nil
        end
      end
    end

    # Binary min-heap on deadline. Sorting the whole array on every insert was
    # O(n log n) per packet under the lock, and it added load-dependent jitter
    # that looked like protocol behaviour.
    class Heap
      def initialize
        @a = []
        @seq = 0
      end

      def empty? = @a.empty?

      def peek_deadline = @a.first[0]

      def push(deadline, block)
        @a << [deadline, @seq += 1, block]
        up(@a.size - 1)
      end

      def pop
        top = @a.first
        last = @a.pop
        unless @a.empty?
          @a[0] = last
          down(0)
        end
        top[2]
      end

      private

      def less(i, j) = (@a[i][0] <=> @a[j][0]).nonzero? || (@a[i][1] <=> @a[j][1])

      def up(i)
        while i.positive?
          parent = (i - 1) / 2
          break if less(parent, i) <= 0

          @a[parent], @a[i] = @a[i], @a[parent]
          i = parent
        end
      end

      def down(i)
        n = @a.size
        loop do
          l = 2 * i + 1
          r = l + 1
          m = i
          m = l if l < n && less(l, m).negative?
          m = r if r < n && less(r, m).negative?
          break if m == i

          @a[m], @a[i] = @a[i], @a[m]
          i = m
        end
      end
    end
  end
end
