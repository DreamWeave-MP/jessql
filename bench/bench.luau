-- JessQL, timed from Luau through its public API: ordering, bounded ordering, filters, aggregates,
-- grouping, joins, streamed providers, and preparing a statement. Every workload returns a
-- checksum of its result, and the checksum is compared with one worked out from the fixture by a
-- plain loop, so a broken fast path cannot post a time. Run by
-- `jess run --package . bench/bench.luau [filter]`, on a release build.
local sql = require('@jessql')

-- A build without the verified toolchain runs Luau slower than a release does, so a number from
-- one says nothing about what ships.
if not jess.bench.verified then
  error('jessql bench: this jess was built without the verified toolchain: measure on a release build', 0)
end

local filter = ...
local only = if filter and filter ~= '' then filter else nil
local RecordCount, JoinCount, SmallCount = 100000, 50000, 400
local timings = {}

local function median(samples)
  table.sort(samples)
  return samples[(#samples + 1) // 2]
end

--- Seconds per call of `body`: warmed up, then the median of seven batches of a size that takes
--- about a tenth of a second, with a full collection between batches.
local function measure(body)
  jess.bench.collect()
  body()
  local start = os.clock()
  body()
  local once = math.max(os.clock() - start, 1e-7)
  local iterations = math.max(1, math.floor(0.1 / once))
  local samples = {}

  for batch = 1, 7 do
    jess.bench.collect()
    start = os.clock()
    for _ = 1, iterations do body() end
    samples[batch] = (os.clock() - start) / iterations
  end

  return median(samples)
end

--- Times `body`, which must return `expected` before it is timed and after.
local function workload(name, body, expected)
  if only and not string.find(name, only, 1, true) then return end

  local got = body()
  if got ~= expected then error(`jessql bench: {name} returned {got}, not {expected}`, 0) end

  local seconds = measure(body)
  got = body()
  if got ~= expected then error(`jessql bench: {name} returned {got} after timing, not {expected}`, 0) end

  table.insert(timings, { name = name, seconds = seconds })
end

--- The sum of each position times the number `read` finds there, and the length: the same for
--- any two orders of `rows` that differ only in where equal numbers stand.
local function weigh(rows, read)
  local total = #rows

  for position, row in rows do
    total += position * read(row)
  end

  return total
end

local function readId(row) return row.id end

local function readValue(row) return row.value end

local function readScore(row) return row.score end

--- A copy of the `rows` that `keep` accepts, in the order `before` gives when there is one.
local function reference(rows, keep, before)
  local out = [for row in rows if not keep or keep(row) => row]
  if before then table.sort(out, before) end

  return out
end

--- The `count` rows of `rows` after the first `skip`.
local function page(rows, skip, count)
  local first, last = skip + 1, skip + count
  return rows[first:last]
end

-- `score` is different in every row, `value` and `bucket` repeat, and `rank` is NULL in every
-- tenth row.
local records = table.create(RecordCount)

for id = 1, RecordCount do
  records[id] = {
    id = id,
    kind = if id % 7 == 0 then 'WEAP' elseif id % 5 == 0 then 'ARMO' else 'MISC',
    name = `L{id}`,
    value = (id * 7919) % 10000,
    bucket = id % 64,
    score = (id * 7919) % 100003 + 0.5,
    rank = if id % 10 == 0 then nil else (id * 31) % 1000,
  }
end

local leftRows, rightRows = table.create(JoinCount), table.create(JoinCount)

for id = 1, JoinCount do
  leftRows[id] = { id = id, name = `L{id}`, bucket = id % 16 }
  rightRows[id] = { id = id, value = (id * 17) % 10000 }
end

local smallRows = table.create(SmallCount)

for id = 1, SmallCount do
  smallRows[id] = { id = id, value = (id * 37) % 101 }
end

--- A provider that hands `rows` over one at a time, through one reused row when the engine
--- allows it, the way a packed store does.
local function streamed(rows, columns)
  return {
    columns = columns,
    iterate = function(request)
      local position = 0
      local volatile = request.allowVolatileRows == true
      local reused = {}

      return {
        _jessqlIter = 'v1',
        volatileRows = volatile,
        handledConstraints = false,
        handledWhere = false,
        ordered = false,
        next = function()
          position += 1
          local row = rows[position]
          if not row or not volatile then return row end

          for _, column in columns do
            reused[column] = row[column]
          end

          return reused
        end,
      }
    end,
    scan = function(_request) return rows end,
  }
end

--- A provider that finds its rows by `id` and is never scanned.
local function indexed(rows, columns)
  return {
    columns = columns,
    indexes = { id = true },
    lookup = function(_column, id, _request)
      local row = rows[id]
      return if row then { row } else {}
    end,
    scan = function(_request) error('jessql bench: the indexed side is not scanned') end,
  }
end

local RecordColumns = { 'id', 'kind', 'name', 'value', 'bucket', 'score', 'rank' }
local db = sql.new()
db:table('records', records, RecordColumns)
db:table('left_rows', leftRows, { 'id', 'name', 'bucket' })
db:table('right_rows', rightRows, { 'id', 'value' })
db:table('small', smallRows, { 'id', 'value' })
db:register('stream', streamed(records, RecordColumns))
db:register('driver', streamed(leftRows, { 'id', 'name', 'bucket' }))
db:register('looked_up', indexed(rightRows, { 'id', 'value' }))

--- Times `text` run with `params`, its rows reduced by `check`.
local function query(name, text, params, check, expected)
  local plan = db:prepare(text)
  workload(name, function() return check(plan.run(params).rows) end, expected)
end

local function byScore(left, right) return left.score < right.score end

local function byScoreDescending(left, right) return left.score > right.score end

local function atLeast(threshold)
  return function(row) return row.value >= threshold end
end

do
  local ordered = reference(records, nil, byScore)
  local expected = weigh(ordered, readId)
  local function check(rows) return weigh(rows, readId) end

  query('order by a number, 100k rows', 'SELECT id, score FROM records ORDER BY score', nil, check, expected)

  query(
    'order by a number descending, 100k rows',
    'SELECT id, score FROM records ORDER BY score DESC',
    nil,
    check,
    weigh(reference(records, nil, byScoreDescending), readId)
  )

  query(
    'order by a number with ties, 100k rows',
    'SELECT id, value FROM records ORDER BY value',
    nil,
    function(rows) return weigh(rows, readValue) end,
    weigh(reference(records, nil, function(left, right) return left.value < right.value end), readValue)
  )

  query(
    'order by two numbers, 100k rows',
    'SELECT id FROM records ORDER BY bucket DESC, score',
    nil,
    check,
    weigh(
      reference(records, nil, function(left, right)
        if left.bucket ~= right.bucket then return left.bucket > right.bucket end

        return left.score < right.score
      end),
      readId
    )
  )

  query(
    'order by two numbers that repeat together, 100k rows',
    'SELECT id, value FROM records ORDER BY bucket, value DESC',
    nil,
    function(rows) return weigh(rows, readValue) end,
    weigh(
      reference(records, nil, function(left, right)
        if left.bucket ~= right.bucket then return left.bucket < right.bucket end

        return left.value > right.value
      end),
      readValue
    )
  )

  query(
    'order by a nullable number, 100k rows',
    'SELECT id FROM records ORDER BY rank, id',
    nil,
    check,
    weigh(
      reference(records, nil, function(left, right)
        local leftRank, rightRank = left.rank or -1, right.rank or -1
        if leftRank ~= rightRank then return leftRank < rightRank end

        return left.id < right.id
      end),
      readId
    )
  )

  query(
    'order by a string, 100k rows',
    'SELECT id FROM records ORDER BY name',
    nil,
    check,
    weigh(reference(records, nil, function(left, right) return left.name < right.name end), readId)
  )

  query(
    'filter then order by a number, 100k rows',
    'SELECT id FROM records WHERE value >= ? ORDER BY score DESC',
    { 2500 },
    check,
    weigh(reference(records, atLeast(2500), byScoreDescending), readId)
  )

  query(
    'top 20 of 100k by a number',
    'SELECT id, score FROM records WHERE value >= 100 ORDER BY score DESC LIMIT 20',
    nil,
    check,
    weigh(page(reference(records, atLeast(100), byScoreDescending), 0, 20), readId)
  )

  query(
    'top 20 of 100k by two numbers',
    'SELECT id FROM records ORDER BY bucket, score DESC LIMIT 20',
    nil,
    check,
    weigh(
      page(
        reference(records, nil, function(left, right)
          if left.bucket ~= right.bucket then return left.bucket < right.bucket end

          return left.score > right.score
        end),
        0,
        20
      ),
      readId
    )
  )

  query(
    '50 rows after 5,000 of 100k by a number',
    'SELECT id FROM records ORDER BY score LIMIT 50 OFFSET 5000',
    nil,
    check,
    weigh(page(ordered, 5000, 50), readId)
  )
end

do
  local function check(rows) return weigh(rows, readId) end

  query(
    'filter on two numbers, 100k rows',
    'SELECT id FROM records WHERE value >= ? AND bucket < ?',
    { 2500, 32 },
    check,
    weigh(reference(records, function(row) return row.value >= 2500 and row.bucket < 32 end), readId)
  )

  query(
    'filter on a nullable number, 100k rows',
    'SELECT id FROM records WHERE rank < 100',
    nil,
    check,
    weigh(reference(records, function(row) return row.rank ~= nil and row.rank < 100 end), readId)
  )

  query(
    'filter on a string, 100k rows',
    "SELECT id FROM records WHERE kind = 'WEAP'",
    nil,
    check,
    weigh(reference(records, function(row) return row.kind == 'WEAP' end), readId)
  )

  query(
    'filter on a LIKE prefix, 100k rows',
    "SELECT id FROM records WHERE name LIKE 'L12%'",
    nil,
    check,
    weigh(reference(records, function(row) return string.sub(row.name, 1, 3) == 'L12' end), readId)
  )

  query(
    'filter on an expression, 100k rows',
    'SELECT id FROM records WHERE value % 7 = 0 OR bucket = 3',
    nil,
    check,
    weigh(reference(records, function(row) return row.value % 7 == 0 or row.bucket == 3 end), readId)
  )

  query(
    'project three columns, 100k rows',
    'SELECT id, name, value FROM records',
    nil,
    function(rows) return weigh(rows, readValue) end,
    weigh(records, readValue)
  )

  local function readRank(row) return row.rank or -1 end

  query(
    'project three columns, one NULL in every tenth row, 100k rows',
    'SELECT id, rank, value FROM records',
    nil,
    function(rows) return weigh(rows, readRank) end,
    weigh(records, readRank)
  )
end

do
  local kept, total, scoreTotal, ranked = 0, 0, 0, 0
  local low, high = math.huge, -math.huge

  for _, row in records do
    if row.bucket >= 48 then continue end

    kept += 1
    total += row.value
    scoreTotal += row.score
    low, high = math.min(low, row.score), math.max(high, row.score)
    if row.rank ~= nil then ranked += 1 end
  end

  query(
    'count the rows a filter keeps, 100k rows',
    'SELECT COUNT(*) AS found FROM records WHERE bucket < ?',
    { 48 },
    function(rows) return rows[1].found end,
    kept
  )

  query(
    'six aggregates over a filter, 100k rows',
    [[SELECT COUNT(*) AS found, SUM(value) AS total, AVG(score) AS mean, MIN(score) AS low,
      MAX(score) AS high, COUNT(rank) AS ranked FROM records WHERE bucket < 48]],
    nil,
    function(rows)
      local {found, total, mean, low, high, ranked} = rows[1]
      return found + total + mean + low + high + ranked
    end,
    kept + total + scoreTotal / kept + low + high + ranked
  )

  local smallTotal, smallLow, smallHigh = 0, math.huge, -math.huge

  for _, row in smallRows do
    smallTotal += row.value
    smallLow, smallHigh = math.min(smallLow, row.value), math.max(smallHigh, row.value)
  end

  query(
    'four aggregates, 400 rows',
    'SELECT COUNT(*) AS found, SUM(value) AS total, MIN(value) AS low, MAX(value) AS high FROM small',
    nil,
    function(rows)
      local {found, total, low, high} = rows[1]
      return found + total + low + high
    end,
    SmallCount + smallTotal + smallLow + smallHigh
  )

  local streamedTotal, streamedCount = 0, 0

  for _, row in records do
    if row.value < 2500 then continue end

    streamedCount += 1
    streamedTotal += row.value
  end

  query(
    'two aggregates over a streamed filter, 100k rows',
    'SELECT COUNT(*) AS found, SUM(value) AS total FROM stream WHERE value >= ?',
    { 2500 },
    function(rows) return rows[1].found + rows[1].total end,
    streamedCount + streamedTotal
  )
end

do
  local groups, bucketTotals = {}, {}

  for _, row in records do
    bucketTotals[row.bucket] = (bucketTotals[row.bucket] or 0) + row.value
    if row.value < 2500 then continue end

    local key = `{row.kind}:{row.bucket}`
    local group = groups[key]

    if not group then
      group = { found = 0, total = 0 }
      groups[key] = group
    end

    group.found += 1
    group.total += row.value
  end

  local totals = {}

  for _, group in groups do
    if group.found >= 10 then table.insert(totals, group.total) end
  end

  table.sort(totals, function(left, right) return left > right end)
  local expected = 0

  for position = 1, math.min(25, #totals) do
    expected += position * totals[position]
  end

  query(
    'group by two columns, 100k rows',
    [[SELECT kind, bucket, count(*) AS found, sum(value) AS total, avg(value) AS mean
      FROM records WHERE value >= ? GROUP BY kind, bucket HAVING count(*) >= 10
      ORDER BY total DESC LIMIT 25]],
    { 2500 },
    function(rows) return sum[for position, row in enumerate(rows) => position * row.total] end,
    expected
  )

  local bucketExpected = 0

  for bucket = 0, 63 do
    bucketExpected += (bucket + 1) * bucketTotals[bucket]
  end

  local function check(rows) return sum[for position, row in enumerate(rows) => position * row.total] end

  local text = 'SELECT bucket, COUNT(*) AS found, SUM(value) AS total FROM %s GROUP BY bucket ORDER BY bucket'
  query('group by one column, 100k rows', string.format(text, 'records'), nil, check, bucketExpected)
  query('group by one column, 100k streamed rows', string.format(text, 'stream'), nil, check, bucketExpected)

  query(
    'top 20 of 100k streamed rows by a number',
    'SELECT id FROM stream ORDER BY score DESC LIMIT 20',
    nil,
    function(rows) return weigh(rows, readId) end,
    weigh(page(reference(records, nil, byScoreDescending), 0, 20), readId)
  )
end

do
  local joined = reference(rightRows, atLeast(9000), function(left, right)
    if left.value ~= right.value then return left.value > right.value end

    return left.id < right.id
  end)

  query(
    'hash join 50k to 50k, filtered, top 10',
    [[SELECT l.id, l.name, r.value FROM left_rows l JOIN right_rows r ON l.id = r.id
      WHERE r.value >= ? ORDER BY r.value DESC, l.id LIMIT 10]],
    { 9000 },
    function(rows) return weigh(rows, readId) end,
    weigh(page(joined, 0, 10), readId)
  )

  query(
    'hash join 50k to 50k, filtered, every row',
    'SELECT l.id, r.value FROM left_rows l JOIN right_rows r ON l.id = r.id WHERE r.value >= ?',
    { 5000 },
    function(rows) return weigh(rows, readValue) end,
    weigh(reference(rightRows, atLeast(5000)), readValue)
  )

  local bucketCounts = table.create(16, 0)

  for _, row in leftRows do
    if rightRows[row.id].value < 5000 then bucketCounts[row.bucket + 1] += 1 end
  end

  local grouped = 0

  for bucket, count in bucketCounts do
    grouped += bucket * count
  end

  query(
    'left join 50k to 50k, grouped',
    [[SELECT l.bucket, COUNT(r.id) AS found FROM left_rows l LEFT JOIN right_rows r ON l.id = r.id
      WHERE r.value < 5000 GROUP BY l.bucket ORDER BY l.bucket]],
    nil,
    function(rows) return sum[for position, row in enumerate(rows) => position * row.found] end,
    grouped
  )

  local pairs = 0

  for _, left in smallRows do
    for _, right in smallRows do
      if left.value < right.value then pairs += 1 end
    end
  end

  query(
    'nested-loop join 400 to 400, counted',
    'SELECT COUNT(*) AS found FROM small a JOIN small b ON a.value < b.value',
    nil,
    function(rows) return rows[1].found end,
    pairs
  )

  query(
    'indexed join from a streamed driver, 50k rows',
    'SELECT d.id, v.value FROM driver d JOIN looked_up v ON d.id = v.id WHERE v.value >= 5000',
    nil,
    function(rows) return weigh(rows, readValue) end,
    weigh(reference(rightRows, atLeast(5000)), readValue)
  )
end

do
  local text = [[SELECT r.kind, r.bucket, COUNT(*) AS found, SUM(r.value) AS total, AVG(r.score) AS mean
    FROM records r LEFT JOIN left_rows l ON r.id = l.id
    WHERE r.value >= ? AND l.name LIKE 'L1%' AND (r.bucket <> 7 OR r.rank IS NOT NULL)
    GROUP BY r.kind, r.bucket HAVING COUNT(*) >= 10 AND SUM(r.value) > 0
    ORDER BY total DESC, r.kind, r.bucket LIMIT 25 OFFSET 5 -- a statement of every clause]]

  workload('prepare a statement of every clause', function() return db:prepare(text).parameterCount end, 1)
  workload('parse a statement of every clause', function() return #sql.parse(text).select end, 5)
end

for _, timing in timings do
  print(`{timing.name}\t{timing.seconds}`)
end

return timings
