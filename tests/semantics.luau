-- What ORDER BY, WHERE and the aggregates answer, each compared with a plain loop over the same
-- rows: NULLs, infinities, both zeros, strings, values that do not compare, and every provider
-- shape the engine reads rows through.
local sql = require('@jessql')
local test = require('@jess/test')
local expect = test.expect
local suite = test.new()

local Count = 240
local Labels = { 'iron', 'ebony', 'glass' }
local Extremes = { -math.huge, math.huge, 0, -0, 1.5, -1.5 }
local Columns = { 'id', 'score', 'rank', 'bucket', 'name', 'label', 'mixed', 'extreme' }

-- `score` and `name` are different in every row; `rank` and `label` repeat and are NULL in some;
-- `mixed` is a number in one row and a string in the next; `extreme` is NULL in every seventh.
local Things = {}

for id = 1, Count do
  Things[id] = {
    id = id,
    score = (id * 73) % 241 - 120 + 0.25,
    rank = if id % 6 == 0 then nil else (id * 7) % 11,
    bucket = id % 5,
    name = `n{(id * 37) % 241}`,
    label = if id % 4 == 0 then nil else Labels[id % 3 + 1],
    mixed = if id % 2 == 0 then id else tostring(id),
    extreme = if id % 7 == 0 then nil else Extremes[id % 7],
  }
end

local Owners = {}

for id = 1, 60 do
  Owners[id] = { thing = id * 3, owner = `o{id % 9}`, weight = (id * 5) % 13 }
end

--- A provider that hands `rows` over one at a time, through one reused row when `volatile` and
--- the engine allows it.
local function streamed(rows, columns, volatile)
  return {
    columns = columns,
    iterate = function(request)
      local position = 0
      local reuse = volatile and request.allowVolatileRows == true
      local reused = {}

      return {
        _jessqlIter = 'v1',
        volatileRows = reuse,
        handledConstraints = false,
        handledWhere = false,
        ordered = false,
        next = function()
          position += 1
          local row = rows[position]
          if not row or not reuse then return row end

          for _, column in columns do
            reused[column] = row[column]
          end

          return reused
        end,
      }
    end,
    scan = function(_request) error('a streamed provider is not scanned') end,
  }
end

local function database()
  local db = sql.new()
  db:table('things', Things, Columns)
  db:table('owners', Owners, { 'thing', 'owner', 'weight' })
  db:register('stream', streamed(Things, Columns, false))
  db:register('volatile', streamed(Things, Columns, true))
  return db
end

local function column(name)
  return function(row) return row[name] end
end

--- Whether `left` goes before `right` under ORDER BY `keys`: NULL before every value, and after
--- every value under DESC.
local function before(keys, left, right)
  for _, key in keys do
    local leftKey, rightKey = key.read(left), key.read(right)
    if leftKey == rightKey then continue end
    if leftKey == nil then return not key.desc end
    if rightKey == nil then return key.desc end
    if key.desc then return leftKey > rightKey end

    return leftKey < rightKey
  end

  return false
end

--- The `rows` that `keep` accepts, ordered by `keys` with an insertion sort: rows whose keys are
--- all equal stay in the order they came in.
local function reference(rows, keep, keys)
  local out = {}

  for _, row in rows do
    if keep and not keep(row) then continue end

    local position = #out + 1

    while keys and position > 1 and before(keys, row, out[position - 1]) do
      position -= 1
    end

    table.insert(out, position, row)
  end

  return out
end

