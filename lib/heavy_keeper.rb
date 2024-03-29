# frozen_string_literal: true

require_relative 'heavy_keeper/version'
require_relative 'heavy_keeper/top_k'
require_relative 'heavy_keeper/min_heap'
require_relative 'heavy_keeper/bucket'

module HeavyKeeper
  class Error < StandardError; end

  extend Dry::Configurable

  setting :cache_prefix, default: 'cache_prefix'
  setting :storage
end
