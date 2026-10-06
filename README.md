# Impair

Network impairment in userspace: a UDP or TCP relay that sits between a client
and a server and damages what passes through. For benchmarking a protocol on a
link with a round trip and some loss, without root or a VM.

```ruby
link = { delay: 0.025, loss: 50, burst: 5, seed: 1234 }

udp = Impair::Udp.start(target_host: "::1", target_port: 4433, **link)
tcp = Impair::Tcp.start(target_host: "::1", target_port: 8443, **link)

# point the clients at udp.port / tcp.port instead of 4433 / 8443

udp.update(loss: 0)        # heal the link mid-run
udp.blackhole(0.5)         # cut it entirely for 500ms
tcp.reset                  # RST every live TCP connection

udp.stop # => counts

# or let the block stop it, raise or not:
counts = Impair::Udp.start(target_host: "::1", target_port: 4433, **link) do |relay|
  run_benchmark(port: relay.port)
end
```

One `Config`, both relays, same units — so "the same link" is actually the
same link. `delay` is one-way seconds. `loss`, `reorder` and `corrupt` are
1-in-N; 0 disables.

| key | what |
|---|---|
| `loss: 50` | drop 1 in 50 |
| `burst: 5` | …in bursts averaging 5 packets. Overall rate stays 1/50 |
| `delay: 0.025` | 25ms one-way. TCP's stall per lost segment is `2 × delay` |
| `jitter: 0.005` | ±5ms uniform on each packet |
| `reorder: 10, reorder_delay: 0.03` | hold 1 in 10 back by 30ms |
| `corrupt: 100` | flip one bit in 1 of 100 (UDP only) |
| `max_size: 1200` | drop anything larger, as a small-MTU path would (UDP only) |
| `rate: 100, rate_interval: 0.1` | **policer**: >100 packets per 100ms are discarded |
| `bandwidth: 1_000_000, queue: 64_000` | **shaper**: 1 MB/s, up to 64 KB queued, then discarded |
| `mss: 1460` | what counts as one segment for TCP's loss decision |
| `congestion: true, rto_min: 0.2` | TCP reacts to a burst with an RTO and window collapse (see below) |
| `seed: 1234` | one RNG per direction; same seed, same run |

Use the shaper to see queueing delay and congestion control; use the policer
to see loss. They are different experiments.

## Counts

`counts` reports what actually happened, per direction and in total, so an
experiment can assert the impairment occurred rather than trust that it did:

```ruby
counts.dropped          # link loss, both directions
counts.client.dropped   # client → server only
counts.loss_rate        # dropped / (forwarded + dropped)
counts.longest_burst
counts.to_s             # "forwarded=19585 dropped=415 (2.07%) longest_burst=12"
```

`dropped` is link loss and nothing else. `oversized`, `throttled`, `overflow`
and `blackholed` are each their own count.

## Before trusting a throughput number

```ruby
relay.verify!(packets_sent)                  # or
relay.verify!(client: sent, server: received)
```

The kernel discards datagrams that arrive while the receive buffer is full,
before the relay sees them. Those thin `forwarded` and `dropped` together, so
`loss_rate` stays pinned at the advertised figure while the real link loses
far more — a relay losing 26% of packets reports a healthy 2.1%. `verify!`
raises if the relay didn't see what you sent, and says whether the kernel
dropped it or the relay's own queue did.

## Trace and replay

```ruby
h3 = Impair::Udp.start(target_host: ..., target_port: ..., loss: 50, burst: 5, trace: true)
# ... run the HTTP/3 benchmark ...
h3.stop

h1 = Impair::Tcp.start(target_host: ..., target_port: ..., replay: h3.trace)
# ... run the HTTP/1 benchmark on the identical loss pattern ...

File.write("h3.csv", h3.trace.to_csv)   # t, direction, seq, action, bytes, wait
```

A seed makes a run repeatable, but two *different* protocols on the same seed
still see different draws: they send different numbers of packets at
different times. `replay:` takes the RNG out of the loss decision. Both arms
lose packet #37 because the trace says so. What remains is the protocol plus
whatever the TCP model below gets wrong, so a replayed comparison is only as
honest as that model, and the model is deliberately conservative. Validate a
headline number against a packet-level setup (netem, dummynet) before
publishing it. When the replay runs out, the configured `loss` takes over;
`counts.replayed` says how many decisions came from the trace.

## Many clients, one link

`Impair::Udp` carries any number of clients. Each source address gets its own
upstream socket, so the server sees one peer per client rather than one
shared port; `counts.connections` is how many. A browser opens six TCP
connections to an origin and one QUIC connection, and the comparison that
matters is six against one, which needs the relay to carry six.

Every flow shares the link. Six connections through a 1-in-50 link each see
1-in-50, and all six queue in the same shaper.

## What the TCP arm can and cannot do

`Impair::Tcp` cannot drop bytes, because TCP's reliability lives below a
userspace relay. It charges what a drop costs instead:

- **An isolated loss** stalls the whole connection for one RTT — fast
  retransmit — and halves the sender's window (RFC 5681 §3.2). The segments
  after it are paced by a window growing one per RTT until it recovers. The
  stall is the head-of-line cost of RFC 9114 §1.1; the halving is most of
  what TCP pays under scattered loss.
- **Three or more in a row** leave no duplicate acks to trigger it, so the
  connection waits out the retransmission timer (`rto_min`, Linux's 200ms
  floor), collapses its window to one segment, and slow-starts back. The
  segments after a burst are paced by the window, not the link.

The second is what makes bursts comparable. QUIC stacks treat a long burst
as persistent congestion and collapse too; without this the TCP arm shrugged
off the exact bursts that cost HTTP/3 a 2-second tail. `congestion: false`
turns it off for a pure HOL measurement.

Not reproduced: SACK, or exponential backoff when the probe after an RTO is
itself lost (a loss pattern cannot say which segment is the probe). So one
RTO per burst, which is the floor of what TCP pays. Still conservative in
TCP's favour, by a bounded amount.

`corrupt`, `reorder`, `max_size` and `rate` are accepted for `Config` parity
and ignored on TCP.

## Development

`bin/setup`, then `rake test`. Tests drive real sockets.
