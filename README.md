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

Two things to know before trusting a number:

- `Impair::Tcp` cannot drop bytes, because TCP's reliability lives below a
  userspace relay. It stalls the stream for one RTT per lost segment instead,
  which reproduces the head-of-line stall a receiver sees (RFC 9114 1.1) but
  not congestion window collapse, SACK, or retransmit behaviour. Conservative
  in TCP's favour.
- `seed` is only a guarantee in one direction. Both directions draw from one
  RNG, so return traffic interleaving changes the order of draws.

## Development

`bin/setup`, then `rake test`. Tests drive real sockets.
