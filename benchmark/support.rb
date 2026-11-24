# frozen_string_literal: true

require 'digest'
require 'redis'
require 'stringio'

module Spike
  REDIS_URL = ENV.fetch('SPIKE_REDIS_URL', 'redis://127.0.0.1:6390/0')

  def self.redis
    Redis.new(url: REDIS_URL)
  end

  # redis-client middleware: sleeps for a synthetic RTT once for each round
  # trip, and counts round trips. A MULTI block or pipeline is one round trip.
  module FakeRtt
    class << self
      attr_accessor :rtt
      attr_reader :round_trips

      def reset_count
        @round_trips = 0
      end

      def tick
        @round_trips += 1
        sleep(rtt) if rtt.positive?
      end
    end

    self.rtt = 0.0
    reset_count

    def call(command, config)
      FakeRtt.tick
      super
    end

    def call_pipelined(commands, config)
      FakeRtt.tick
      super
    end
  end
  RedisClient.register(FakeRtt)

  # Seeded, synthetic stream of updates. Each update makes 1 to 3 add calls,
  # and each call has 1 to 5 items. Item i of a call comes from a Zipf
  # distribution over a set 10 times larger than the set for item i - 1, so
  # the first items of a call repeat often and the last items rarely.
  class Dataset
    SET_SIZES = [100, 1_000, 10_000, 100_000, 1_000_000].freeze
    ITEMS_PER_CALL = { 1 => 0.10, 2 => 0.25, 3 => 0.30, 4 => 0.20, 5 => 0.15 }.freeze

    attr_reader :calls_by_update

    def initialize(seed:, updates:, call_presence: 0.85)
      @rng = Random.new(seed)
      @zipfs = SET_SIZES.map { |size| Zipf.new(size, 1.1, @rng) }
      @calls_by_update = Array.new(updates) { update_calls(call_presence) }
    end

    def calls(range = 0...calls_by_update.size)
      calls_by_update[range].flatten(1)
    end

    def self.item(group, position, rank)
      "item:#{Digest::SHA256.hexdigest("#{group}:#{position}:#{rank}")}"
    end

    private

    def update_calls(call_presence)
      groups = (0..2).select { @rng.rand < call_presence }
      groups = [@rng.rand(3)] if groups.empty?

      groups.map do |group|
        Array.new(items_per_call) { |position| self.class.item(group, position, @zipfs[position].sample) }
      end
    end

    def items_per_call
      target = @rng.rand
      ITEMS_PER_CALL.each do |count, weight|
        return count if target < weight

        target -= weight
      end
      ITEMS_PER_CALL.keys.last
    end
  end

  class Zipf
    def initialize(size, exponent, rng)
      @rng = rng
      total = 0.0
      @cumulative = Array.new(size) { |rank| total += 1.0 / ((rank + 1)**exponent) }
      @total = total
    end

    def sample
      target = @rng.rand * @total
      @cumulative.bsearch_index { |value| value >= target } || (@cumulative.size - 1)
    end
  end

  module Stats
    module_function

    def percentile(values, pct)
      return nil if values.empty?

      sorted = values.sort
      sorted[[(pct / 100.0 * sorted.size).ceil - 1, 0].max]
    end

    def ms(seconds)
      seconds && format('%.2f', seconds * 1000)
    end

    def server_cpu(redis)
      info = redis.info('cpu')
      info['used_cpu_user'].to_f + info['used_cpu_sys'].to_f
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
