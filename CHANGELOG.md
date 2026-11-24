## [0.2.0] - 2026-11-24

- Run `TopK#increase_by` and `TopK#add` as one Lua script (`EVALSHA`). Each
call now makes 1 `HGETALL` and 1 `EVALSHA`, in place of about 22 round trips
for each item. Each script is atomic, so concurrent writers no longer lose
updates or let the min-heap grow past `top_k`.
- Split calls with more than 256 bucket updates (items x depth) into more than
one script, to limit how long each script blocks Redis.
- The Redis server must allow `EVAL` and `EVALSHA`. Redis 5.0 or later is still
required, as before.
- The Redis data format does not change. Lists written by 0.1.6 keep working.
- Fix `TopK#clear`, `MinHeap#add` and `MinHeap#update` with redis-rb 5. They
called commands on the Redis client inside `multi`, not on the yielded
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
