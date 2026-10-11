local sql = require('@jessql')
local rowCount = tonumber((...)) or 500000
local rows = table.create(rowCount)

for index = 1, rowCount do
  rows[index] = { id = index, value = (index * 7919) % 1000000 }
end

local db = sql.new()
db:table('x', rows, { 'id', 'value' })
local query = db:prepare('SELECT id, value FROM x WHERE value >= 100 ORDER BY value DESC LIMIT 20')

for round = 1, 3 do
  local started = os.clock()
  local result = query.run()
  print(round, (os.clock() - started) * 1000, #result.rows, result.rows[1].value)
end
