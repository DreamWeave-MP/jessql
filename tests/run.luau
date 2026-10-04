local sql = require('@jessql')
local test = require('@jess/test')
local expect = test.expect
local suite = test.new()

local function streamingDb()
  local db = sql.new()
  db:register('numbers', {
    columns = { 'id', 'bucket', 'value' },
    iterate = function(_request)
      local i = 0
      return {
        _jessqlIter = 'v1',
        handledConstraints = false,
        handledWhere = false,
        ordered = false,
        next = function()
          i += 1
          if i > 1000 then return nil end
          return { id = i, bucket = i % 10, value = (i * 17) % 997 }
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
    for i = 2, #result.rows do
      local previous = result.rows[i - 1]
      local current = result.rows[i]
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

return suite
