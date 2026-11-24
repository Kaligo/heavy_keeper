# EVALSHA spike: results

Date: 2026-11-24. Branch: `chore/evalsha-spike`. Code: `benchmark/`.

Environment: local Redis 7.0.2 on port 6390, Ruby 4.0.4, `redis` 5.4.1, `redis-client` 0.31.0. The dataset is a seeded, synthetic set of 20,000 updates. Each update makes 1 to 3 `add` calls of 1 to 5 items, drawn from Zipf distributions. On average, an update makes 2.55 `add` calls with 3.06 items each.

To run it again:

```sh
redis-server --port 6390 --save '' --appendonly no --daemonize yes
BUNDLE_GEMFILE=benchmark/Gemfile BUNDLE_PATH=$PWD/vendor/bundle bundle install
BUNDLE_GEMFILE=benchmark/Gemfile BUNDLE_PATH=$PWD/vendor/bundle bundle exec ruby benchmark/spike.rb
```

## Summary

All pass criteria pass. The chunk size for `depth: 32` must be much smaller than the first estimate of 50 items.

| Criterion | Target | Result | Status |
|---|---|---|---|
| Round trips for each `add` | 2, and current ≥ 10× more | 2.0, current 67.5 (34×) | Pass |
| p50 at 0.5 ms RTT | ≥ 5× faster | 53.16 ms → 2.49 ms (21×) | Pass |
| Redis CPU for each update | ≤ +50% | 1,392 µs → 247 µs (5.6× less) | Pass |
| Script p99, `depth: 8`, 5 items | < 200 µs | 178 µs | Pass |
| Chunk size for `depth: 32` | p99 ≤ about 1 ms | 10 items = 1.04 ms p99 | About 8 items |
| Lost updates (run D) | Lua 0 | current 81, Lua 0 | Pass |
| Heap integrity (run D) | Lua correct | current wrong, Lua correct | Pass |
| Same results (run E) | identical | identical | Pass |

## Run E: same results

5,000 updates, 12,723 `add` calls, same random numbers for both versions.

- Return values that differ: 0.
- Bucket hash (16,018 entries), sorted set (500) and heap hash (500): identical.
- After `SCRIPT FLUSH`, the next call succeeded through the `EVAL` fallback.

So the Lua port is the same algorithm, and the fingerprints keep full precision. The timing results below compare equal work.

## Run A: single thread

Load phase: 19,000 updates (48,539 calls, 148,619 items) at RTT 0.

| version | round trips / call | round trips / item | p50 | p99 | Redis CPU / update |
|---|---|---|---|---|---|
| current | 67.5 | 22.0 | 2.39 ms | 4.54 ms | 1,392 µs |
| lua | 2.0 | 0.7 | 0.25 ms | 0.62 ms | 247 µs |

The current code makes 22.0 round trips for each item. That is at the top of the 12 to 23 that we estimated.

The Redis CPU time comes from `used_cpu_user` plus `used_cpu_sys`. So it includes the network and parsing work for each command, which `commandstats` does not show. CPUs on other machines are different, so use the ratio, not the absolute values.

Synthetic RTT phase (500 updates for each RTT):

| version | RTT | p50 | p99 | max |
|---|---|---|---|---|
| current | 0.5 ms | 53.16 ms | 96.14 ms | 101.01 ms |
| lua | 0.5 ms | 2.49 ms | 4.36 ms | 7.79 ms |
| current | 1.0 ms | 96.56 ms | 166.09 ms | 178.58 ms |
| lua | 1.0 ms | 4.01 ms | 6.04 ms | 28.18 ms |

`sleep` overshoots on macOS: 0.5 ms gives 0.64 ms, and 1 ms gives 1.26 ms. The measured times are still about 10% to 65% above `round trips × actual sleep + RTT 0 time`. The cause is not known. It affects both versions.

## Run B: 10 threads, 1 shared client, RTT 0.5 ms

| version | add calls | throughput | p50 | p99 | max |
|---|---|---|---|---|---|
| current | 1,539 | 18 calls/s | 56.28 ms | 100.09 ms | 87,620.46 ms |
| lua | 1,539 | 409 calls/s | 2.32 ms | 4.73 ms | 3,759.30 ms |

