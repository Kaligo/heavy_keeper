# A min-heap implementation in Redis.
# This class is not supposed to use outside of the HeavyKeeper implementation
# for TopK. The writes to the min-heap are in increase_by.lua.
# It uses the following datastructure in Redis:
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

    def exist?(key, item)
      storage.hexists(hash_key(key), item)
    end

    def delete(key, item)
      storage.zrem(sorted_set_key(key), item)
      storage.hdel(hash_key(key), item)
    end

    def sorted_set_key(key)
      "#{key_prefix}:sorted_set:#{key}"
    end

    def hash_key(key)
      "#{key_prefix}:hash:#{key}"
    end

    private

    attr_reader :storage

    def key_prefix
      "#{HeavyKeeper.config.cache_prefix}_min_heap"
    end
  end
end
