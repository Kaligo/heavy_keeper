# HeavyKeeper
This gem implements HeavyKeeper algorithm, based on the paper with the same
name: https://www.usenix.org/conference/atc18/presentation/gong

The interface is designed to be similar with ReBloom TopK datastructure (DS)
(https://oss.redis.com/redisbloom/TopK_Commands/).

This is a naive implementation of HeavyKeeper, probably not very optimized.
We use multiple Redis DSs:

- A hash with maximum depth * width items to act as a bucket to store main
counter
- A sorted set with maximum K elements to act as a MinHeap
- A hash with maximum K elements to store more correct counter of the element in MinHeap


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'heavy_keeper'
```

## Usage

You will need to add an initializer to provide some configuration:

```ruby
HeavyKeeper.configure do |config|
  config.cache_prefix = 'cache_prefix'.freeze # currently used as prefix for the redis data structures.
  config.storage = Redis.new # a Redis store, at least version 4.0
end
```

In general, you will only interact with an instance of the `HeavyKeeper::TopK` class.

These are the most relevant instance methods (see code comments for more detail):

`reserve(name, top_k: size, width:, depth:, decay:)` - sets up a Top K list with specified options

`increase_by(name, *items)` - add an array of items to a list

`list(name)` - returns full list of items in Top K list

`clear(name)` - deletes list

`remove(name, item)` - reset the counter of the targeted item in the list

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bundle exec rspec` to run the tests.

To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Kaligo/heavy_keeper.