One shared client in one process can do about 18 `add` calls per second with the current code.

The maximum is about equal to the full run time for both versions. So one thread waited for the client lock for the whole run. The Ruby lock is not fair, and under contention one thread can wait for a very long time. This is a property of a shared client, not of Lua. The Lua version makes it less likely, because the client lock is free more often.

## Run C: script time (`SLOWLOG`, server side)

| settings | items / script | p50 | p99 | max |
|---|---|---|---|---|
| depth 8, top_k 500 | 1 | 32 µs | 67 µs | 81 µs |
| depth 8, top_k 500 | 2 | 56 µs | 101 µs | 112 µs |
| depth 8, top_k 500 | 3 | 79 µs | 126 µs | 136 µs |
| depth 8, top_k 500 | 5 | 127 µs | 178 µs | 186 µs |
| depth 8, top_k 500 | 10 | 239 µs | 325 µs | 333 µs |
| depth 32, top_k 100 | 10 | 916 µs | 1,042 µs | 1,057 µs |
| depth 32, top_k 100 | 50 | 4,853 µs | 5,682 µs | 5,682 µs |
| depth 32, top_k 100 | 100 | 9,258 µs | 11,822 µs | 11,822 µs |

The cost is about 25 µs for each item at `depth: 8`, and about 95 µs for each item at `depth: 32`.

- For `depth: 8` calls of up to 5 items, each script blocks Redis for less than 0.2 ms.
- For `depth: 32` lists, a chunk size of 50 blocks Redis for about 5 to 6 ms for each script. A chunk of about 8 items keeps the p99 below 1 ms. The current code does the same work, but it spreads the work over many short commands, so other clients can run in between.

## Run D: races, 10 processes, separate clients, RTT 0.5 ms

Lost updates: 200 hot items with no bucket collision, `top_k: 1000`, `width: 1_000_000`. Each item was added once, then 10 × 150 calls of 3 items.

| version | items with a lost update | lost increments (bucket) | lost increments (heap) | total increments |
|---|---|---|---|---|
| current | 7 / 200 | 81 | 81 | 4,700 |
| lua | 0 / 200 | 0 | 0 | 4,700 |

Heap integrity: cold flood of unique items, `top_k: 50`, 10 × 150 calls of 3 items.

| version | ZCARD | hash size | in sorted set only | in hash only |
|---|---|---|---|---|
| current | 50 | 89 | 0 | 39 |
| lua | 50 | 50 | 0 | 0 |

The current code shows lost bucket updates, and a sorted set and hash out of step. The hash kept 39 items that are not in the sorted set. `exist?` reads the hash, so these 39 items count as present in the heap. In this run, the sorted set stayed at 50 members. In an earlier run, it grew to 51, past `top_k`. That race depends on timing. The Lua version shows none of these problems.

## Other findings

- `lib/heavy_keeper/top_k.rb` uses `StringIO` but does not require `stringio`. In a plain Ruby 4.0 process, `add` fails with `uninitialized constant StringIO`. RSpec loads it, so the specs did not show this. The spike adds the require in `benchmark/support.rb`. The real change should add `require 'stringio'` to `top_k.rb`.
- The CI uses Redis 5. The spike used Redis 7.0.2. The script uses only commands that Redis 5 has (`ZPOPMIN` was added in 5.0).

## Limits of this spike

- Local machine and synthetic RTT. The synthetic RTT models only latency, not bandwidth or a real network.
- Synthetic dataset, reduced to 20,000 updates.
- Not tested: upgrade from 0.1.6 data, accuracy against the exact top 500, the `redis` 4 gem.

## Suggested next steps

1. Continue with the full build.
2. Use a fixed budget of bucket operations for each script: `max(1, budget / depth)` items. A budget of 256 gives 8 items at `depth: 32`, below 1 ms. A budget of 64 gives 2 items at `depth: 32`, about 0.2 ms.
3. Add `require 'stringio'` to `top_k.rb` in the real change.
