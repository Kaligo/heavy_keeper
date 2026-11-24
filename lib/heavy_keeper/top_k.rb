# frozen_string_literal: true

require 'digest'
require 'dry-schema'
require 'securerandom'
require 'stringio'
require 'xxhash'
require_relative 'validations/message'

module HeavyKeeper
  class TopK # rubocop:disable Metrics/ClassLength
    Validator = ::Dry::Schema.Params do
      required(:top_k).filled(:integer, gt?: 0)
      required(:width).filled(:integer, gt?: 0)
      required(:depth).filled(:integer, gt?: 0)
      required(:decay).filled(:decimal, gt?: 0, lteq?: 1)
    end

    INCREASE_BY_SCRIPT = File.read(File.join(__dir__, 'increase_by.lua')).freeze
    INCREASE_BY_SHA = Digest::SHA1.hexdigest(INCREASE_BY_SCRIPT).freeze

    # Redis blocks all other clients while a script runs. Each script handles
    # at most this many bucket updates (items x depth), which keeps one script
    # near 1 ms. Larger calls are split into more than one script.
    MAX_BUCKET_UPDATES_PER_SCRIPT = 256

    # Initiate the controller to create/operate on top-k DS
    #
    # @param storage [Redis] A Redis client to interact with Redis
    #
    # @return [HeavyKeeper::TopK] new instance of the controller
    def initialize(storage: HeavyKeeper.config.storage)
      @storage = storage
      @min_heap = MinHeap.new(storage)
      @bucket = Bucket.new(storage)
    end

    # Complexity O(1)
    # Initialize a TopK in Redis with specified parameters.
    #
    # @param key [String] a key for identifying top-k DS in Redis
    # @param top_k [Integer] number of top elements we want to track
    # @param width [Integer] Size of the bucket to store counter
    # @param depth [Integer] Number of buckets we want to store
    # @param decay [Decimal] decay factor: smaller number means bigger
    #        distinction between mouse-flow and elelphant flow
    #
    # @return OK on success, otherwise raise error
    def reserve(key, options)
      options = validate(options)
      # We need to use Decimal when validating to accept integer
      # number. However, we need to convert to float when save to Redis
      # because redis-rb 5 don't support Decimal type
      options[:decay] = options[:decay].to_f

      storage.mapped_hmset(metadata_key(key), options)
    end

    # Complexity O(k + depth)
    # Add an array of items to a Top-K DS
    #
    # @param key [String] key for identifying top-k DS in Redis
    # @param items [String, String, ...] each value represents an item we want to
    #        store in Top-K
    #
    # @return [Array[Nil, Integer]]
    #         nil if the item is not addded to the list
    #         otherwise, return the current value of item
    def add(key, *items)
      items_and_increments = items.map { |item| [item, 1] }
      increase_by(key, *items_and_increments)
    end

    # Complexity O(k + (increment * depth))
    # Add an array of items to a Top-K DS, with custom increment for each item
    #
    # Uses 1 HGETALL and 1 EVALSHA for each call. The script does all reads and
    # writes of the buckets and the min-heap, so each script is atomic. A call
    # with more than MAX_BUCKET_UPDATES_PER_SCRIPT bucket updates is split into
    # more than one script, and is not atomic as a whole.
    #
    # @param key [String] key for identifying top-k DS in Redis
    # @param items_and_increments [[String, Integer], ...]
    #        each value represents an item and increment that needs to be added
    #        to Top-K. Each increment must be an Integer.
    #
    # @raise [HeavyKeeper::Error] if an increment is not an Integer
    #
    # @return [Array[Nil, Integer]]
    #         nil if the item is not addded to the list
    #         otherwise, return the current value of item
    def increase_by(key, *items_and_increments)
      validate_increments(items_and_increments)
      options = validate(storage.hgetall(metadata_key(key)))
      keys = increase_by_keys(key)
      header = [options[:top_k], options[:depth], options[:decay].to_s('F')]
      items_per_script = [MAX_BUCKET_UPDATES_PER_SCRIPT / options[:depth], 1].max

      items_and_increments.each_slice(items_per_script).flat_map do |slice|
        argv = header + slice.flat_map { |item, increment| increase_by_args(item, increment, options) }
        run_increase_by(keys, argv)
      end
    end

    # Complexity O(k)
    # Checks whether an item is one of Top-K items. Multiple items can be checked at once.
    #
    # @param key [String] a key for identifying top-k DS in Redis
    # @param items [String, String, ...] an array of item that we want to check
    #
    # @return [Array[Boolean]] true if item is in Top-K, otherwise return false
    def query(key, *items)
      items.map do |item|
        min_heap.exist?(key, item)
      end
    end

    # Complexity O(k + depth)
    # Please note this number will never be higher than the real count
    # and likely to be lower. Multiple items can be queried at once.
    #
    # @param key [String] a key for identifying top-k DS in Redis
    # @param items [String, String, ...] an array of item that we want to check
    #
    # @return [Array[Integer]] return the count of each item
    def count(key, *items)
      items.map do |item|
        min_heap.count(key, item)
      end
    end

    # Complexity O(k)
    # Return full list of items in Top K list.
    #
    # @param key [String] a key for identifying top-k DS in Redis
    #
    # @return [Hash] return a hash contains the key and the count of the top-K
    #         elements
    def list(key)
      top_k = storage.hget(metadata_key(key), :top_k).to_i
      min_heap.list(key, top_k)
    end

    # Complexity O(1)
    # Clean up all Redis data related to a key
    #
    # @param key [String] a key for identifying top-k DS in Redis
    #
    # @return OK if successful; otherwise, raise error
    def clear(key)
      storage.multi do |transaction|
        transaction.del(metadata_key(key))
        transaction.del(min_heap.sorted_set_key(key))
        transaction.del(min_heap.hash_key(key))
        transaction.del(bucket.hash_key(key))
      end
    end

    # Complexity O(1)
    # Reset counter of an item to zero in order to decay it out
    #
    # @param key [String] a key for identifying top-k DS in Redis
    # @param items [String] item that we want to decay
    #
    # @return OK if successful, raise error otherwise
    def remove(key, item)
      options = validate(storage.hgetall(metadata_key(key)))
      item_fingerprint = XXhash.xxh64(item)

      options[:depth].times do |i|
        bucket_number = XXhash.xxh64_stream(StringIO.new(item), i) % options[:width]
        fingerprint, _ = bucket.get(key, i, bucket_number)

        bucket.set(key, i, bucket_number, [fingerprint, 0]) if item_fingerprint == fingerprint
      end

      min_heap.delete(key, item)
    end

    private

    attr_reader :storage, :min_heap, :bucket

    # KEYS for increase_by.lua, in the order that the script expects
    def increase_by_keys(key)
      [bucket.hash_key(key), min_heap.sorted_set_key(key), min_heap.hash_key(key)]
    end

    # Arguments for one item: item, fingerprint, increment, then depth bucket
    # columns and depth random numbers. The fingerprint goes as a string,
    # because Lua numbers cannot hold all 64-bit values.
    def increase_by_args(item, increment, options)
      depth = options[:depth]
      columns = Array.new(depth) { |i| XXhash.xxh64_stream(StringIO.new(item), i) % options[:width] }
      randoms = Array.new(depth) { SecureRandom.rand.to_s }

      [item, XXhash.xxh64(item).to_s, increment, *columns, *randoms]
    end

    # The script stores counts as integers, so it would cut a Float increment
    # to an integer. Check all items before any write.
    def validate_increments(items_and_increments)
      items_and_increments.each do |item, increment|
        next if increment.is_a?(Integer)

        raise HeavyKeeper::Error, "Increment for #{item.inspect} must be an integer, got #{increment.inspect}"
      end
    end

    # Redis can lose its script cache, for example after a failover or
    # SCRIPT FLUSH. EVAL runs the full script and loads it into the cache again.
    def run_increase_by(keys, argv)
      storage.evalsha(INCREASE_BY_SHA, keys: keys, argv: argv)
    rescue Redis::CommandError => e
      raise unless e.message.start_with?('NOSCRIPT')

      storage.eval(INCREASE_BY_SCRIPT, keys: keys, argv: argv)
    end

    def metadata_key(key)
      "#{key_prefix}:#{key}:data"
    end

    def key_prefix
      "#{HeavyKeeper.config.cache_prefix}_heavykeeper"
    end

    def validate(options)
      result = Validator.call(options)

      if result.failure?
        error = Validations::Message.new.build(result.errors.to_h).join('. ')
        raise HeavyKeeper::Error, error
      end

      result.output
    end
  end
end
