# frozen_string_literal: true

require 'dry-schema'
require 'securerandom'
require 'xxhash'
require_relative '../validations/message'

module HeavyKeeper
  class TopK # rubocop:disable Metrics/ClassLength
    Validator = ::Dry::Schema.Params do
      required(:top_k).filled(:integer, gt?: 0)
      required(:width).filled(:integer, gt?: 0)
      required(:depth).filled(:integer, gt?: 0)
      required(:decay).filled(:decimal, gt?: 0, lteq?: 1)
    end

    # Initiate the controller to create/operate on top-k DS
    #
    # @param storage [Redis] A Redis client to interact with Redis
    #
    # @return [HeavyKeeper::TopK] new instance of the controller
    def initialize(storage: HeavyKeeper::Config.config.storage)
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
    # @param key [String] key for identifying top-k DS in Redis
    # @param items_and_increments [[String, Integer], ...]
    #        each value represents an item and increment that needs to be added
    #        to Top-K
    #
    # @return [Array[Nil, String]]
    #         nil if the item is not addded to the list
    #         otherwise, return the current value of item
    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/BlockLength
    # rubocop:disable Metrics/PerceivedComplexity
    def increase_by(key, *items_and_increments)
      options = validate(storage.hgetall(metadata_key(key)))

      items_and_increments.map do |(item, increment)|
        max_count = 0
        item_fingerprint = XXhash.xxh64(item)

        exist = min_heap.exist?(key, item)
        min_value = min_heap.min(key)

        options[:depth].times do |i|
          bucket_number = XXhash.xxh64_stream(StringIO.new(item), i) % options[:width]

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

            if SecureRandom.rand < decay
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
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/BlockLength
    # rubocop:enable Metrics/PerceivedComplexity

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
      storage.multi do
        storage.del(metadata_key(key))
        min_heap.clear(key)
        bucket.clear(key)
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

    def metadata_key(key)
      "#{key_prefix}:#{key}:data"
    end

    def key_prefix
      "#{HeavyKeeper::Config.config.cache_prefix}_heavy_keeper"
    end

    def validate(options)
      result = Validator.call(options)

      if result.failure?
        error = ::Validations::Message.new.build(result.errors.to_h).join('. ')
        raise HeavyKeeper::Error, error
      end

      result.output
    end
  end
end
