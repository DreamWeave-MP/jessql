local sql = require('@jessql')
local rowCount = tonumber((...)) or 100000
local left = table.create(rowCount)
local right = table.create(rowCount)

for index = 1, rowCount do
  left[index] = { id = index, name = 'L' .. tostring(index) }
  right[index] = { id = index, value = (index * 17) % 10000 }
end

local db = sql.new()
db:table('left_rows', left, { 'id', 'name' })
db:table('right_rows', right, { 'id', 'value' })
local query = db:prepare('SELECT l.id, l.name, r.value FROM left_rows l JOIN right_rows r ON l.id = r.id WHERE r.value >= ? ORDER BY r.value DESC LIMIT 10')
print('strategy=' .. query.explain().joins[1].strategy)
local result = query.run({ 9000 })
print(string.format('rows_in=%d+%d rows_out=%d', rowCount, rowCount, #result.rows))
print(result.rows[1].id, result.rows[1].value)
