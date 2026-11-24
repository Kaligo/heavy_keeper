# frozen_string_literal: true

require 'digest'
require 'heavy_keeper'

module Spike
  # Shared helpers for both variants. They reach into private parts of
  # HeavyKeeper, which is acceptable for a spike.
  module Helpers
    private

    def bucket_columns(item, depth, width)
      Array.new(depth) { |i| XXhash.xxh64_stream(StringIO.new(item), i) % width }
    end

    def bucket_hash_key(key)
      bucket.send(:hash_key, key)
    end

    def heap_zset_key(key)
      min_heap.send(:sorted_set_key, key)
    end

    def heap_hash_key(key)
      min_heap.send(:hash_key, key)
    end
  end

  # Prototype: 1 HGETALL + 1 EVALSHA for each chunk of items.
  class TopKLua < HeavyKeeper::TopK
    include Helpers

    SCRIPT = File.read(File.join(__dir__, 'increase_by.lua'))
    SHA = Digest::SHA1.hexdigest(SCRIPT)

    def initialize(storage:, random: Random.new, chunk_size: 50)
      super(storage: storage)
      @random = random
      @chunk_size = chunk_size
    end

    def increase_by(key, *items_and_increments)
      options = validate(storage.hgetall(metadata_key(key)))
      keys = [bucket_hash_key(key), heap_zset_key(key), heap_hash_key(key)]
      head = [options[:top_k], options[:depth], options[:decay].to_s('F')]

      items_and_increments.each_slice(@chunk_size).flat_map do |chunk|
        argv = head + chunk.flat_map { |item, increment| item_args(item, increment, options) }
        run_script(keys, argv)
      end
    end

    private

    def item_args(item, increment, options)
      depth = options[:depth]

      [item, XXhash.xxh64(item).to_s, increment] +
        bucket_columns(item, depth, options[:width]) +
        Array.new(depth) { @random.rand.to_s }
    end

    def run_script(keys, argv)
      storage.evalsha(SHA, keys: keys, argv: argv)
    rescue Redis::CommandError => e
      raise unless e.message.start_with?('NOSCRIPT')

      storage.eval(SCRIPT, keys: keys, argv: argv)
    end
  end

  # Copy of the current TopK#increase_by, with the random source injected the
  # same way as TopKLua: depth numbers for each item, used by row. Only for
  # run E. The timing runs use the real HeavyKeeper::TopK.
  class TopKRef < HeavyKeeper::TopK
    include Helpers

    def initialize(storage:, random: Random.new)
      super(storage: storage)
      @random = random
    end

    def increase_by(key, *items_and_increments)
      options = validate(storage.hgetall(metadata_key(key)))

      items_and_increments.map do |(item, increment)|
        max_count = 0
        item_fingerprint = XXhash.xxh64(item)
        columns = bucket_columns(item, options[:depth], options[:width])
        randoms = Array.new(options[:depth]) { @random.rand }

        exist = min_heap.exist?(key, item)
        min_value = min_heap.min(key)

        options[:depth].times do |i|
          bucket_number = columns[i]
          fingerprint, count = bucket.get(key, i, bucket_number)

          if count.nil? || count.zero?
            bucket.set(key, i, bucket_number, [item_fingerprint, increment])
            max_count = [increment, max_count].max
          elsif fingerprint == item_fingerprint
            if exist || count <= min_value
              bucket.set(key, i, bucket_number, [fingerprint, count + increment])
              max_count = [count + increment, max_count].max
            end
          else
            decay = options[:decay]**count

            if randoms[i] < decay
              count -= increment

              if count.positive?
                bucket.set(key, i, bucket_number, [fingerprint, count])
              else
                bucket.set(key, i, bucket_number, [item_fingerprint, increment])
                max_count = [increment, max_count].max
              end
            end
          end
        end

        if exist
          min_heap.update(key, item, max_count)
        else
          min_heap.add(key, item, max_count, options[:top_k])
        end
      end
    end
  end
end
