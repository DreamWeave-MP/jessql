local sql = require('@jessql')

local n = tonumber((...)) or 100000
local rows = table.create(n)
for i = 1, n do
    rows[i] = {
        id = i,
        kind = if i % 7 == 0 then 'WEAP' elseif i % 5 == 0 then 'ARMO' else 'MISC',
        value = (i * 7919) % 10000,
        bucket = i % 64,
    }
end

local db = sql.new()
db:table('records', rows, {'id','kind','value','bucket'})
local q = db:prepare([[SELECT kind, bucket, count(*) AS n, sum(value) AS total, avg(value) AS mean
FROM records
WHERE value >= ?
GROUP BY kind, bucket
HAVING count(*) >= 10
ORDER BY total DESC
LIMIT 25]])

local result = q.run({2500})
print(string.format('rows_in=%d rows_out=%d params=%d', n, #result.rows, q.parameterCount))
for i = 1, math.min(3, #result.rows) do
    local r = result.rows[i]
    print(string.format('%s bucket=%d n=%d total=%d mean=%.2f', r.kind, r.bucket, r.n, r.total, r.mean))
end
