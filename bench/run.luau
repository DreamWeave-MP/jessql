local sql = require('@jessql')

local rowCount = tonumber((...)) or 100000
local rows = table.create(rowCount)

for index = 1, rowCount do
  rows[index] = {
    id = index,
    kind = if index % 7 == 0 then 'WEAP' elseif index % 5 == 0 then 'ARMO' else 'MISC',
    value = (index * 7919) % 10000,
    bucket = index % 64,
  }
end

local db = sql.new()
db:table('records', rows, { 'id', 'kind', 'value', 'bucket' })
local query = db:prepare([[SELECT kind, bucket, count(*) AS n, sum(value) AS total, avg(value) AS mean
FROM records
WHERE value >= ?
GROUP BY kind, bucket
HAVING count(*) >= 10
ORDER BY total DESC
LIMIT 25]])

local result = query.run({ 2500 })
print(string.format('rows_in=%d rows_out=%d params=%d', rowCount, #result.rows, query.parameterCount))

for index = 1, math.min(3, #result.rows) do
  local row = result.rows[index]
  print(string.format('%s bucket=%d n=%d total=%d mean=%.2f', row.kind, row.bucket, row.n, row.total, row.mean))
end
