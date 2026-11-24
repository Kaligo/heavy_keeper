-- HeavyKeeper::TopK#increase_by, run atomically inside Redis.
--
-- Ruby computes the fingerprints, the bucket columns and the random numbers,
-- because Redis Lua has no xxHash and the seed of math.random is fixed on
-- older Redis versions. This script does every read and write of the buckets
-- and the min-heap, so one call is atomic.
--
-- KEYS[1]  bucket hash
-- KEYS[2]  min-heap sorted set
-- KEYS[3]  min-heap hash
--
-- ARGV[1]  top_k
-- ARGV[2]  depth
-- ARGV[3]  decay
-- then, for each item:
--   item, fingerprint, increment,
--   <depth> bucket columns,
--   <depth> random numbers in [0, 1)
--
-- Returns one value for each item: the count, or false (a nil reply) when the
-- item is not in the min-heap after the update.
--
-- xxh64 fingerprints go up to about 1.8e19, but Lua numbers are doubles and
-- are exact only up to 2^53. So fingerprints stay strings of decimal digits.
-- Bucket values are the JSON text "[<fingerprint>,<count>]", which the Ruby
-- code before 0.2.0 also wrote, so they are parsed with a pattern, not cjson.

local bucket_key = KEYS[1]
local heap_zset = KEYS[2]
local heap_hash = KEYS[3]

local top_k = tonumber(ARGV[1])
local depth = tonumber(ARGV[2])
local decay = tonumber(ARGV[3])

local function format_int(n)
  return string.format('%d', n)
end

local function write_bucket(field, fingerprint, count)
  redis.call('HSET', bucket_key, field, '[' .. fingerprint .. ',' .. format_int(count) .. ']')
end

local function read_bucket(field)
  local raw = redis.call('HGET', bucket_key, field)
  if not raw then return nil, nil end

  local fingerprint, count = string.match(raw, '^%[(%d+),(%-?%d+)%]$')
  if not fingerprint then
    error('heavy_keeper: invalid bucket value at ' .. field .. ': ' .. raw)
  end

  return fingerprint, tonumber(count)
end

local function heap_min()
  local member = redis.call('ZRANGE', heap_zset, 0, 0)[1]
  if not member then return 0 end

  return tonumber(redis.call('HGET', heap_hash, member)) or 0
end

-- Same logic as MinHeap#update and MinHeap#add
local function update_heap(item, exist, count)
  local value = format_int(count)

  if exist then
    redis.call('ZADD', heap_zset, value, item)
    redis.call('HSET', heap_hash, item, value)
    return count
  end

  local size = redis.call('ZCARD', heap_zset)
  redis.call('ZADD', heap_zset, value, item)
  redis.call('HSET', heap_hash, item, value)

  if size < top_k then return count end

  local dropped = redis.call('ZPOPMIN', heap_zset)[1]
  redis.call('HDEL', heap_hash, dropped)

  if dropped == item then return false end

  return count
end

local results = {}
local stride = 3 + 2 * depth

for pos = 4, #ARGV, stride do
  local item = ARGV[pos]
  local item_fingerprint = ARGV[pos + 1]
  local increment = tonumber(ARGV[pos + 2])
  local columns_at = pos + 3
  local randoms_at = pos + 3 + depth

  local max_count = 0
  local exist = redis.call('HEXISTS', heap_hash, item) == 1
  local min_value = heap_min()

  for i = 0, depth - 1 do
    local field = i .. ':' .. ARGV[columns_at + i]
    local fingerprint, count = read_bucket(field)

    if count == nil or count == 0 then
      write_bucket(field, item_fingerprint, increment)
      max_count = math.max(max_count, increment)
    elseif fingerprint == item_fingerprint then
      if exist or count <= min_value then
        write_bucket(field, fingerprint, count + increment)
        max_count = math.max(max_count, count + increment)
      end
    elseif tonumber(ARGV[randoms_at + i]) < decay ^ count then
      count = count - increment

      if count > 0 then
        write_bucket(field, fingerprint, count)
      else
        write_bucket(field, item_fingerprint, increment)
        max_count = math.max(max_count, increment)
      end
    end
  end

  results[#results + 1] = update_heap(item, exist, max_count)
end

return results
