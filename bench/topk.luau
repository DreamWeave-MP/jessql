local sql=require('@jessql'); local n=tonumber((...)) or 500000
local rows=table.create(n); for i=1,n do rows[i]={id=i,value=(i*7919)%1000000} end
local db=sql.new(); db:table('x',rows,{'id','value'}); local q=db:prepare('SELECT id, value FROM x WHERE value >= 100 ORDER BY value DESC LIMIT 20')
for r=1,3 do local t=os.clock(); local x=q.run(); print(r,(os.clock()-t)*1000,#x.rows,x.rows[1].value) end
