require 'dry-configurable'

module HeavyKeeper
  class Config
    extend Dry::Configurable

    setting :app_name, default: 'app_name'
    setting :storage
  end
end
