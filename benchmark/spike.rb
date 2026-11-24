# frozen_string_literal: true

# EVALSHA spike. See tasks/spike-results.md.
#
#   redis-server --port 6390 --save '' --appendonly no --daemonize yes
#   BUNDLE_GEMFILE=benchmark/Gemfile bundle exec ruby benchmark/spike.rb [calibrate a b c d e ...]

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require_relative 'support'
require_relative 'top_k_variants'

module Spike
  DEPTH_8 = { top_k: 500, width: 2048, depth: 8, decay: 0.9 }.freeze
  DEPTH_32 = { top_k: 100, width: 2048, depth: 32, decay: 0.9 }.freeze

  VARIANTS = {
    'current' => ->(redis) { HeavyKeeper::TopK.new(storage: redis) },
    'lua' => ->(redis) { TopKLua.new(storage: redis) }
  }.freeze

  module_function

  def dataset
    @dataset ||= Dataset.new(seed: 1, updates: 20_000)
  end

  def fresh(top_k_class, redis, key, options)
    top_k = top_k_class.respond_to?(:call) ? top_k_class.call(redis) : top_k_class
    top_k.clear(key)
    top_k.reserve(key, options)
    top_k
  end

  # Runs the calls one after the other. Returns latency, round trips and
  # Redis CPU time.
  def replay(top_k, key, calls, redis)
    FakeRtt.reset_count
    cpu_before = Stats.server_cpu(redis)
    FakeRtt.reset_count
    latencies = calls.map do |members|
      started = Stats.monotonic
      top_k.add(key, *members)
      Stats.monotonic - started
    end
    round_trips = FakeRtt.round_trips
    { latencies: latencies, round_trips: round_trips, cpu: Stats.server_cpu(redis) - cpu_before }
  end

  def calibrate
    puts '## Sleep calibration'
    puts
    puts '| target | mean actual | p99 actual |'
    puts '|---|---|---|'
    [0.0005, 0.001].each do |target|
      actual = Array.new(500) do
        started = Stats.monotonic
        sleep(target)
        Stats.monotonic - started
      end
      puts "| #{Stats.ms(target)} ms | #{Stats.ms(actual.sum / actual.size)} ms | #{Stats.ms(Stats.percentile(actual, 99))} ms |"
    end
    puts
  end

  # Run A: round trips, latency at synthetic RTT, Redis CPU time.
  def run_a
    redis = Spike.redis
    load_updates = 0...19_000
    rtt_updates = { 0.0005 => 19_000...19_500, 0.001 => 19_500...20_000 }
    n_updates = load_updates.size

    puts '## Run A: single thread'
    puts
    puts "Load: #{n_updates} updates (#{dataset.calls(load_updates).size} add calls, " \
         "#{dataset.calls(load_updates).sum(&:size)} items) at RTT 0. Settings: #{DEPTH_8}."
    puts
    puts '| version | round trips / call | round trips / item | p50 | p99 | wall time | Redis CPU / update |'
    puts '|---|---|---|---|---|---|---|'

    rtt_rows = []
    VARIANTS.each do |name, factory|
      FakeRtt.rtt = 0.0
      top_k = fresh(factory, redis, "spike_a_#{name}", DEPTH_8)
      calls = dataset.calls(load_updates)
      result = replay(top_k, "spike_a_#{name}", calls, redis)
      lat = result[:latencies]
      puts "| #{name} | #{format('%.1f', result[:round_trips].to_f / calls.size)} " \
           "| #{format('%.1f', result[:round_trips].to_f / calls.sum(&:size))} " \
           "| #{Stats.ms(Stats.percentile(lat, 50))} ms | #{Stats.ms(Stats.percentile(lat, 99))} ms " \
           "| #{format('%.1f', lat.sum)} s | #{format('%.1f', result[:cpu] / n_updates * 1_000_000)} µs |"

      rtt_updates.each do |rtt, range|
        FakeRtt.rtt = rtt
        calls = dataset.calls(range)
        res = replay(top_k, "spike_a_#{name}", calls, redis)
        rtt_rows << [name, rtt, res, calls.size]
      ensure
        FakeRtt.rtt = 0.0
      end
    end

    puts
    puts '| version | RTT | add calls | round trips / call | p50 | p99 | max |'
    puts '|---|---|---|---|---|---|---|'
    rtt_rows.sort_by { |name, rtt| [rtt, name] }.each do |name, rtt, res, n|
      lat = res[:latencies]
      puts "| #{name} | #{Stats.ms(rtt)} ms | #{n} | #{format('%.1f', res[:round_trips].to_f / n)} " \
           "| #{Stats.ms(Stats.percentile(lat, 50))} ms | #{Stats.ms(Stats.percentile(lat, 99))} ms " \
           "| #{Stats.ms(lat.max)} ms |"
    end
    puts
  end

  # Run B: 10 threads share 1 Redis client, like an app with one client for each process.
  def run_b(threads: 10, rtt: 0.0005)
    puts "## Run B: #{threads} threads, 1 shared client, RTT #{Stats.ms(rtt)} ms"
    puts
    puts '| version | add calls | throughput | p50 | p99 | max |'
    puts '|---|---|---|---|---|---|'

    VARIANTS.each do |name, factory|
      redis = Spike.redis
      key = "spike_b_#{name}"
      top_k = fresh(factory, redis, key, DEPTH_8)
      FakeRtt.rtt = 0.0
      replay(top_k, key, dataset.calls(0...5_000), redis)

      queue = Queue.new
      dataset.calls(5_000...5_600).each { |c| queue << c }
      total = queue.size
      queue.close
      latencies = Queue.new

      FakeRtt.rtt = rtt
      started = Stats.monotonic
      Array.new(threads) do
        Thread.new do
          while (members = queue.pop)
            t = Stats.monotonic
            top_k.add(key, *members)
            latencies << (Stats.monotonic - t)
          end
        end
      end.each(&:join)
      elapsed = Stats.monotonic - started
      FakeRtt.rtt = 0.0

      lat = Array.new(latencies.size) { latencies.pop }
      puts "| #{name} | #{total} | #{format('%.0f', total / elapsed)} calls/s " \
           "| #{Stats.ms(Stats.percentile(lat, 50))} ms | #{Stats.ms(Stats.percentile(lat, 99))} ms " \
           "| #{Stats.ms(lat.max)} ms |"
    end
    puts
  end

  # Run C: script time from SLOWLOG.
  def run_c
    redis = Spike.redis
    redis.config(:set, 'slowlog-log-slower-than', '0')
    redis.config(:set, 'slowlog-max-len', '100000')
    members = dataset.calls.flatten
    rng = Random.new(7)

    puts '## Run C: script time (SLOWLOG, server side)'
    puts
    puts '| settings | items / script | scripts | p50 | p99 | max |'
    puts '|---|---|---|---|---|---|'

    [[DEPTH_8, [1, 2, 3, 5, 10]], [DEPTH_32, [10, 50, 100]]].each do |options, sizes|
      key = "spike_c_d#{options[:depth]}"
      top_k = fresh(TopKLua.new(storage: redis, chunk_size: 1_000), redis, key, options)
      dataset.calls(0...3_000).each { |call| top_k.add(key, *call) }

      sizes.each do |size|
        redis.slowlog(:reset)
        n = 300
        n.times { top_k.add(key, *members.sample(size, random: rng)) }
        times = redis.slowlog(:get, 100_000)
          .select { |entry| entry[3].first.casecmp?('evalsha') }
          .map { |entry| entry[2] }
        puts "| depth #{options[:depth]}, top_k #{options[:top_k]} | #{size} | #{times.size} " \
             "| #{Stats.percentile(times, 50)} µs | #{Stats.percentile(times, 99)} µs | #{times.max} µs |"
      end
    end
    puts
  ensure
    redis&.config(:set, 'slowlog-log-slower-than', '10000')
    redis&.config(:set, 'slowlog-max-len', '128')
    redis&.slowlog(:reset)
  end

  # Run D: lost updates and heap integrity under concurrent writers.
  def run_d(workers: 10, rtt: 0.0005)
    puts "## Run D: #{workers} processes, separate clients, RTT #{Stats.ms(rtt)} ms"
    puts
    lost_updates(workers, rtt)
    heap_integrity(workers, rtt)
  end

  def lost_updates(workers, rtt)
    options = { top_k: 1_000, width: 1_000_000, depth: 8, decay: 0.9 }
    hot = dataset.calls.flatten.tally.sort_by { |_, n| -n }.first(200).map(&:first)
    clean = items_without_collisions(hot, options)
    zipf = Zipf.new(clean.size, 1.1, Random.new(3))
    plans = Array.new(workers) { Array.new(150) { Array.new(3) { clean[zipf.sample] } } }
    exact = clean.to_h { |item| [item, 1] }
    plans.flatten.each { |item| exact[item] += 1 }

    puts "Lost updates: #{clean.size} hot items with no bucket collision, top_k #{options[:top_k]}, " \
         "width #{options[:width]}. Each item added once first, then #{workers} × 150 calls of 3 items."
    puts
    puts '| version | items with a lost update | lost increments (bucket) | lost increments (heap) | of total |'
    puts '|---|---|---|---|---|'

    VARIANTS.each do |name, factory|
      redis = Spike.redis
      key = "spike_d_lost_#{name}"
      top_k = fresh(factory, redis, key, options)
      top_k.add(key, *clean)

      run_workers(plans, factory, key, rtt)

      bucket = HeavyKeeper::Bucket.new(redis)
      lost_bucket = 0
      lost_heap = 0
      bad_items = 0
      clean.each do |item|
        columns = Array.new(options[:depth]) { |i| XXhash.xxh64_stream(StringIO.new(item), i) % options[:width] }
        counts = columns.each_with_index.map { |col, i| bucket.get(key, i, col)&.last.to_i }
        heap = HeavyKeeper::MinHeap.new(redis).count(key, item)
        lost_bucket += exact[item] - counts.max
        lost_heap += exact[item] - heap
        bad_items += 1 if counts.max != exact[item] || heap != exact[item]
      end
      total = exact.values.sum
      puts "| #{name} | #{bad_items} / #{clean.size} | #{lost_bucket} | #{lost_heap} | #{total} |"
    end
    puts
  end

  def heap_integrity(workers, rtt)
    options = { top_k: 50, width: 2048, depth: 8, decay: 0.9 }
    rng = Random.new(5)
    plans = Array.new(workers) { Array.new(150) { Array.new(3) { "item:#{rng.bytes(32).unpack1('H*')}" } } }

    puts "Heap integrity: cold flood of unique items, top_k #{options[:top_k]}, #{workers} × 150 calls of 3 items."
    puts
    puts '| version | ZCARD | hash size | in set only | in hash only |'
    puts '|---|---|---|---|---|'

    VARIANTS.each do |name, factory|
      redis = Spike.redis
      key = "spike_d_heap_#{name}"
      fresh(factory, redis, key, options)
      run_workers(plans, factory, key, rtt)

      heap = HeavyKeeper::MinHeap.new(redis)
      zset = redis.zrange(heap.send(:sorted_set_key, key), 0, -1)
      hash = redis.hkeys(heap.send(:hash_key, key))
      puts "| #{name} | #{zset.size} | #{hash.size} | #{(zset - hash).size} | #{(hash - zset).size} |"
    end
    puts
  end

  def run_workers(plans, factory, key, rtt)
    pids = plans.map do |plan|
      fork do
        FakeRtt.rtt = rtt
        top_k = factory.call(Spike.redis)
        plan.each { |items| top_k.add(key, *items) }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }
  end

  def items_without_collisions(items, options)
    columns = items.to_h do |item|
      [item, Array.new(options[:depth]) { |i| XXhash.xxh64_stream(StringIO.new(item), i) % options[:width] }]
    end
    options[:depth].times.each_with_object(items.dup) do |row, kept|
      dupes = columns.values.map { |cols| cols[row] }.tally.select { |_, n| n > 1 }.keys
      kept.reject! { |item| dupes.include?(columns[item][row]) }
    end
  end

  # Run E: the Lua port gives the same results as the Ruby loop.
  def run_e
    redis = Spike.redis
    FakeRtt.rtt = 0.0
    calls = dataset.calls(0...5_000)

    puts '## Run E: same results (5,000 updates, same random numbers)'
    puts

    states = {}
    returns = {}
    { 'ruby' => TopKRef, 'lua' => TopKLua }.each do |name, klass|
      key = "spike_e_#{name}"
      top_k = fresh(klass.new(storage: redis, random: Random.new(42)), redis, key, DEPTH_8)
      returns[name] = calls.map { |members| top_k.add(key, *members) }
      states[name] = dump_state(top_k, redis, key)
    end

    diffs = returns['ruby'].zip(returns['lua']).count { |a, b| a != b }
    puts "- add calls: #{calls.size}, with different return values: #{diffs}"
    %i[buckets zset heap_hash].each do |part|
      same = states['ruby'][part] == states['lua'][part]
      puts "- #{part}: #{states['ruby'][part].size} entries, identical: #{same}"
    end
    puts "- admitted (non-nil) results: #{returns['lua'].flatten.compact.size} of #{returns['lua'].flatten.size}"

    redis.script(:flush)
    key = 'spike_e_lua'
    result = TopKLua.new(storage: redis).add(key, 'after-flush')
    puts "- NOSCRIPT recovery after SCRIPT FLUSH: #{result.inspect}"
    puts
  end

  def dump_state(top_k, redis, key)
    {
      buckets: redis.hgetall(top_k.send(:bucket_hash_key, key)),
      zset: redis.zrange(top_k.send(:heap_zset_key, key), 0, -1, with_scores: true),
      heap_hash: redis.hgetall(top_k.send(:heap_hash_key, key))
    }
  end
end

runs = ARGV.empty? ? %w[calibrate e a b c d] : ARGV
runs.each do |run|
  started = Spike::Stats.monotonic
  run == 'calibrate' ? Spike.calibrate : Spike.public_send("run_#{run}")
  warn "(#{run} took #{format('%.0f', Spike::Stats.monotonic - started)} s)"
  $stdout.flush
end
