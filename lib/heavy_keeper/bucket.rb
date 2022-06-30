require 'json'

# Act as 2D array with to store HeavyKeeper counter.
# It's implemented using a hash underneath.
#
# rubocop:disable Naming/MethodParameterName
module HeavyKeeper
  class Bucket
    def initialize(storage = HeavyKeeper::Config.config.storage)
      @storage = storage
    end

    def set(key, i, j, value)
      storage.hset(hash_key(key), "#{i}:#{j}", JSON.generate(value))
    end

    def get(key, i, j)
      value = storage.hget(hash_key(key), "#{i}:#{j}")

      value ? JSON.parse(value) : value
    end

    def clear(key)
      storage.del(hash_key(key))
    end

    private

    attr_reader :storage

    def hash_key(key)
      "#{key_prefix}:hash:#{key}"
    end

    def key_prefix
      "#{HeavyKeeper::Config.config.cache_prefix}_bucket"
    end
  end
end
# rubocop:enable Naming/MethodParameterName
