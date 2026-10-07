## [Unreleased]

### Added

- `Impair.relay_class(kind)` and `Impair.relay(kind, ...)`, mapping a transport
  or protocol name (`:udp`, `:tcp`, `"HTTP/3"`, `"HTTP/2"`, `"HTTP/1.1"`) to the
  relay that carries it. Benchmarks comparing an HTTP/3 arm against TCP arms
  were each writing their own conditional; the comparison is only valid if both
  arms are on the same link, so the choice belongs here rather than in three
  callers. `relay` forwards to `Relay.start`, block form included.

## [0.1.0] - 2026-09-30

- Initial release
