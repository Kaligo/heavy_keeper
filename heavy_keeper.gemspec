# frozen_string_literal: true

require_relative 'lib/heavy_keeper/version'

Gem::Specification.new do |spec|
  spec.name = 'heavy_keeper'
  spec.version = HeavyKeeper::VERSION
  spec.authors = ['Hieu Nguyen', 'Kenneth Teh']

  spec.summary = 'Gem which implements HeavyKeeper algorithm'
  spec.homepage = 'https://github.com/Kaligo/heavy_keeper'
  spec.required_ruby_version = '>= 2.7.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/Kaligo/heavy_keeper'
  spec.metadata['changelog_uri'] = 'https://github.com/Kaligo/heavy_keeper/blob/master/CHANGELOG.md'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'dry-configurable', '>= 0.13.0'
  spec.add_dependency 'dry-schema', '~> 1'
  spec.add_dependency 'redis'
  spec.add_dependency 'xxhash'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
