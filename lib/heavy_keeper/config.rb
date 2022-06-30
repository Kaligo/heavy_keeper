require 'dry-configurable'

module HeavyKeeper
  class Config
    extend Dry::Configurable

    setting :cache_prefix, default: 'cache_prefix'
    setting :storage
  end
end
