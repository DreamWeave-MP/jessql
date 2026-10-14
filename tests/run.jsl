local sql = require('@jessql')
local test = require('@jess/test')
local expect = test.expect
local suite = test.new()

local function streamingDb()
  local db = sql.new()
  db:register('numbers', {
    columns = { 'id', 'bucket', 'value' },
    iterate = function(_request)
      local id = 0
      return {
        _jessqlIter = 'v1',
        handledConstraints = false,
        handledWhere = false,
        ordered = false,
        next = function()
          id += 1
          if id > 1000 then return nil end
          return { id = id, bucket = id % 10, value = (id * 17) % 997 }
        end,
      }
    end,
    scan = function(_request)
      error('direct single-source query should use iterate')
    end,
  })
  return db
end

suite.describe('streaming single-source providers', function()
  suite.it('aggregates without materializing provider scans', function()
    local result = streamingDb():query('SELECT COUNT(*) AS n, SUM(id) AS total FROM numbers')
    expect(result.rows[1].n).toBe(1000)
    expect(result.rows[1].total).toBe(500500)
  end)

  suite.it('applies residual WHERE predicates', function()
    local result = streamingDb():query('SELECT COUNT(*) AS n FROM numbers WHERE id >= 901')
    expect(result.rows[1].n).toBe(100)
  end)

  suite.it('groups streamed rows correctly', function()
    local result = streamingDb():query('SELECT bucket, COUNT(*) AS n FROM numbers GROUP BY bucket ORDER BY bucket')
    expect(#result.rows).toBe(10)
    for _, row in result.rows do expect(row.n).toBe(100) end
  end)

  suite.it('runs top-k ordering over streamed rows', function()
    local result = streamingDb():query('SELECT id, value FROM numbers ORDER BY value DESC, id ASC LIMIT 5')
    expect(#result.rows).toBe(5)
    for index = 2, #result.rows do
      local previous = result.rows[index - 1]
      local current = result.rows[index]
      expect(previous.value >= current.value).toBeTruthy()
    end
  end)

  suite.it('honors offset and limit while streaming', function()
    local result = streamingDb():query('SELECT id FROM numbers LIMIT 5 OFFSET 10')
    expect(#result.rows).toBe(5)
    expect(result.rows[1].id).toBe(11)
    expect(result.rows[5].id).toBe(15)
  end)
end)

local function volatileDb()
  local db = sql.new()
  db:register('volatile_numbers', {
    columns = { 'id', 'bucket', 'value' },
    iterate = function(request)
      local index = 0
      local row = {}
      return {
        _jessqlIter = 'v1',
        handledConstraints = false,
        handledWhere = false,
        ordered = false,
        volatileRows = request.allowVolatileRows == true,
        next = function()
          index += 1
          if index > 1000 then return nil end
          row.id = index
          row.bucket = index % 10
          row.value = (index * 17) % 997
          return row
        end,
      }
    end,
    scan = function(_request)
      error('volatile single-source query should use iterate')
    end,
  })
  return db
end


suite.describe('compact aggregate groups', function()
  suite.it('does not retain first-row contexts when the grouped column is the only non-aggregate value', function()
    local db = streamingDb()
    local plan = db:prepare('SELECT bucket, COUNT(*) AS n FROM numbers GROUP BY bucket ORDER BY n DESC, bucket ASC LIMIT 3')
    expect(plan.explain().compactGroup).toBe(true)
    local result = plan.run()
    expect(#result.rows).toBe(3)
    expect(result.rows[1].bucket).toBe(0)
    expect(result.rows[1].n).toBe(100)
  end)

  suite.it('preserves permissive first-row semantics when a non-grouped column is projected', function()
    local db = streamingDb()
    local plan = db:prepare('SELECT bucket, value, COUNT(*) AS n FROM numbers GROUP BY bucket ORDER BY bucket LIMIT 1')
    expect(plan.explain().compactGroup).toBe(false)
    local result = plan.run()
    expect(#result.rows).toBe(1)
    expect(result.rows[1].bucket).toBe(0)
    expect(result.rows[1].value).toBe((10 * 17) % 997)
    expect(result.rows[1].n).toBe(100)
  end)
end)

suite.describe('volatile streaming rows', function()
  suite.it('clones group representatives instead of retaining the reused provider row', function()
    local result = volatileDb():query('SELECT bucket, COUNT(*) AS n FROM volatile_numbers GROUP BY bucket ORDER BY bucket')
    expect(#result.rows).toBe(10)
    for bucket = 0, 9 do
      expect(result.rows[bucket + 1].bucket).toBe(bucket)
      expect(result.rows[bucket + 1].n).toBe(100)
    end
  end)

  suite.it('retains distinct rows for direct limited projections', function()
    local result = volatileDb():query('SELECT id, value FROM volatile_numbers LIMIT 5')
    expect(#result.rows).toBe(5)
    for index = 1, 5 do expect(result.rows[index].id).toBe(index) end
  end)

  suite.it('retains distinct rows in bounded top-k ordering', function()
    local result = volatileDb():query('SELECT id, value FROM volatile_numbers ORDER BY value DESC, id ASC LIMIT 5')
    expect(#result.rows).toBe(5)
    for index = 2, #result.rows do
      local previous = result.rows[index - 1]
      local current = result.rows[index]
      expect(previous.value >= current.value).toBeTruthy()
      expect(previous.id ~= current.id).toBeTruthy()
    end
  end)
end)

suite.describe('direct LIMIT safety', function()
  suite.it('does not bound provider iteration before a residual WHERE predicate is evaluated', function()
    local db = sql.new()
    local seenHint = 'unset'
    db:register('limited_numbers', {
      columns = { 'id' },
      iterate = function(request)
        seenHint = request.limitHint
        local index = 0
        local providerLimit = request.limitHint or 1000
        return {
          _jessqlIter = 'v1',
          handledConstraints = false,
          handledWhere = false,
          ordered = false,
          next = function()
            index += 1
            if index > providerLimit then return nil end
            return { id = index }
          end,
        }
      end,
      scan = function(_request) error('direct query should use iterate') end,
    })
    local result = db:query('SELECT id FROM limited_numbers WHERE id >= 901 LIMIT 5')
    expect(seenHint).toBe(nil)
    expect(#result.rows).toBe(5)
    expect(result.rows[1].id).toBe(901)
    expect(result.rows[5].id).toBe(905)
  end)
end)

suite.describe('indexed join driver selection', function()
  suite.it('drives from the more constrained side when both join keys are indexed', function()
    local db = sql.new()
    local leftRows = { { id = 1, kind = 'hot' }, { id = 2, kind = 'cold' } }
    local rightRows = { { id = 1, value = 10 }, { id = 2, value = 20 } }
    local function provider(rows)
      return {
        columns = { 'id', 'kind', 'value' },
        indexes = { id = true },
        lookup = function(_column, id, _request)
          for _, row in rows do if row.id == id then return { row } end end
          return {}
        end,
        iterate = function(_request)
          local index = 0
          return {
            _jessqlIter = 'v1', handledConstraints = false, handledWhere = false, ordered = false,
            next = function()
              index += 1
              return rows[index]
            end,
          }
        end,
        scan = function(_request) return rows end,
      }
    end
    db:register('left_rows', provider(leftRows))
    db:register('right_rows', provider(rightRows))
    local plan = db:prepare([[SELECT l.id, r.value
      FROM left_rows l INNER JOIN right_rows r ON l.id = r.id
      WHERE l.kind = 'hot']])
    expect(plan.explain().joins[1].strategy).toBe('index-right')
    local result = plan.run()
    expect(#result.rows).toBe(1)
    expect(result.rows[1].value).toBe(10)
  end)
end)

suite.describe('indexed lookup bounds', function()
  suite.it('passes the remaining LIMIT budget to an indexed lookup when no residual filter can reject rows', function()
    local db = sql.new()
    db:table('lookup_keys', { { id = 7 } }, { 'id' })
    local seenHint = nil
    db:register('lookup_values', {
      columns = { 'key', 'value' },
      indexes = { key = true },
      lookup = function(_column, key, request)
        seenHint = request.limitHint
        local rows = {}
        local count = request.limitHint or 100
        for index = 1, count do rows[index] = { key = key, value = index } end
        return rows
      end,
      scan = function(_request)
        error('indexed side should not be scanned')
      end,
    })
    local result = db:query('SELECT v.value FROM lookup_keys k INNER JOIN lookup_values v ON k.id = v.key LIMIT 3')
    expect(#result.rows).toBe(3)
    expect(seenHint).toBe(3)
  end)
end)


suite.describe('compact grouped indexed joins', function()
  suite.it('groups by the indexed-side key without retaining every joined context', function()
    local db = sql.new()
    db:register('symbols', {
      columns = { 'id', 'target' },
      indexes = { id = true },
      lookup = function(_column, id, _request)
        return { { id = id, target = if id == 1 then 'hot' else 'cold' } }
      end,
      scan = function(_request) error('indexed symbol side should not be scanned') end,
    })

    db:register('members', {
      columns = { 'symbol_id' },
      iterate = function(_request)
        local index = 0
        return {
          _jessqlIter = 'v1', handledConstraints = false, handledWhere = false, ordered = false,
          next = function()
            index += 1
            if index > 1000 then return nil end
            return { symbol_id = if index <= 900 then 1 else 2 }
          end,
        }
      end,
      scan = function(_request) error('member driver should stream') end,
    })

    local result = db:query([[SELECT s.target, COUNT(*) AS n
      FROM members m INNER JOIN symbols s ON m.symbol_id = s.id
      GROUP BY s.target ORDER BY n DESC LIMIT 1]])
    expect(#result.rows).toBe(1)
    expect(result.rows[1].target).toBe('hot')
    expect(result.rows[1].n).toBe(900)
  end)
end)

suite.describe('streaming indexed joins', function()
  suite.it('streams indexed aggregate joins instead of materializing joined contexts', function()
    local db = sql.new()
    db:register('join_values', {
      columns = { 'key', 'value' },
      indexes = { key = true },
      lookup = function(_column, key, _request)
        return {
          { key = key, value = key * 10 + 1 },
          { key = key, value = key * 10 + 2 },
          { key = key, value = key * 10 + 3 },
        }
      end,
      scan = function(_request) error('indexed side should not be scanned') end,
    })

    db:register('join_keys', {
      columns = { 'id', 'bucket' },
      iterate = function(_request)
        local id = 0
        return {
          _jessqlIter = 'v1', handledConstraints = false, handledWhere = false, ordered = false,
          next = function()
            id += 1
            if id > 1000 then return nil end
            return { id = id, bucket = id % 10 }
          end,
        }
      end,
      scan = function(_request) error('indexed aggregate driver should stream') end,
    })

    local result = db:query([[SELECT k.bucket, COUNT(*) AS n
      FROM join_values v INNER JOIN join_keys k ON v.key = k.id
      GROUP BY k.bucket ORDER BY k.bucket]])
    expect(#result.rows).toBe(10)
    for _, row in result.rows do expect(row.n).toBe(300) end
  end)
end)

suite.describe('exact provider cardinality', function()
  suite.it('answers trivial COUNT(*) without scanning the provider', function()
    local db = sql.new()
    local scanned = false
    db:register('catalog', {
      columns = { 'id' },
      count = function() return 123456789 end,
      scan = function(_request) scanned = true; error('exact count should not scan') end,
    })
    local plan = db:prepare('SELECT COUNT(*) AS n FROM catalog')
    expect(plan:explain().providerCount).toBe(true)
    expect(plan:run().rows[1].n).toBe(123456789)
    expect(scanned).toBe(false)
  end)

  suite.it('does not use exact cardinality when SQL semantics need rows', function()
    local db = sql.new()
    local rows = { { id = 1 }, { id = 2 }, { id = 3 } }
    local countCalls = 0
    db:register('catalog', {
      columns = { 'id' },
      count = function() countCalls += 1; return #rows end,
      scan = function(_request) return rows end,
    })
    expect(db:query('SELECT COUNT(*) AS n FROM catalog WHERE id >= 2').rows[1].n).toBe(2)
    expect(countCalls).toBe(0)
  end)

  suite.it('gives db:table exact cardinality automatically', function()
    local db = sql.new()
    db:table('items', { { id = 1 }, { id = 2 }, { id = 3 }, { id = 4 } }, { 'id' })
    expect(db:query('SELECT COUNT(*) AS n FROM items').rows[1].n).toBe(4)
  end)
end)

-- Twelve rows in three buckets of four, every `value` different, and labels that give bucket 0
-- two rows and bucket 2 none: joining the two both multiplies rows and drops them.
local NumberColumns, LabelColumns = { 'id', 'bucket', 'value' }, { 'bucket', 'label' }
local Numbers = {}

for id = 1, 12 do
  Numbers[id] = { id = id, bucket = (id - 1) // 4, value = (id * 7) % 12 }
end

local Labels = {
  { bucket = 0, label = 'none' },
  { bucket = 0, label = 'zero' },
  { bucket = 1, label = 'one' },
}

local Comparisons = { ['='] = true, ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true }

--- A provider that never stops early: what every bounded one is compared with.
local function unbounded(rows, columns)
  return { columns = columns, scan = function(_request) return rows end }
end

--- A provider that hands over the first `request.limit` rows and reads nothing else of the
--- request. `seen`, when given, collects the requests it was handed.
local function stopsAtLimit(rows, columns, seen)
  return {
    columns = columns,
    scan = function(request)
      if seen then table.insert(seen, request) end

      local out = {}

      for index = 1, math.min(#rows, request.limit or #rows) do
        out[index] = rows[index]
      end

      return out
    end,
  }
end

local function holds(row, constraint)
  local cell, value = row[constraint.column], constraint.value
  if constraint.op == '=' then return cell == value end
  if constraint.op == '<' then return cell < value end
  if constraint.op == '<=' then return cell <= value end
  if constraint.op == '>' then return cell > value end

  return cell >= value
end

--- A provider bounded the way dreamwind-sql's and openmw-workbench's are: it stops at
--- `request.limitHint or request.limit`, and only when it took the whole WHERE itself and either
--- no order was asked of it or it produced the one asked. `handles.where` makes it apply the
--- pushed comparisons; `handles.order` makes it sort by a single requested column.
local function stopsAtHint(rows, columns, handles)
  return {
    columns = columns,
    scan = function(request)
      local candidates = rows
      local handledConstraints = #request.constraints == 0

      if handles.where and not handledConstraints then
        handledConstraints = true

        for _, constraint in request.constraints do
          if not Comparisons[constraint.op] then handledConstraints = false end
        end
      end

      if handles.where and handledConstraints then
        candidates = {}

        for _, row in rows do
          local kept = true

          for _, constraint in request.constraints do
            if not holds(row, constraint) then kept = false end
          end

          if kept then table.insert(candidates, row) end
        end
      end

      local handledWhere = request.whereComplete == true and handledConstraints
      local orderBy, ordered = request.orderBy, false

      if handles.order and orderBy and #orderBy == 1 then
        local column, descending = orderBy[1].column, orderBy[1].desc == true
        candidates = table.clone(candidates)

        table.sort(candidates, function(left, right)
          if descending then return left[column] > right[column] end

          return left[column] < right[column]
        end)

        ordered = true
      end

      local limit = if handledWhere and (not orderBy or ordered) then request.limitHint or request.limit else nil
      local out = {}

      for _, row in candidates do
        if limit and #out >= limit then break end

        table.insert(out, row)
      end

      return {
        _jessqlScan = 'v1',
        rows = out,
        handledConstraints = handledConstraints,
        handledWhere = handledWhere,
        ordered = ordered,
      }
    end,
  }
end

local BoundedNames = {
  'stops at request.limit',
  'stops at the hint',
  'stops at the hint, applies the WHERE',
  'stops at the hint, produces the order',
  'stops at the hint, applies the WHERE and produces the order',
}

local function boundedProviders(rows, columns)
  return {
    stopsAtLimit(rows, columns),
    stopsAtHint(rows, columns, {}),
    stopsAtHint(rows, columns, { where = true }),
    stopsAtHint(rows, columns, { order = true }),
    stopsAtHint(rows, columns, { where = true, order = true }),
  }
end

--- Runs a query over the numbers and the labels behind every kind of bounded provider, expects
--- each to give the rows the unbounded providers give, and returns those rows.
local function expectUnchanged(text, params)
  local function rowsOver(numberProvider, labelProvider)
    local db = sql.new()
    db:register('numbers', numberProvider)
    db:register('labels', labelProvider)
    return db:query(text, params).rows
  end

  local expected = rowsOver(unbounded(Numbers, NumberColumns), unbounded(Labels, LabelColumns))
  local numberProviders = boundedProviders(Numbers, NumberColumns)
  local labelProviders = boundedProviders(Labels, LabelColumns)
  local got, wanted = {}, {}

  for index, name in BoundedNames do
    got[name], wanted[name] = rowsOver(numberProviders[index], labelProviders[index]), expected
  end

  expect(got).toEqual(wanted)
  return expected
end

--- The request the numbers provider is handed for a query.
local function requestFor(text)
  local seen = {}
  local db = sql.new()
  db:register('numbers', stopsAtLimit(Numbers, NumberColumns, seen))
  db:register('labels', unbounded(Labels, LabelColumns))
  db:query(text)
  return seen[1]
end

suite.describe('provider row bounds', function()
  suite.it('counts every row under COUNT(*) with LIMIT', function()
    expect(expectUnchanged('SELECT COUNT(*) AS total FROM numbers LIMIT 1')).toEqual { { total = 12 } }
    expect(expectUnchanged('SELECT SUM(value) AS total FROM numbers LIMIT 1')).toEqual { { total = 66 } }
  end)

  suite.it('groups every row under GROUP BY with LIMIT', function()
    local text = 'SELECT bucket, COUNT(*) AS total FROM numbers GROUP BY bucket LIMIT 2'
    expect(expectUnchanged(text)).toEqual { { bucket = 0, total = 4 }, { bucket = 1, total = 4 } }

    local last = expectUnchanged('SELECT bucket, MAX(id) AS top FROM numbers GROUP BY bucket ORDER BY bucket DESC LIMIT 1')
    expect(last).toEqual { { bucket = 2, top = 12 } }
  end)

  -- The engine has no DISTINCT; grouping by the column is how a query asks for distinct values.
  suite.it('finds every distinct value under a GROUP BY standing in for DISTINCT, with LIMIT', function()
    expect(expectUnchanged('SELECT bucket FROM numbers GROUP BY bucket LIMIT 2')).toEqual { { bucket = 0 }, { bucket = 1 } }
  end)

  suite.it('lets the provider go on through OFFSET under LIMIT with OFFSET', function()
    expect(expectUnchanged('SELECT id FROM numbers LIMIT 2 OFFSET 3')).toEqual { { id = 4 }, { id = 5 } }
    expect(expectUnchanged('SELECT id FROM numbers LIMIT 0 OFFSET 2')).toEqual {}
  end)

  suite.it('filters every row under LIMIT with a WHERE the provider leaves to the engine', function()
    expect(expectUnchanged('SELECT id FROM numbers WHERE value % 2 = 0 LIMIT 3')).toEqual { { id = 2 }, { id = 4 }, { id = 6 } }
    expect(expectUnchanged('SELECT id FROM numbers WHERE id > 8 AND value % 2 = 0 LIMIT 1')).toEqual { { id = 10 } }
  end)

  suite.it('filters every row under LIMIT with a WHERE the provider can apply', function()
    expect(expectUnchanged('SELECT id FROM numbers WHERE value >= 9 LIMIT 2')).toEqual { { id = 3 }, { id = 5 } }
    expect(expectUnchanged('SELECT id FROM numbers WHERE id > ? LIMIT 1 OFFSET 1', { 9 })).toEqual { { id = 11 } }
  end)

  suite.it('orders every row under LIMIT with an ORDER BY asked of the provider, produced or not', function()
    local top = expectUnchanged('SELECT id, value FROM numbers ORDER BY value DESC LIMIT 3')
    expect(top).toEqual { { id = 5, value = 11 }, { id = 10, value = 10 }, { id = 3, value = 9 } }
    expect(expectUnchanged('SELECT value FROM numbers ORDER BY value LIMIT 2 OFFSET 1')).toEqual { { value = 1 }, { value = 2 } }
  end)

  suite.it('orders every row under LIMIT with an ORDER BY the provider is not asked for', function()
    local top = expectUnchanged('SELECT id FROM numbers ORDER BY value * -1 LIMIT 3')
    expect(top).toEqual { { id = 5 }, { id = 10 }, { id = 3 } }

    local aliased = expectUnchanged('SELECT id, value % 5 AS rank FROM numbers ORDER BY rank DESC, id DESC LIMIT 2')
    expect(aliased).toEqual { { id = 4, rank = 4 }, { id = 3, rank = 4 } }
  end)

  suite.it('joins every row under a two-table join with LIMIT', function()
    local inner = expectUnchanged('SELECT n.id, l.label FROM numbers n JOIN labels l ON n.bucket = l.bucket LIMIT 3 OFFSET 7')
    expect(inner).toEqual { { id = 4, label = 'zero' }, { id = 5, label = 'one' }, { id = 6, label = 'one' } }

    local outer = expectUnchanged('SELECT n.id, l.label FROM numbers n LEFT JOIN labels l ON n.bucket = l.bucket ORDER BY n.id DESC LIMIT 2')
    expect(outer).toEqual { { id = 12 }, { id = 11 } }
  end)

  suite.it('hands a single-table LIMIT to the provider, with OFFSET added', function()
    local plain = requestFor('SELECT id FROM numbers LIMIT 3')
    expect(plain.limit).toBe(3)
    expect(plain.limitHint).toBe(3)

    local offset = requestFor('SELECT id FROM numbers LIMIT 3 OFFSET 4')
    expect(offset.limit).toBe(7)
    expect(offset.limitHint).toBe(7)
  end)

  suite.it('hands only the hint under an ORDER BY asked of the provider', function()
    local request = requestFor('SELECT id FROM numbers ORDER BY value DESC LIMIT 3 OFFSET 1')
    expect(request.orderBy).toEqual { { column = 'value', desc = true } }
    expect(request.limit).toBeNil()
    expect(request.limitHint).toBe(4)
  end)

  suite.it('hands no bound when the engine has more to do after the scan', function()
    local queries = {
      'SELECT COUNT(*) AS total FROM numbers LIMIT 1',
      'SELECT bucket FROM numbers GROUP BY bucket LIMIT 1',
      'SELECT id FROM numbers WHERE value >= 9 LIMIT 1',
      'SELECT id FROM numbers ORDER BY value * -1 LIMIT 1',
      'SELECT n.id FROM numbers n JOIN labels l ON n.bucket = l.bucket LIMIT 1',
      'SELECT id FROM numbers OFFSET 3',
    }

    for _, text in queries do
      local request = requestFor(text)
      expect({ text, request.limit, request.limitHint }).toEqual { text }
    end
  end)
end)

return suite
