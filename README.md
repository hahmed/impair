# Impair

Network impairment in userspace: a UDP or TCP relay that sits between a client
and a server and damages what passes through. For benchmarking a protocol on a
link with a round trip and some loss, without root or a VM.

```ruby
relay = Impair::Udp.new(
  target_host: "::1", target_port: 4433,
  delay: 0.025, loss: 50, seed: 1234
).start

# point the client at relay.port instead of 4433
relay.stop # => counts
```

`loss` and `reorder` are 1-in-N; 0 disables. `delay` is one-way seconds.
`counts` reports what actually happened (`forwarded`, `dropped`,
`loss_rate`, ...) so an experiment can assert the impairment occurred rather
than trust that it did.

Before trusting a throughput number, check the relay saw everything:

```ruby
relay.verify!(packets_you_sent) # raises if the relay was outrun
```

The kernel discards datagrams that arrive while the receive buffer is full,
before the relay sees them. Those thin `forwarded` and `dropped` together, so
`loss_rate` stays pinned at the advertised figure while the real link loses far
more — a relay losing 26% of packets reports a healthy 2.1%. "Counts every
decision" is only a guarantee for decisions the relay was handed, so `verify!`
checks the rest.

Three things to know before trusting a number:

- `Impair::Tcp` cannot drop bytes, because TCP's reliability lives below a
  userspace relay. It stalls the stream for one RTT per lost segment instead,
  which reproduces the head-of-line stall a receiver sees (RFC 9114 1.1) but
  not congestion window collapse, SACK, or retransmit behaviour. Conservative
  in TCP's favour.
- Each direction has its own RNG, so a run is reproducible. Interleaving never
  biased the loss *rate* — every draw is 1-in-N regardless of order — but it
  did make a run unrepeatable, which is worse for a benchmark.
- `rate` is a policer, not a shaper: over-budget packets are discarded rather
  than queued, so it produces loss, not queueing delay. Don't use it to measure
  bufferbloat or congestion control.

## Development

`bin/setup`, then `rake test`. Tests drive real sockets.
