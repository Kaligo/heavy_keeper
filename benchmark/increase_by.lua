-- Spike port of HeavyKeeper::TopK#increase_by.
--
-- KEYS[1] bucket hash
-- KEYS[2] min-heap sorted set
-- KEYS[3] min-heap hash
--
-- ARGV: top_k, depth, decay, then for each item:
--   item, fingerprint (decimal string), increment,
--   depth bucket columns, depth random numbers in [0, 1)
--
-- Fingerprints are xxh64 values up to ~1.8e19. Lua numbers are doubles, so
-- fingerprints stay strings and are never converted to numbers.

local bucket_key = KEYS[1]
local heap_zset = KEYS[2]
local heap_hash = KEYS[3]

local top_k = tonumber(ARGV[1])
local depth = tonumber(ARGV[2])
local decay = tonumber(ARGV[3])

local stride = 3 + 2 * depth
local results = {}

local function fmt_int(n)
  return string.format('%d', n)
end

local function write_bucket(field, fingerprint, count)
  redis.call('HSET', bucket_key, field, '[' .. fingerprint .. ',' .. fmt_int(count) .. ']')
end

local function heap_min()
  local member = redis.call('ZRANGE', heap_zset, 0, 0)[1]
  if not member then return 0 end
  return tonumber(redis.call('HGET', heap_hash, member)) or 0
end

local pos = 4
while pos <= #ARGV do
  local item = ARGV[pos]
  local item_fingerprint = ARGV[pos + 1]
  local increment = tonumber(ARGV[pos + 2])
  local columns_at = pos + 3
  local randoms_at = pos + 3 + depth
  pos = pos + stride

  local max_count = 0
  local exist = redis.call('HEXISTS', heap_hash, item) == 1
  local min_value = heap_min()

  for i = 0, depth - 1 do
    local field = i .. ':' .. ARGV[columns_at + i]
    local raw = redis.call('HGET', bucket_key, field)
    local fingerprint, count

    if raw then
      local fp, c = string.match(raw, '^%[(%d+),(%-?%d+)%]$')
      if not fp then
        return redis.error_reply('heavy_keeper: bad bucket value ' .. field .. '=' .. raw)
      end
      fingerprint, count = fp, tonumber(c)
    end

    if count == nil or count == 0 then
      write_bucket(field, item_fingerprint, increment)
      if increment > max_count then max_count = increment end
    elseif fingerprint == item_fingerprint then
      if exist or count <= min_value then
        write_bucket(field, fingerprint, count + increment)
        if count + increment > max_count then max_count = count + increment end
      end
    else
      if tonumber(ARGV[randoms_at + i]) < decay ^ count then
        count = count - increment

        if count > 0 then
          write_bucket(field, fingerprint, count)
        else
          write_bucket(field, item_fingerprint, increment)
          if increment > max_count then max_count = increment end
        end
      end
    end
  end

  local value = fmt_int(max_count)

  if exist then
    -- MinHeap#update
    redis.call('ZADD', heap_zset, value, item)
    redis.call('HSET', heap_hash, item, value)
    results[#results + 1] = max_count
  else
    -- MinHeap#add
    local size = redis.call('ZCARD', heap_zset)
    redis.call('ZADD', heap_zset, value, item)
    redis.call('HSET', heap_hash, item, value)

    if size >= top_k then
      local dropped = redis.call('ZPOPMIN', heap_zset)[1]
      redis.call('HDEL', heap_hash, dropped)

      if dropped ~= item then
        results[#results + 1] = max_count
      else
        results[#results + 1] = false
      end
    else
      results[#results + 1] = max_count
    end
  end
end

return results
