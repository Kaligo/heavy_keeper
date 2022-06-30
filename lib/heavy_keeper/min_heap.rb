# A min-heap implementation in Redis.
# This class is not supposed to use outside of the HeavyKeeper implementation
# for TopK. It uses the following datastructure in Redis:
# - A sorted set with size K to store the min heap
# - A hash with size K to store counter for each item in min heap
#
module HeavyKeeper
  class MinHeap
    def initialize(storage = HeavyKeeper.config.storage)
      @storage = storage
    end

    def list(key, total)
      items = storage.zrevrange(sorted_set_key(key), 0, total - 1)

      if items.empty?
        {}
      else
        storage.mapped_hmget(hash_key(key), *items)
      end
    end

    def count(key, item)
      storage.hget(hash_key(key), item).to_i
    end

    def min(key)
      item = storage.zrangebyscore(sorted_set_key(key), - Float::INFINITY, Float::INFINITY, limit: [0, 1]).first
      count(key, item)
    end

    def exist?(key, item)
      storage.hexists(hash_key(key), item)
    end

    def add(key, item, value, top_k)
      count = storage.zcard(sorted_set_key(key))

      storage.multi do
        storage.zadd(sorted_set_key(key), value, item)
        storage.hset(hash_key(key), item, value)
      end

      if count >= top_k
        dropped_item, _ = storage.zpopmin(sorted_set_key(key))
        storage.hdel(hash_key(key), dropped_item)

        if dropped_item != item
          value
        end
      else
        value
      end
    end

    def update(key, item, value)
      storage.multi do
        storage.zrem(sorted_set_key(key), item)
        storage.zincrby(sorted_set_key(key), value, item)
        storage.hset(hash_key(key), item, value)
      end

      value
    end

    def clear(key)
      storage.del(sorted_set_key(key))
      storage.del(hash_key(key))
    end

    def delete(key, item)
      storage.zrem(sorted_set_key(key), item)
      storage.hdel(hash_key(key), item)
    end

    private

    attr_reader :storage

    def sorted_set_key(key)
      "#{key_prefix}:sorted_set:#{key}"
    end

    def hash_key(key)
      "#{key_prefix}:hash:#{key}"
    end

    def key_prefix
      "#{HeavyKeeper.config.cache_prefix}_heavy_keeper"
    end
  end
end