--- `rows` as a query selecting `names` returns them.
local function project(rows, names, skip, count)
  local out = {}

  for position = (skip or 0) + 1, math.min(#rows, (skip or 0) + (count or #rows)) do
    local result = {}

    for _, name in names do
      result[name] = rows[position][name]
    end

    table.insert(out, result)
  end

  return out
end

local function ascending(name) return { read = column(name), desc = false } end

local function descending(name) return { read = column(name), desc = true } end

suite.describe('ORDER BY', function()
  suite.it('orders by a number, upwards and downwards', function()
    local db = database()
    local upwards = project(reference(Things, nil, { ascending 'score' }), { 'id', 'score' })
    local downwards = project(reference(Things, nil, { descending 'score' }), { 'id', 'score' })

    for _, source in { 'things', 'stream', 'volatile' } do
      expect(db:query(`SELECT id, score FROM {source} ORDER BY score`).rows).toEqual(upwards)
      expect(db:query(`SELECT id, score FROM {source} ORDER BY score ASC`).rows).toEqual(upwards)
      expect(db:query(`SELECT id, score FROM {source} ORDER BY score DESC`).rows).toEqual(downwards)
    end
  end)

  suite.it('puts NULL first upwards and last downwards', function()
    local db = database()
    local upwards = reference(Things, nil, { ascending 'rank', ascending 'id' })
    local downwards = reference(Things, nil, { descending 'rank', ascending 'id' })

    expect(upwards[1].rank).toBeNil()
    expect(downwards[Count].rank).toBeNil()
    expect(db:query('SELECT id, rank FROM things ORDER BY rank, id').rows).toEqual(project(upwards, { 'id', 'rank' }))
    expect(db:query('SELECT id, rank FROM things ORDER BY rank DESC, id').rows).toEqual(project(downwards, { 'id', 'rank' }))
  end)

  suite.it('orders by several keys, each in its own direction', function()
    local db = database()
    local keys = { descending 'bucket', ascending 'rank', descending 'score' }
    local expected = project(reference(Things, nil, keys), { 'id' })

    for _, source in { 'things', 'stream', 'volatile' } do
      expect(db:query(`SELECT id FROM {source} ORDER BY bucket DESC, rank, score DESC`).rows).toEqual(expected)
    end
  end)

  suite.it('orders NULL, the infinities, and both zeros', function()
    local db = database()
    local upwards = reference(Things, nil, { ascending 'extreme', ascending 'id' })
    local downwards = reference(Things, nil, { descending 'extreme', descending 'id' })

    expect(upwards[1].extreme).toBeNil()
    expect(upwards[Count // 7 + 1].extreme).toBe(-math.huge)
    expect(db:query('SELECT id FROM things ORDER BY extreme, id').rows).toEqual(project(upwards, { 'id' }))
    expect(db:query('SELECT id FROM things ORDER BY extreme DESC, id DESC').rows).toEqual(project(downwards, { 'id' }))
  end)

  suite.it('orders by a string, and by a string that is NULL in some rows', function()
    local db = database()
    local byName = project(reference(Things, nil, { ascending 'name' }), { 'id' })
    local byLabel = project(reference(Things, nil, { descending 'label', ascending 'name' }), { 'id' })

    expect(db:query('SELECT id FROM things ORDER BY name').rows).toEqual(byName)
    expect(db:query('SELECT id FROM things ORDER BY label DESC, name').rows).toEqual(byLabel)
    expect(db:query('SELECT id FROM stream ORDER BY label DESC, name').rows).toEqual(byLabel)
  end)

  suite.it('orders by an expression, and by a SELECT alias', function()
    local db = database()
    local negated = { read = function(row) return row.score * -1 end, desc = false }
    local remainder = { read = function(row) return row.id % 7 end, desc = true }
    local byRemainder = reference(Things, nil, { remainder, ascending 'id' })
    local aliased = {}

    for position, row in byRemainder do
      aliased[position] = { id = row.id, remainder = row.id % 7 }
    end

    expect(db:query('SELECT id FROM things ORDER BY score * -1').rows).toEqual(project(reference(Things, nil, { negated }), { 'id' }))
    expect(db:query('SELECT id, id % 7 AS remainder FROM things ORDER BY remainder DESC, id').rows).toEqual(aliased)
  end)

  suite.it('answers LIMIT and OFFSET with a run of the whole order', function()
    local db = database()
    local byScore = reference(Things, nil, { ascending 'score' })
    local byRank = reference(Things, nil, { descending 'rank', ascending 'score' })
    local byBucket = reference(Things, function(row) return row.rank ~= nil and row.rank >= 3 end, { ascending 'bucket', descending 'score' })
    local pages = { { 7, 0 }, { 7, 13 }, { 1, 0 }, { 50, 20 }, { 50, 220 }, { 500, 0 }, { 0, 3 }, { 240, 0 } }

    for _, source in { 'things', 'stream', 'volatile' } do
      for _, bounds in pages do
        local limit, offset = bounds[1], bounds[2]
        local tail = `LIMIT {limit} OFFSET {offset}`

        expect(db:query(`SELECT id FROM {source} ORDER BY score {tail}`).rows).toEqual(project(byScore, { 'id' }, offset, limit))
        expect(db:query(`SELECT id FROM {source} ORDER BY rank DESC, score {tail}`).rows).toEqual(project(byRank, { 'id' }, offset, limit))

        expect(db:query(`SELECT id FROM {source} WHERE rank >= 3 ORDER BY bucket, score DESC {tail}`).rows).toEqual(
          project(byBucket, { 'id' }, offset, limit)
        )
      end
    end
  end)

  suite.it('keeps every row of a key that repeats, in order of the key', function()
    local db = database()

    for _, text in { 'SELECT id, bucket FROM things ORDER BY bucket', 'SELECT id, bucket FROM things ORDER BY bucket DESC' } do
      local rows = db:query(text).rows
      local seen, total = {}, 0
      local downwards = string.find(text, 'DESC', 1, true) ~= nil

      expect(#rows).toBe(Count)

      for position, row in rows do
        total += row.id
        expect(seen[row.id]).toBeNil()
        seen[row.id] = true
        if position == 1 then continue end

        local previous = rows[position - 1].bucket
        expect(if downwards then previous >= row.bucket else previous <= row.bucket).toBe(true)
      end

      expect(total).toBe(Count * (Count + 1) / 2)
    end
  end)

  suite.it('raises for keys that do not compare with each other', function()
    local db = database()

    expect(function() db:query('SELECT id FROM things ORDER BY mixed') end).toThrow('attempt to compare')
    expect(function() db:query('SELECT id FROM things ORDER BY bucket, mixed') end).toThrow('attempt to compare')
    expect(function() db:query('SELECT id FROM things ORDER BY mixed LIMIT 3') end).toThrow('attempt to compare')
    expect(db:query('SELECT id FROM things WHERE id = 4 ORDER BY mixed').rows).toEqual { { id = 4 } }
  end)

  suite.it('orders joined rows by keys from either side', function()
    local db = database()
    local joined = {}

    for _, owner in Owners do
      local thing = Things[owner.thing]
      table.insert(joined, { id = thing.id, score = thing.score, owner = owner.owner, weight = owner.weight })
    end

    local keys = { descending 'weight', ascending 'owner', ascending 'score' }
    local expected = reference(joined, nil, keys)
    local text = 'SELECT t.id, o.owner FROM things t JOIN owners o ON t.id = o.thing ORDER BY o.weight DESC, o.owner, t.score'

    expect(db:query(text).rows).toEqual(project(expected, { 'id', 'owner' }))
    expect(db:query(`{text} LIMIT 9 OFFSET 4`).rows).toEqual(project(expected, { 'id', 'owner' }, 4, 9))
  end)

  suite.it('orders groups by their aggregates', function()
    local db = database()
    local groups, byBucket = {}, {}

    for _, row in Things do
      local group = byBucket[row.bucket]

      if not group then
        group = { bucket = row.bucket, total = 0, found = 0 }
        byBucket[row.bucket] = group
        table.insert(groups, group)
      end

      group.total += row.score
      group.found += 1
    end

    local expected = reference(groups, nil, { descending 'total' })
    local text = 'SELECT bucket, SUM(score) AS total, COUNT(*) AS found FROM things GROUP BY bucket ORDER BY total DESC'

    expect(db:query(text).rows).toEqual(expected)
    expect(db:query(`{text} LIMIT 2 OFFSET 1`).rows).toEqual { expected[2], expected[3] }
    expect(db:query((string.gsub(text, 'things', 'volatile'))).rows).toEqual(expected)
  end)
end)

--- The ids of the rows of `source` that `text` keeps, and the ids `keep` keeps of `Things`.
local function kept(db, source, text, params, keep)
  local got, wanted = {}, {}

  for _, row in db:query(`SELECT id FROM {source} WHERE {text}`, params).rows do
    table.insert(got, row.id)
  end

  for _, row in Things do
    if keep(row) then table.insert(wanted, row.id) end
  end

  return got, wanted
end

suite.describe('WHERE', function()
  suite.it('compares a number with a literal and with a parameter, and never passes NULL', function()
    local db = database()

    local comparisons = {
      { '=', function(cell, value) return cell == value end },
      { '!=', function(cell, value) return cell ~= value end },
      { '<>', function(cell, value) return cell ~= value end },
      { '<', function(cell, value) return cell < value end },
      { '<=', function(cell, value) return cell <= value end },
      { '>', function(cell, value) return cell > value end },
      { '>=', function(cell, value) return cell >= value end },
    }

    for _, source in { 'things', 'stream', 'volatile' } do
      for _, comparison in comparisons do
        local op, holds = comparison[1], comparison[2]
        local function keep(row) return row.rank ~= nil and holds(row.rank, 4) end

        local got, wanted = kept(db, source, `rank {op} 4`, nil, keep)
        expect(got).toEqual(wanted)

        got, wanted = kept(db, source, `rank {op} ?`, { 4 }, keep)
        expect(got).toEqual(wanted)

        got, wanted = kept(db, source, `4 {op} rank`, nil, function(row) return row.rank ~= nil and holds(4, row.rank) end)
        expect(got).toEqual(wanted)
      end
    end
  end)

  suite.it('joins comparisons with AND, and mixes them with terms that are not comparisons', function()
    local db = database()

    for _, source in { 'things', 'stream' } do
      local got, wanted = kept(db, source, 'rank >= 3 AND score < 40.5 AND bucket != 2', nil, function(row)
        return row.rank ~= nil and row.rank >= 3 and row.score < 40.5 and row.bucket ~= 2
      end)

      expect(got).toEqual(wanted)

      got, wanted = kept(db, source, "score > ? AND name LIKE 'n1%' AND bucket <= ?", { -50, 3 }, function(row)
        return row.score > -50 and string.sub(row.name, 1, 2) == 'n1' and row.bucket <= 3
      end)

      expect(got).toEqual(wanted)

      got, wanted = kept(db, source, 'rank < 2 OR score >= 100', nil, function(row)
        return (row.rank ~= nil and row.rank < 2) or row.score >= 100
      end)

      expect(got).toEqual(wanted)
    end
  end)

  suite.it('keeps no row for a comparison with NULL', function()
    local db = database()

    for _, op in { '=', '!=', '<', '>=' } do
      expect(db:query(`SELECT id FROM things WHERE score {op} NULL`).rows).toEqual {}
      expect(db:query(`SELECT id FROM things WHERE bucket = 1 AND score {op} NULL`).rows).toEqual {}
    end
  end)

  suite.it('compares with both zeros, the infinities, and a parameter that is not a number', function()
    local db = database()
    local notNumber = 0 / 0

    local got, wanted = kept(db, 'things', 'extreme = 0', nil, function(row) return row.extreme == 0 end)
    expect(got).toEqual(wanted)
    expect(#got).toBe(2 * (Count // 7))

    got, wanted = kept(db, 'things', 'extreme > ?', { -math.huge }, function(row) return row.extreme ~= nil and row.extreme > -math.huge end)
    expect(got).toEqual(wanted)

    got, wanted = kept(db, 'things', 'extreme <= ?', { -math.huge }, function(row) return row.extreme == -math.huge end)
    expect(got).toEqual(wanted)

    got = kept(db, 'things', 'score >= ?', { notNumber }, function(_row) return false end)
    expect(got).toEqual {}

    got, wanted = kept(db, 'things', 'extreme != ?', { notNumber }, function(row) return row.extreme ~= nil end)
    expect(got).toEqual(wanted)
  end)

  suite.it('tests equality across types, and raises for an ordering across them', function()
    local db = database()

    local got, wanted = kept(db, 'things', 'mixed = 4', nil, function(row) return row.id == 4 end)
    expect(got).toEqual(wanted)

    got, wanted = kept(db, 'things', 'mixed != 4', nil, function(row) return row.id ~= 4 end)
    expect(got).toEqual(wanted)

    got, wanted = kept(db, 'things', "mixed = '5' AND bucket = 0", nil, function(row) return row.id == 5 end)
    expect(got).toEqual(wanted)

    expect(function() db:query('SELECT id FROM things WHERE mixed > 3') end).toThrow('attempt to compare')
    expect(function() db:query('SELECT id FROM things WHERE bucket >= 0 AND mixed > 3') end).toThrow('attempt to compare')
    expect(function() db:query('SELECT COUNT(*) AS found FROM things WHERE mixed > 3') end).toThrow('attempt to compare')
  end)

  suite.it('leaves a comparison alone once an earlier one has failed', function()
    local db = database()

    expect(db:query('SELECT id FROM things WHERE id < 0 AND mixed > 3').rows).toEqual {}
    expect(db:query('SELECT id FROM things WHERE id = 2 AND mixed > 1').rows).toEqual { { id = 2 } }
    expect(function() db:query('SELECT id FROM things WHERE id = 1 AND mixed > 1') end).toThrow('attempt to compare')
  end)

  suite.it('goes on to the next comparison after one that is NULL', function()
    local db = database()
    local text = 'SELECT id FROM things WHERE extreme > ? AND mixed > 3'

    expect(function() db:query(text, { math.huge }) end).toThrow('attempt to compare')
    expect(db:query('SELECT id FROM things WHERE extreme > ? AND bucket > 3', { math.huge }).rows).toEqual {}
  end)

  suite.it('filters each side of a join before joining', function()
    local db = database()
    local wanted = {}

    for _, owner in Owners do
      local thing = Things[owner.thing]

      if owner.weight >= 6 and thing.rank ~= nil and thing.rank < 8 and thing.bucket ~= 0 then
        table.insert(wanted, { id = thing.id, owner = owner.owner })
      end
    end

    local text = [[SELECT t.id, o.owner FROM owners o JOIN things t ON t.id = o.thing
      WHERE o.weight >= ? AND t.rank < 8 AND t.bucket <> 0]]

    expect(db:query(text, { 6 }).rows).toEqual(wanted)

    expect(function()
      db:query('SELECT t.id FROM owners o JOIN things t ON t.id = o.thing WHERE t.mixed < 9')
    end).toThrow('attempt to compare')
  end)
end)

suite.describe('aggregates', function()
  suite.it('count, add, average, and find the least and the greatest, skipping NULL', function()
    local db = database()

    local text = [[SELECT COUNT(*) AS found, COUNT(rank) AS ranked, SUM(rank) AS total, AVG(rank) AS mean,
      MIN(rank) AS least, MAX(rank) AS greatest, SUM(score) AS scores, AVG(score) AS middle,
      MIN(score) AS lowest, MAX(score) AS highest, MIN(extreme) AS floor, MAX(extreme) AS ceiling
      FROM %s WHERE %s]]

    local filters = {
      { 'id > 0', function(_row) return true end },
      { 'bucket < 3', function(row) return row.bucket < 3 end },
      { 'score >= 0.25 AND rank != 5', function(row) return row.score >= 0.25 and row.rank ~= nil and row.rank ~= 5 end },
      { "label = 'iron'", function(row) return row.label == 'iron' end },
    }

    for _, source in { 'things', 'stream', 'volatile' } do
      for _, filter in filters do
        local wanted = { found = 0, ranked = 0 }
        local total, scores = 0, 0

        for _, row in Things do
          if not filter[2](row) then continue end

          wanted.found += 1
          scores += row.score
          wanted.lowest = math.min(wanted.lowest or row.score, row.score)
          wanted.highest = math.max(wanted.highest or row.score, row.score)

          if row.extreme ~= nil then
            wanted.floor = math.min(wanted.floor or row.extreme, row.extreme)
            wanted.ceiling = math.max(wanted.ceiling or row.extreme, row.extreme)
          end

          if row.rank == nil then continue end

          wanted.ranked += 1
          total += row.rank
          wanted.least = math.min(wanted.least or row.rank, row.rank)
          wanted.greatest = math.max(wanted.greatest or row.rank, row.rank)
        end

        wanted.total, wanted.mean = total, total / wanted.ranked
        wanted.scores, wanted.middle = scores, scores / wanted.found
        expect(db:query(string.format(text, source, filter[1])).rows).toEqual { wanted }
      end
    end
  end)

  suite.it('answer NULL over no rows, and COUNT answers zero', function()
    local db = database()
    local text = 'SELECT COUNT(*) AS found, COUNT(rank) AS ranked, SUM(rank) AS total, AVG(rank) AS mean, MIN(rank) AS least, MAX(rank) AS greatest FROM %s WHERE %s'

    for _, source in { 'things', 'stream' } do
      expect(db:query(string.format(text, source, 'score > 1000')).rows).toEqual { { found = 0, ranked = 0 } }
      expect(db:query(string.format(text, source, 'id % 6 = 0 AND id < 20')).rows).toEqual { { found = 3, ranked = 0 } }
    end
  end)

  suite.it('work over strings and expressions, and raise for a sum that cannot be added', function()
    local db = database()
    local least, greatest, doubled = Things[1].name, Things[1].name, 0

    for _, row in Things do
      if row.name < least then least = row.name end
      if row.name > greatest then greatest = row.name end
      doubled += row.score * 2
    end

    local text = 'SELECT MIN(name) AS least, MAX(name) AS greatest, SUM(score * 2) AS doubled FROM things'

    expect(db:query(text).rows).toEqual { { least = least, greatest = greatest, doubled = doubled } }
    expect(function() db:query('SELECT SUM(name) AS total FROM things') end).toThrow('attempt to perform arithmetic')
    expect(function() db:query('SELECT MIN(mixed) AS least FROM things') end).toThrow('attempt to compare')
    -- Luau adds a string that reads as a number, so the engine does too.
    expect(db:query('SELECT SUM(mixed) AS total FROM things').rows).toEqual { { total = Count * (Count + 1) / 2 } }
    expect(db:query('SELECT AVG(mixed) AS mean FROM things WHERE id < 3').rows).toEqual { { mean = 1.5 } }
    expect(db:query('SELECT COUNT(mixed) AS found FROM things').rows).toEqual { { found = Count } }
  end)

  suite.it('add in the order the rows come in', function()
    local db = sql.new()
    local rows, total = {}, 0

    for index = 1, 500 do
      rows[index] = { value = 1 / index + (if index % 2 == 0 then 1e15 else -1e15) }
      total += rows[index].value
    end

    db:table('series', rows, { 'value' })
    expect(db:query('SELECT SUM(value) AS total FROM series').rows[1].total).toBe(total)
    expect(db:query('SELECT AVG(value) AS mean FROM series WHERE value > -1e16').rows[1].mean).toBe(total / 500)
  end)
end)

return suite
