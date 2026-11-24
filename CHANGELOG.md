## [0.2.0] - 2026-11-24

- Run `TopK#increase_by` and `TopK#add` as one Lua script using `EVALSHA`.
    - Each call now makes 1 `HGETALL` and 1 `EVALSHA`, instead of 20+ round trips per item.
    - Calls with >256 bucket updates are split into multiple script calls,  to limit
      how long each script blocks Redis.
    - The Redis server must allow `EVAL` and `EVALSHA`. Redis 5.0 or later is still
      required, as before.
    - Note that EVALSHA is not supported by MockRedis, so this could be a breaking change for CI.
- Fix `TopK#clear`, `MinHeap#add` and `MinHeap#update` when using redis-rb v5.
  They called commands on the Redis client inside `multi`, not on the yielded
  transaction. redis-rb 5 then sends them as separate commands, with no
  `MULTI` or `EXEC`.

## [0.1.6] - 2025-02-04

- Move `Validations::Message` to inside HeavyKeeper namespace to avoid
conflict

## [0.1.5] - 2024-06-13

- Support latest version of xx-hash

## [0.1.4] - 2022-11-19

- Support redis-rb 5.x

## [0.1.3] - 2022-07-01
- Actually fix key typos with specs

## [0.1.2] - 2022-07-01
- Fix key typos

## [0.1.1] - 2022-06-30
- Move config up to HeavyKeeper namespace to save some redundant typing

## [0.1.0] - 2022-06-29

- Initial release
