local sql = require('@jessql')
local n = tonumber((...)) or 100000
local left = table.create(n)
local right = table.create(n)
for i = 1, n do
    left[i] = { id=i, name='L' .. tostring(i) }
    right[i] = { id=i, value=(i * 17) % 10000 }
end
local db = sql.new()
db:table('left_rows', left, {'id','name'})
db:table('right_rows', right, {'id','value'})
local q = db:prepare('SELECT l.id, l.name, r.value FROM left_rows l JOIN right_rows r ON l.id = r.id WHERE r.value >= ? ORDER BY r.value DESC LIMIT 10')
print('strategy=' .. q.explain().joins[1].strategy)
local result = q.run({9000})
print(string.format('rows_in=%d+%d rows_out=%d', n, n, #result.rows))
print(result.rows[1].id, result.rows[1].value)
