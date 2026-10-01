# frozen_string_literal: true

require "test_helper"

# One Config, both relays, same units. The point of the gem is comparing two
# protocols on the same link, which is only true if "the same link" is the
# same object with the same meaning on both sides.
class TestConfig < Minitest::Test
  LINK = { loss: 50, delay: 0.025, seed: 7 }.freeze

  def test_defaults_impair_nothing
    refute_predicate Impair::Config.new, :impairing?
  end

  def test_any_impairment_is_detected
    assert_predicate Impair::Config.new(loss: 50), :impairing?
    assert_predicate Impair::Config.new(delay: 0.01), :impairing?
    assert_predicate Impair::Config.new(reorder: 10), :impairing?
  end

  def test_both_relays_accept_the_same_config
    skip "TODO: Tcp takes rtt/mss instead of Config"
    udp = Impair::Udp.new(target_host: "127.0.0.1", target_port: 1, **LINK)
    tcp = Impair::Tcp.new(target_host: "127.0.0.1", target_port: 1, **LINK)

    assert_equal udp.config, tcp.config
  ensure
    udp&.stop
    tcp&.stop
  end

  # delay is one-way seconds. TCP pays a full round trip per lost segment, so
  # the stall is derived, not configured separately -- two knobs for one
  # quantity is how the arms drift apart.
  def test_rtt_is_derived_from_delay
    skip "TODO: Config#rtt"
    assert_in_delta 0.05, Impair::Config.new(delay: 0.025).rtt, 1e-9
  end

  def test_tcp_accepts_every_udp_key
    skip "TODO: shared Config"
    config = Impair::Config.new(reorder: 10, corrupt: 10, max_size: 1200, jitter: 0.005)
    tcp = Impair::Tcp.new(target_host: "127.0.0.1", target_port: 1, **config.to_h)
    assert tcp
  ensure
    tcp&.stop
  end

  def test_rejects_nonsense
    skip "TODO: Config#validate!"
    assert_raises(ArgumentError) { Impair::Config.new(loss: -1) }
    assert_raises(ArgumentError) { Impair::Config.new(delay: -0.1) }
    assert_raises(ArgumentError) { Impair::Config.new(loss: 1.5) }
    assert_raises(ArgumentError) { Impair::Config.new(burst: 2) } # burst without loss
  end

  # burst is the mean burst length. The overall loss rate must still be
  # 1/loss, or "loss: 50" would mean something different the moment you turn
  # burst on and the two arms stop being comparable.
  def test_burst_preserves_the_overall_loss_rate
    skip "TODO: Gilbert-Elliott"
    config = Impair::Config.new(loss: 50, burst: 5)
    assert_in_delta 0.02, config.loss_rate, 1e-9
  end
end
