# frozen_string_literal: true

module Impair
  # Loss by ordinal rather than by chance. "Drop the client's packets 2 to 7"
  # is how the QUIC interop runner states a handshake-loss case, and it is
  # the form a bug report takes: a specific packet, not a probability.
  #
  #   Impair::Udp.start(..., replay: Impair::Script.drop(client: 2..7))
  #   Impair::Script.drop(client: [1, 3, 5], server: 10..12)
  #
  # Ordinals are 1-based and count lost? decisions in that direction, which
  # is every packet the link admitted. Packets past the last named ordinal
  # fall through to the configured +loss+, as a replayed Trace does when it
  # runs out; set loss: 0 for nothing but the script.
  #
  # A Script is what +replay:+ accepts: anything with a +losses+ hash of
  # booleans per direction. Build one from a Trace's losses to edit a
  # recorded run, or hand-write one to pin a case.
  class Script
    attr_reader :losses

    # +ordinals+ per direction: a Range, an Array of Integers, or one Integer.
    def self.drop(client: [], server: [])
      new(client: expand(client), server: expand(server))
    end

    def self.expand(ordinals)
      list = Array(ordinals).flat_map { |o| o.is_a?(Range) ? o.to_a : [o] }
      list.each do |o|
        raise ArgumentError, "ordinals are 1-based positive integers, got #{o.inspect}" unless o.is_a?(Integer) && o >= 1
      end
      list.uniq.sort
    end
    private_class_method :expand

    # +client+ and +server+ are the sorted ordinals to lose.
    def initialize(client: [], server: [])
      @losses = {
        client: booleans(client),
        server: booleans(server)
      }
    end

    # The ordinals this script loses, per direction, recovered from the
    # booleans so a Trace's losses can be read back in the same terms.
    def dropped(direction)
      @losses.fetch(direction).each_index.select { |i| @losses[direction][i] }.map { |i| i + 1 }
    end

    def to_s
      parts = %i[client server].filter_map do |d|
        list = dropped(d)
        "#{d}: #{summarise(list)}" unless list.empty?
      end
      parts.empty? ? "Script(nothing)" : "Script(#{parts.join(", ")})"
    end

    private

    # A boolean per decision up to the last named ordinal: true at each named
    # position, false between.
    def booleans(ordinals)
      return [] if ordinals.empty?

      Array.new(ordinals.last, false).tap { |list| ordinals.each { |o| list[o - 1] = true } }
    end

    def summarise(list)
      list.slice_when { |a, b| b != a + 1 }.map { |run| run.size > 2 ? "#{run.first}-#{run.last}" : run.join(",") }.join(",")
    end
  end
end
