--!native

local parser = require('@jessql/parser')

local M = {}
local AGG = { COUNT=true, SUM=true, AVG=true, MIN=true, MAX=true }

local function lower(s) return string.lower(s) end

local function hasAggregate(expr)
    if expr == nil then return false end
    if expr.tag == 'call' and AGG[expr.name] then return true end
    if expr.tag == 'binary' then return hasAggregate(expr.left) or hasAggregate(expr.right) end
    if expr.tag == 'unary' or expr.tag == 'isnull' then return hasAggregate(expr.expr) end
    if expr.tag == 'call' then
        for _, a in expr.args do if hasAggregate(a) then return true end end
    end
    return false
end

local function sqlTruthy(v) return v ~= nil and v ~= false end

local function like(value, pattern)
    if value == nil or pattern == nil then return nil end
    value = tostring(value); pattern = tostring(pattern)
    local vi, pi, starVi, starPi = 1, 1, nil, nil
    while vi <= #value do
        local pc = string.sub(pattern, pi, pi)
        if pc == '_' then
            vi += 1; pi += 1
        elseif pc == '%' then
            starPi = pi + 1; starVi = vi; pi += 1
        elseif pc ~= '' and string.sub(value, vi, vi) == pc then
            vi += 1; pi += 1
        elseif starPi ~= nil then
            starVi += 1; vi = starVi; pi = starPi
        else
            return false
        end
    end
    while string.sub(pattern, pi, pi) == '%' do pi += 1 end
    return pi > #pattern
end

local function compileLiteralLike(pattern)
    if type(pattern) ~= 'string' then return nil end
    local firstPercent = string.find(pattern, '%', 1, true)
    local firstUnderscore = string.find(pattern, '_', 1, true)
    if firstUnderscore ~= nil then return nil end
    if firstPercent == nil then
        return function(value)
            if value == nil then return nil end
            return tostring(value) == pattern
        end
    end
    local secondPercent = string.find(pattern, '%', firstPercent + 1, true)
    if secondPercent ~= nil then return nil end
    if firstPercent == #pattern then
        local prefix = string.sub(pattern, 1, -2)
        local n = #prefix
        return function(value)
            if value == nil then return nil end
            value = tostring(value)
            return #value >= n and string.sub(value, 1, n) == prefix
        end
    elseif firstPercent == 1 then
        local suffix = string.sub(pattern, 2)
        local n = #suffix
        return function(value)
            if value == nil then return nil end
            value = tostring(value)
            return #value >= n and string.sub(value, #value - n + 1) == suffix
        end
    end
    return nil
end

local function bindColumn(expr, sources)
    if expr.sourceIndex ~= nil and expr.boundName ~= nil then return expr.sourceIndex, expr.boundName end
    local name = lower(expr.name)
    local sourceIndex = nil
    if expr.qualifier then
        local q = lower(expr.qualifier)
        for i, s in sources do
            if lower(s.alias) == q or lower(s.name) == q then sourceIndex = i; break end
        end
        if sourceIndex == nil then error('jessql: unknown table/alias ' .. expr.qualifier, 0) end
    else
        local hit = nil
        for i, s in sources do
            if s.columnSet[name] then
                if hit ~= nil then error('jessql: ambiguous column ' .. expr.name, 0) end
                hit = i
            end
        end
        if hit == nil then error('jessql: unknown column ' .. expr.name, 0) end
        sourceIndex = hit
    end
    expr.sourceIndex = sourceIndex
    expr.boundName = sources[sourceIndex].columnMap[name] or expr.name
    return sourceIndex, expr.boundName
end

local function compileExpr(expr, sources, directSingle, aggregateIds)
    local tag = expr.tag
    if tag == 'literal' then
        local value = expr.value
        return function(_ctx, _group, _params) return value end
    elseif tag == 'param' then
        local index = expr.index
        return function(_ctx, _group, params) return params[index] end
    elseif tag == 'column' then
        local sourceIndex, boundName = bindColumn(expr, sources)
        local key = boundName
        local si = sourceIndex
        if directSingle then
            return function(row, _group, _params) return row[key] end
        end
        return function(ctx, _group, _params)
            local row = ctx[si]
            return if row == nil then nil else row[key]
        end
    elseif tag == 'unary' then
        local f = compileExpr(expr.expr, sources, directSingle, aggregateIds)
        if expr.op == 'NOT' then return function(c,g,p) local v=f(c,g,p); return if v==nil then nil else not sqlTruthy(v) end end
        if expr.op == '-' then return function(c,g,p) local v=f(c,g,p); return if v==nil then nil else -v end end
        return function(c,g,p) return f(c,g,p) end
    elseif tag == 'isnull' then
        local f = compileExpr(expr.expr, sources, directSingle, aggregateIds)
        if expr.negated then return function(c,g,p) return f(c,g,p) ~= nil end end
        return function(c,g,p) return f(c,g,p) == nil end
    elseif tag == 'binary' then
        local a = compileExpr(expr.left, sources, directSingle, aggregateIds)
        local b = compileExpr(expr.right, sources, directSingle, aggregateIds)
        local op = expr.op
        if op == 'AND' then return function(c,g,p) local x=a(c,g,p); if x==false then return false end; local y=b(c,g,p); if y==false then return false end; if x==nil or y==nil then return nil end; return sqlTruthy(x) and sqlTruthy(y) end end
        if op == 'OR' then return function(c,g,p) local x=a(c,g,p); if sqlTruthy(x) then return true end; local y=b(c,g,p); if sqlTruthy(y) then return true end; if x==nil or y==nil then return nil end; return false end end
        if op == '=' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x==y end end
        if op == '!=' or op == '<>' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x~=y end end
        if op == '<' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x<y end end
        if op == '<=' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x<=y end end
        if op == '>' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x>y end end
        if op == '>=' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x>=y end end
        if op == '+' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x+y end end
        if op == '-' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x-y end end
        if op == '*' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x*y end end
        if op == '/' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x/y end end
        if op == '%' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return x%y end end
        if op == '||' then return function(c,g,p) local x,y=a(c,g,p),b(c,g,p); if x==nil or y==nil then return nil end; return tostring(x)..tostring(y) end end
        if op == 'LIKE' then
            if expr.right.tag == 'literal' then
                local fast = compileLiteralLike(expr.right.value)
                if fast ~= nil then return function(c,g,p) return fast(a(c,g,p)) end end
            end
            return function(c,g,p) return like(a(c,g,p), b(c,g,p)) end
        end
        error('jessql: unsupported operator ' .. tostring(op), 0)
    elseif tag == 'call' then
        local name = expr.name
        if AGG[name] and aggregateIds ~= nil then
            local id = aggregateIds[expr]
            if id == nil then error('jessql: aggregate expression was not planned', 0) end
            return function(_c, group, _p) return group[id] end
        elseif AGG[name] then
            local arg = nil
            if not expr.star then
                if #expr.args ~= 1 then error('jessql: aggregate ' .. name .. ' needs one argument', 0) end
                arg = compileExpr(expr.args[1], sources, directSingle, aggregateIds)
            end
            if name == 'COUNT' then
                if expr.star then return function(_c,g,_p) return #g end end
                return function(_c,g,p) local n=0; for _,gc in g do if arg(gc,g,p)~=nil then n+=1 end end; return n end
            elseif name == 'SUM' then
                return function(_c,g,p) local total=nil; for _,gc in g do local v=arg(gc,g,p); if v~=nil then total=(total or 0)+v end end; return total end
            elseif name == 'AVG' then
                return function(_c,g,p) local total,n=0,0; for _,gc in g do local v=arg(gc,g,p); if v~=nil then total+=v; n+=1 end end; return if n==0 then nil else total/n end
            elseif name == 'MIN' then
                return function(_c,g,p) local best=nil; for _,gc in g do local v=arg(gc,g,p); if v~=nil and (best==nil or v<best) then best=v end end; return best end
            else
                return function(_c,g,p) local best=nil; for _,gc in g do local v=arg(gc,g,p); if v~=nil and (best==nil or v>best) then best=v end end; return best end
            end
        end
        local args = table.create(#expr.args)
        for i, a in expr.args do args[i] = compileExpr(a, sources, directSingle, aggregateIds) end
        if name == 'LOWER' then
            return function(c,g,p) local v=args[1](c,g,p); return if v==nil then nil else string.lower(tostring(v)) end
        elseif name == 'UPPER' then
            return function(c,g,p) local v=args[1](c,g,p); return if v==nil then nil else string.upper(tostring(v)) end
        elseif name == 'LENGTH' then
            return function(c,g,p) local v=args[1](c,g,p); return if v==nil then nil else #tostring(v) end
        elseif name == 'ABS' then
            return function(c,g,p) local v=args[1](c,g,p); return if v==nil then nil else math.abs(v) end
        elseif name == 'COALESCE' then
            return function(c,g,p) for _,f in args do local v=f(c,g,p); if v~=nil then return v end end return nil end
        else
            error('jessql: unknown function ' .. name, 0)
        end
    end
    error('jessql: cannot compile expression ' .. tostring(tag), 0)
end

local function schemaFromRows(rows)
    local columns, seen = {}, {}
    for i = 1, math.min(#rows, 32) do
        for k in rows[i] do
            if type(k) == 'string' and not seen[lower(k)] then seen[lower(k)] = true; columns[#columns+1] = k end
        end
    end
    table.sort(columns)
    return columns
end

local function makeSource(db, spec, index)
    local provider = db._tables[lower(spec.name)]
    if provider == nil then error('jessql: unknown table ' .. spec.name, 0) end
    local columns = provider.columns
    local cmap, cset = {}, {}
    for _, c in columns do cmap[lower(c)] = c; cset[lower(c)] = true end
    return { name=spec.name, alias=spec.alias, provider=provider, columns=columns, columnMap=cmap, columnSet=cset, index=index }
end

local function constraintFrom(expr)
    if expr == nil then return {}, true end
    local out = {}
    local function walk(e)
        if e.tag == 'binary' and e.op == 'AND' then return walk(e.left) and walk(e.right) end
        if e.tag ~= 'binary' then return false end
        local op = e.op
        if op ~= '=' and op ~= '!=' and op ~= '<>' and op ~= '<' and op ~= '<=' and op ~= '>' and op ~= '>=' and op ~= 'LIKE' then return false end
        local col, lit = e.left, e.right
        local flip = false
        if col.tag ~= 'column' or (lit.tag ~= 'literal' and lit.tag ~= 'param') then
            col, lit = e.right, e.left; flip = true
        end
        if col.tag ~= 'column' or (lit.tag ~= 'literal' and lit.tag ~= 'param') or col.sourceIndex == nil then return false end
        if flip then
            if op == '<' then op = '>' elseif op == '>' then op = '<' elseif op == '<=' then op = '>=' elseif op == '>=' then op = '<=' end
        end
        out[#out+1] = { sourceIndex=col.sourceIndex, column=col.boundName, op=op, value=lit.value, param=lit.index }
        return true
    end
    local complete = walk(expr)
    return out, complete
end

local function conjuncts(expr)
    local out = {}
    local function walk(e)
        if e ~= nil and e.tag == 'binary' and e.op == 'AND' then
            walk(e.left); walk(e.right)
        elseif e ~= nil then
            out[#out+1] = e
        end
    end
    walk(expr)
    return out
end

local function singleSourceOf(expr)
    local source = nil
    local mixed = false
    local function walk(e)
        if e == nil or mixed then return end
        if e.tag == 'column' then
            local si = e.sourceIndex
            if si ~= nil then
                if source == nil then source = si elseif source ~= si then mixed = true end
            end
        elseif e.tag == 'binary' then
            walk(e.left); walk(e.right)
        elseif e.tag == 'unary' or e.tag == 'isnull' then
            walk(e.expr)
        elseif e.tag == 'call' then
            for _, a in e.args do walk(a) end
        end
    end
    walk(expr)
    return if mixed then nil else source
end

local function valueKey(v)
    if v == nil then return 'N;' end
    local t = type(v)
    if t == 'string' then return 'S' .. #v .. ':' .. v end
    if t == 'number' then return 'D' .. tostring(v) .. ';' end
    if t == 'boolean' then return if v then 'B1;' else 'B0;' end
    return 'O' .. tostring(v) .. ';'
end

local function prepare(db, sql)
    local ast = parser.parse(sql)
    local sources = { makeSource(db, ast.from, 1) }
    for i, j in ast.joins do sources[#sources+1] = makeSource(db, j.source, i+1) end
    local directSingle = #sources == 1

    if hasAggregate(ast.where) then error('jessql: aggregates are not allowed in WHERE', 0) end
    for _, e in ast.groupBy do if hasAggregate(e) then error('jessql: aggregates are not allowed in GROUP BY', 0) end end
    for _, j in ast.joins do if hasAggregate(j.on) then error('jessql: aggregates are not allowed in JOIN ON', 0) end end

    local aggregateIds = {}
    local aggregateSpecs = {}
    local aggregateByKey = {}
    local function exprKey(e)
        if e == nil then return 'nil' end
        if e.tag == 'literal' then return 'lit:' .. type(e.value) .. ':' .. tostring(e.value) end
        if e.tag == 'param' then return 'param:' .. tostring(e.index) end
        if e.tag == 'column' then return 'col:' .. lower(e.qualifier or '') .. '.' .. lower(e.name) end
        if e.tag == 'star' then return 'star:' .. lower(e.qualifier or '') end
        if e.tag == 'unary' then return 'u:' .. e.op .. '(' .. exprKey(e.expr) .. ')' end
        if e.tag == 'isnull' then return 'null:' .. tostring(e.negated) .. '(' .. exprKey(e.expr) .. ')' end
        if e.tag == 'binary' then return 'b:' .. e.op .. '(' .. exprKey(e.left) .. ',' .. exprKey(e.right) .. ')' end
        if e.tag == 'call' then
            local parts = table.create(#e.args)
            for i, a in e.args do parts[i] = exprKey(a) end
            return 'call:' .. e.name .. ':' .. tostring(e.star) .. '(' .. table.concat(parts, ',') .. ')'
        end
        return tostring(e.tag)
    end
    local function registerAggregates(e)
        if e == nil then return end
        if e.tag == 'call' and AGG[e.name] then
            local key = exprKey(e)
            local id = aggregateByKey[key]
            if id == nil then
                id = #aggregateSpecs + 1
                aggregateByKey[key] = id
                aggregateSpecs[id] = { name=e.name, star=e.star, expr=e }
            end
            aggregateIds[e] = id
            return
        elseif e.tag == 'binary' then
            registerAggregates(e.left); registerAggregates(e.right)
        elseif e.tag == 'unary' or e.tag == 'isnull' then
            registerAggregates(e.expr)
        elseif e.tag == 'call' then
            for _, a in e.args do registerAggregates(a) end
        end
    end
    for _, item in ast.select do registerAggregates(item.expr) end
    registerAggregates(ast.having)
    for _, o in ast.orderBy do registerAggregates(o.expr) end

    local whereFn = if ast.where then compileExpr(ast.where, sources, directSingle, nil) else nil
    local whereTermPlans = {}
    if ast.where ~= nil then
        for _, term in conjuncts(ast.where) do
            local _, pushable = constraintFrom(term)
            whereTermPlans[#whereTermPlans+1] = {
                fn = compileExpr(term, sources, directSingle, nil),
                sourceIndex = singleSourceOf(term),
                pushable = pushable,
            }
        end
    end
    local sourceWhereFns = table.create(#sources)
    if #sources > 1 and ast.where ~= nil then
        local bySource = table.create(#sources)
        for _, term in conjuncts(ast.where) do
            local si = singleSourceOf(term)
            if si ~= nil then
                local list = bySource[si]
                if list == nil then list = {}; bySource[si] = list end
                list[#list+1] = compileExpr(term, sources, true, nil)
            end
        end
        for si, list in bySource do
            if list ~= nil then
                sourceWhereFns[si] = function(row, params)
                    for _, fn in list do
                        if not sqlTruthy(fn(row, nil, params)) then return false end
                    end
                    return true
                end
            end
        end
    end
    local function sourceFilterScore(sourceIndex)
        local score = 0
        for _, term in whereTermPlans do
            if term.sourceIndex == sourceIndex then score += if term.pushable then 2 else 1 end
        end
        return score
    end

    local joinFns = {}
    local joinPlans = {}
    for i, j in ast.joins do
        joinFns[i] = compileExpr(j.on, sources, directSingle, nil)
        local rightIndex = i + 1
        local e = j.on
        local plan = { strategy='nested-loop' }
        if e.tag == 'binary' and e.op == '=' and e.left.tag == 'column' and e.right.tag == 'column' then
            local leftCol, rightCol = e.left, e.right
            if leftCol.sourceIndex == rightIndex and rightCol.sourceIndex < rightIndex then leftCol, rightCol = rightCol, leftCol end
            if leftCol.sourceIndex < rightIndex and rightCol.sourceIndex == rightIndex then
                plan = {
                    strategy='hash',
                    leftSourceIndex=leftCol.sourceIndex,
                    leftColumn=leftCol.boundName,
                    rightColumn=rightCol.boundName,
                }
                if #sources == 2 and #ast.joins == 1 and j.kind == 'inner' then
                    local leftProvider = sources[leftCol.sourceIndex].provider
                    local rightProvider = sources[rightIndex].provider
                    local leftIndexed = leftCol.sourceIndex == 1 and type(leftProvider.lookup) == 'function'
                        and type(leftProvider.indexes) == 'table' and leftProvider.indexes[leftCol.boundName] == true
                    local rightIndexed = type(rightProvider.lookup) == 'function'
                        and type(rightProvider.indexes) == 'table' and rightProvider.indexes[rightCol.boundName] == true
                    if leftIndexed and rightIndexed then
                        local leftScore = sourceFilterScore(leftCol.sourceIndex)
                        local rightScore = sourceFilterScore(rightIndex)
                        plan.strategy = if leftScore > rightScore then 'index-right' else 'index-left'
                    elseif leftIndexed then
                        plan.strategy = 'index-left'
                    elseif rightIndexed then
                        plan.strategy = 'index-right'
                    end
                end
            end
        end
        joinPlans[i] = plan
    end
    local groupFns = {}
    for i, e in ast.groupBy do groupFns[i] = compileExpr(e, sources, directSingle, nil) end
    for _, spec in aggregateSpecs do
        if spec.star then
            if spec.name ~= 'COUNT' then error('jessql: only COUNT accepts *', 0) end
        else
            if #spec.expr.args ~= 1 then error('jessql: aggregate ' .. spec.name .. ' needs one argument', 0) end
            spec.argFn = compileExpr(spec.expr.args[1], sources, directSingle, nil)
        end
    end
    local havingFn = if ast.having then compileExpr(ast.having, sources, directSingle, aggregateIds) else nil
    local hasAvg = false
    for _, spec in aggregateSpecs do if spec.name == 'AVG' then hasAvg = true; break end end

    -- A single simple GROUP BY column can carry its own representative value. If every
    -- non-aggregate column referenced after grouping is that same column, retaining the first
    -- provider/join context per group is pure overhead. Keep permissive first-row semantics for
    -- every other query shape. ORDER BY may reference SELECT aliases, so inspect their defining
    -- expressions instead of mistaking an aggregate alias for a provider column.
    local compactGroupColumn = nil
    if #ast.groupBy == 1 then
        local grouped = ast.groupBy[1]
        local groupedSource = if grouped.tag == 'column' then grouped.sourceIndex else nil
        if groupedSource == nil and grouped.tag == 'column' and directSingle then groupedSource = 1 end
        if grouped.tag == 'column' and groupedSource ~= nil then
            local groupedName = grouped.boundName or grouped.name
            local selectAliases = {}
            for _, item in ast.select do
                if item.alias ~= nil then selectAliases[lower(item.alias)] = item.expr end
            end
            local aliasStack = {}
            local safe = true
            local function inspectPostAggregate(expr, insideAggregate)
                if expr == nil or not safe then return end
                if expr.tag == 'column' then
                    if not insideAggregate then
                        local aliasExpr = nil
                        if expr.qualifier == nil and expr.sourceIndex == nil then
                            aliasExpr = selectAliases[lower(expr.name)]
                        end
                        if aliasExpr ~= nil and not aliasStack[aliasExpr] then
                            aliasStack[aliasExpr] = true
                            inspectPostAggregate(aliasExpr, false)
                            aliasStack[aliasExpr] = nil
                        else
                            local sourceIndex, columnName = bindColumn(expr, sources)
                            if sourceIndex ~= groupedSource or columnName ~= groupedName then safe = false end
                        end
                    end
                elseif expr.tag == 'binary' then
                    inspectPostAggregate(expr.left, insideAggregate)
                    inspectPostAggregate(expr.right, insideAggregate)
                elseif expr.tag == 'unary' or expr.tag == 'isnull' then
                    inspectPostAggregate(expr.expr, insideAggregate)
                elseif expr.tag == 'call' then
                    local aggregateCall = AGG[string.upper(expr.name)] == true
                    for _, argument in expr.args do inspectPostAggregate(argument, insideAggregate or aggregateCall) end
                end
            end
            for _, item in ast.select do inspectPostAggregate(item.expr, false) end
            inspectPostAggregate(ast.having, false)
            for _, order in ast.orderBy do inspectPostAggregate(order.expr, false) end
            if safe then compactGroupColumn = { sourceIndex=groupedSource, column=groupedName } end
        end
    end

    local selectors = {}
    local resultColumns = {}
    local selectorByAlias = {}
    local selectorSource = {}
    local function addSelector(name, fn, sourceInfo)
        selectors[#selectors+1] = fn
        resultColumns[#resultColumns+1] = name
        selectorByAlias[lower(name)] = fn
        selectorSource[lower(name)] = sourceInfo
    end
    for _, item in ast.select do
        local e = item.expr
        if e.tag == 'star' then
            for si, s in sources do
                if e.qualifier == nil or lower(e.qualifier) == lower(s.alias) or lower(e.qualifier) == lower(s.name) then
                    for _, c in s.columns do
                        local key = c
                        local idx = si
                        local fn
                        if directSingle then
                            fn = function(row) return row[key] end
                        else
                            fn = function(ctx) local r=ctx[idx]; return if r then r[key] else nil end
                        end
                        addSelector(if directSingle then c else s.alias .. '.' .. c, fn, { sourceIndex=si, column=c })
                    end
                end
            end
        else
            local name = item.alias
            if name == nil then
                if e.tag == 'column' then name = e.name
                elseif e.tag == 'call' then name = string.lower(e.name)
                else name = 'expr' .. tostring(#selectors + 1) end
            end
            local fn = compileExpr(e, sources, directSingle, aggregateIds)
            local sourceInfo = if e.tag == 'column' and e.sourceIndex ~= nil then { sourceIndex=e.sourceIndex, column=e.boundName } else nil
            addSelector(name, fn, sourceInfo)
        end
    end

    local orderFns = {}
    local orderSourceInfo = {}
    for i, o in ast.orderBy do
        local fn = nil
        if o.expr.tag == 'column' and o.expr.qualifier == nil then
            local key = lower(o.expr.name)
            fn = selectorByAlias[key]
            orderSourceInfo[i] = selectorSource[key]
        end
        if fn == nil then
            fn = compileExpr(o.expr, sources, directSingle, aggregateIds)
            if o.expr.tag == 'column' and o.expr.sourceIndex ~= nil then
                orderSourceInfo[i] = { sourceIndex=o.expr.sourceIndex, column=o.expr.boundName }
            end
        end
        orderFns[i] = { fn=fn, desc=o.desc }
    end

    local neededSets = {}
    for i = 1, #sources do neededSets[i] = {} end
    local function markExpr(e)
        if e == nil then return end
        if e.tag == 'column' and e.sourceIndex ~= nil then
            neededSets[e.sourceIndex][e.boundName] = true
        elseif e.tag == 'star' then
            for si, source in sources do
                if e.qualifier == nil or lower(e.qualifier) == lower(source.alias) or lower(e.qualifier) == lower(source.name) then
                    for _, c in source.columns do neededSets[si][c] = true end
                end
            end
        elseif e.tag == 'binary' then
            markExpr(e.left); markExpr(e.right)
        elseif e.tag == 'unary' or e.tag == 'isnull' then
            markExpr(e.expr)
        elseif e.tag == 'call' then
            for _, a in e.args do markExpr(a) end
        end
    end
    for _, item in ast.select do markExpr(item.expr) end
    markExpr(ast.where); markExpr(ast.having)
    for _, e in ast.groupBy do markExpr(e) end
    for _, o in ast.orderBy do markExpr(o.expr) end
    for _, j in ast.joins do markExpr(j.on) end
    local neededColumns = {}
    for si, source in sources do
        local cols = {}
        for _, c in source.columns do if neededSets[si][c] then cols[#cols+1] = c end end
        neededColumns[si] = cols
    end

    local aggregate = #ast.groupBy > 0 or #aggregateSpecs > 0

    -- Exact provider cardinality can answer the simplest COUNT(*) without scanning any rows.
    -- Keep this deliberately narrow: once WHERE/GROUP/HAVING/ORDER/LIMIT/OFFSET participates,
    -- normal SQL execution owns the semantics.
    local directProviderCount = false
    if directSingle and ast.where == nil and #ast.groupBy == 0 and ast.having == nil
        and #ast.orderBy == 0 and ast.limit == nil and ast.offset == 0 and #ast.select == 1
        and type(sources[1].provider.count) == 'function' then
        local expression = ast.select[1].expr
        directProviderCount = expression.tag == 'call' and expression.name == 'COUNT' and expression.star == true
    end

    -- Binding happened while compiling WHERE/select/etc.; extract safe provider hints now.
    local constraints, constraintsComplete = constraintFrom(ast.where)

    local providerOrder = nil
    if directSingle and not aggregate and #ast.orderBy > 0 then
        local pushed = table.create(#ast.orderBy)
        local ok = true
        for i, o in ast.orderBy do
            local info = orderSourceInfo[i]
            if info == nil or info.sourceIndex ~= 1 then
                ok = false
                break
            end
            pushed[i] = { column=info.column, desc=o.desc }
        end
        if ok then providerOrder = pushed end
    end

    local indexedDriverSource = nil
    local indexedDriverOrder = nil
    if #sources == 2 and #joinPlans == 1 then
        if joinPlans[1].strategy == 'index-left' then indexedDriverSource = 2 end
        if joinPlans[1].strategy == 'index-right' then indexedDriverSource = 1 end
        if not aggregate and indexedDriverSource ~= nil and #ast.orderBy > 0 then
            local pushed = table.create(#ast.orderBy)
            local ok = true
            for i, o in ast.orderBy do
                local info = orderSourceInfo[i]
                if info == nil or info.sourceIndex ~= indexedDriverSource then ok = false; break end
                pushed[i] = { column=info.column, desc=o.desc }
            end
            if ok then indexedDriverOrder = pushed end
        end
    end

    local plan = {}
    function plan.run(params)
        params = params or {}
        if #params < ast.params then error(string.format('jessql: query expects %d parameters, got %d', ast.params, #params), 0) end
        if directProviderCount then
            local row = {}
            row[resultColumns[1]] = sources[1].provider.count()
            return { columns=resultColumns, rows={row} }
        end

        local rowsBySource = table.create(#sources)
        local rowIterators = table.create(#sources)
        local scanMeta = table.create(#sources)
        local scanRequests = table.create(#sources)
        local skipScan = {}
        local lazyDriver = {}
        if directSingle and type(sources[1].provider.iterate) == 'function' then
            skipScan[1] = true
            lazyDriver[1] = true
        end
        if #sources == 2 and #joinPlans == 1 then
            if joinPlans[1].strategy == 'index-left' then skipScan[1] = true end
            if joinPlans[1].strategy == 'index-right' then skipScan[2] = true end
            if indexedDriverSource ~= nil and type(sources[indexedDriverSource].provider.iterate) == 'function' then
                skipScan[indexedDriverSource] = true
                lazyDriver[indexedDriverSource] = true
            end
        end
        for si, s in sources do
            local cs = {}
            for _, c in constraints do
                if c.sourceIndex == si then
                    cs[#cs+1] = { column=c.column, op=c.op, value=if c.param then params[c.param] else c.value }
                end
            end
            local request = {
                columns=neededColumns[si],
                constraints=cs,
                limit=if #sources==1 and ast.where==nil then ast.limit else nil,
                limitHint=if directSingle and not aggregate and ast.limit ~= nil and ast.where == nil then ast.offset + ast.limit else nil,
                orderBy=if directSingle and si == 1 then providerOrder
                    elseif indexedDriverSource == si then indexedDriverOrder
                    else nil,
                whereComplete=directSingle and (ast.where == nil or constraintsComplete),
                allowVolatileRows=directSingle,
            }
            scanRequests[si] = request
            if lazyDriver[si] then
                local iter = s.provider.iterate(request)
                if type(iter) ~= 'table' or iter._jessqlIter ~= 'v1' or type(iter.next) ~= 'function' then
                    error('jessql: provider iterate(request) must return a v1 iterator', 0)
                end
                rowIterators[si] = iter
                scanMeta[si] = iter
            elseif not skipScan[si] then
                local scanned = s.provider.scan(request)
                if type(scanned) == 'table' and scanned._jessqlScan == 'v1' then
                    rowsBySource[si] = scanned.rows
                    scanMeta[si] = scanned
                else
                    rowsBySource[si] = scanned
                end
                local sourceWhere = sourceWhereFns[si]
                local meta = scanMeta[si]
                if sourceWhere ~= nil and not (meta ~= nil and meta.handledConstraints == true) then
                    local input = rowsBySource[si]
                    local filtered = {}
                    for _, row in input do
                        if sourceWhere(row, params) then filtered[#filtered+1] = row end
                    end
                    rowsBySource[si] = filtered
                end
            end
        end

        local residualWhere = whereFn
        if #whereTermPlans > 0 then
            local active = {}
            for _, term in whereTermPlans do
                local meta = if term.sourceIndex ~= nil then scanMeta[term.sourceIndex] else nil
                if not (term.pushable and meta ~= nil and meta.handledConstraints == true) then
                    active[#active+1] = term.fn
                end
            end
            if #active == 0 then
                residualWhere = nil
            elseif #active ~= #whereTermPlans then
                residualWhere = function(ctx, group, runParams)
                    for _, fn in active do
                        if not sqlTruthy(fn(ctx, group, runParams)) then return false end
                    end
                    return true
                end
            end
        end
        local orderHandled = false
        if directSingle then
            local meta = scanMeta[1]
            if meta ~= nil then
                if meta.handledWhere == true then residualWhere = nil end
                if meta.ordered == true and providerOrder ~= nil then orderHandled = true end
            end
        end

        local indexedJoinIterator = nil
        if not directSingle and #ast.joins == 1 then
            local joinPlan = joinPlans[1]
            if joinPlan.strategy == 'index-left' or joinPlan.strategy == 'index-right' then
                local lookupSource = if joinPlan.strategy == 'index-left' then 1 else 2
                local driverSource = if lookupSource == 1 then 2 else 1
                local lookupColumn = if lookupSource == 1 then joinPlan.leftColumn else joinPlan.rightColumn
                local driverColumn = if driverSource == 1 then joinPlan.leftColumn else joinPlan.rightColumn
                local provider = sources[lookupSource].provider
                local request = scanRequests[lookupSource]
                local driverIterator = rowIterators[driverSource]
                local driverRows = rowsBySource[driverSource]
                local driverPosition = 0
                local currentDriver = nil
                local currentMatches = nil
                local matchPosition = 0
                local lastKey = nil
                local lastMatches = nil
                local yielded = 0
                local joinedLimit = if not aggregate and residualWhere == nil and #orderFns == 0 and ast.limit ~= nil
                    then ast.offset + ast.limit else nil

                local function nextDriver()
                    if driverIterator ~= nil then return driverIterator.next() end
                    driverPosition += 1
                    if driverRows == nil then return nil end
                    return driverRows[driverPosition]
                end

                local function lookupRows(key)
                    if key == lastKey then return lastMatches end
                    local lookupRequest = request
                    if joinedLimit ~= nil then
                        lookupRequest = table.clone(request)
                        lookupRequest.limitHint = math.max(joinedLimit - yielded, 0)
                    end
                    local looked = provider.lookup(lookupColumn, key, lookupRequest)
                    local rows = looked
                    if type(looked) == 'table' and looked._jessqlScan == 'v1' then rows = looked.rows end
                    if rows == nil then rows = {} end
                    lastKey = key
                    lastMatches = rows
                    return rows
                end

                indexedJoinIterator = {
                    next = function()
                        while true do
                            if joinedLimit ~= nil and yielded >= joinedLimit then return nil end
                            if currentMatches ~= nil then
                                matchPosition += 1
                                local matched = currentMatches[matchPosition]
                                if matched ~= nil then
                                    yielded += 1
                                    if lookupSource == 1 then return { matched, currentDriver } end
                                    return { currentDriver, matched }
                                end
                                currentMatches = nil
                            end

                            currentDriver = nextDriver()
                            if currentDriver == nil then return nil end
                            local key = currentDriver[driverColumn]
                            if key ~= nil then
                                currentMatches = lookupRows(key)
                                matchPosition = 0
                            end
                        end
                    end,
                }
            end
        end

        local contexts = if directSingle then rowsBySource[1] else nil
        if indexedJoinIterator == nil then
        for ji, join in ast.joins do
            local sourceIndex = ji + 1
            local rhs = rowsBySource[sourceIndex]
            local on = joinFns[ji]
            local joinPlan = joinPlans[ji]
            local nextContexts = {}
            if ji == 1 and not directSingle and joinPlan.strategy == 'index-left' then
                local provider = sources[1].provider
                local request = scanRequests[1]
                local cache = {}
                local missing = {}
                local driverMeta = scanMeta[2]
                local driverOrdered = #orderFns == 0 or (indexedDriverOrder ~= nil and driverMeta ~= nil and driverMeta.ordered == true)
                local stopAfter = if driverOrdered and ast.limit ~= nil and not aggregate then ast.offset + ast.limit else nil
                local done = stopAfter == 0
                local function consumeRight(right: any)
                    local key = right[joinPlan.rightColumn]
                    if key ~= nil then
                        local leftRows = cache[key]
                        if leftRows == nil and not missing[key] then
                            local lookupRequest = request
                            if stopAfter ~= nil and residualWhere == nil then
                                lookupRequest = table.clone(request)
                                lookupRequest.limitHint = stopAfter - #nextContexts
                            end
                            local looked = provider.lookup(joinPlan.leftColumn, key, lookupRequest)
                            if looked ~= nil then
                                leftRows = if type(looked) == 'table' and looked._jessqlScan == 'v1' then looked.rows else looked
                            end
                            if leftRows == nil or #leftRows == 0 then missing[key] = true else cache[key] = leftRows end
                        end
                        if leftRows ~= nil then
                            for _, leftRow in leftRows do
                                local ctx = { leftRow, right }
                                if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                                    nextContexts[#nextContexts+1] = ctx
                                    if stopAfter ~= nil and #nextContexts >= stopAfter then done = true; break end
                                end
                            end
                        end
                    end
                end
                local driverIter = rowIterators[2]
                if driverIter ~= nil then
                    while not done do
                        local right = driverIter.next()
                        if right == nil then break end
                        consumeRight(right)
                    end
                else
                    for _, right in rowsBySource[2] do
                        if done then break end
                        consumeRight(right)
                    end
                end
                residualWhere = nil
                if #orderFns > 0 and driverOrdered then orderHandled = true end
            elseif ji == 1 and not directSingle and joinPlan.strategy == 'index-right' then
                local provider = sources[2].provider
                local request = scanRequests[2]
                local cache = {}
                local missing = {}
                local driverMeta = scanMeta[1]
                local driverOrdered = #orderFns == 0 or (indexedDriverOrder ~= nil and driverMeta ~= nil and driverMeta.ordered == true)
                local stopAfter = if driverOrdered and ast.limit ~= nil and not aggregate then ast.offset + ast.limit else nil
                local done = stopAfter == 0
                local function consumeLeft(leftRow: any)
                    local key = leftRow[joinPlan.leftColumn]
                    if key ~= nil then
                        local rightRows = cache[key]
                        if rightRows == nil and not missing[key] then
                            local lookupRequest = request
                            if stopAfter ~= nil and residualWhere == nil then
                                lookupRequest = table.clone(request)
                                lookupRequest.limitHint = stopAfter - #nextContexts
                            end
                            local looked = provider.lookup(joinPlan.rightColumn, key, lookupRequest)
                            if looked ~= nil then
                                rightRows = if type(looked) == 'table' and looked._jessqlScan == 'v1' then looked.rows else looked
                            end
                            if rightRows == nil or #rightRows == 0 then missing[key] = true else cache[key] = rightRows end
                        end
                        if rightRows ~= nil then
                            for _, right in rightRows do
                                local ctx = { leftRow, right }
                                if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                                    nextContexts[#nextContexts+1] = ctx
                                    if stopAfter ~= nil and #nextContexts >= stopAfter then done = true; break end
                                end
                            end
                        end
                    end
                end
                local driverIter = rowIterators[1]
                if driverIter ~= nil then
                    while not done do
                        local leftRow = driverIter.next()
                        if leftRow == nil then break end
                        consumeLeft(leftRow)
                    end
                else
                    for _, leftRow in rowsBySource[1] do
                        if done then break end
                        consumeLeft(leftRow)
                    end
                end
                residualWhere = nil
                if #orderFns > 0 and driverOrdered then orderHandled = true end
            elseif ji == 1 and not directSingle and joinPlan.strategy == 'hash' then
                local buckets = {}
                local duplicateBuckets = {}
                for _, right in rhs do
                    local key = right[joinPlan.rightColumn]
                    if key ~= nil then
                        local first = buckets[key]
                        if first == nil then
                            buckets[key] = right
                        else
                            local bucket = duplicateBuckets[key]
                            if bucket == nil then bucket = { first, right }; duplicateBuckets[key] = bucket
                            else bucket[#bucket+1] = right end
                        end
                    end
                end
                for _, leftRow in rowsBySource[1] do
                    local key = leftRow[joinPlan.leftColumn]
                    local first = if key == nil then nil else buckets[key]
                    if first ~= nil then
                        local bucket = duplicateBuckets[key]
                        if bucket ~= nil then
                            for _, right in bucket do nextContexts[#nextContexts+1] = { leftRow, right } end
                        else
                            nextContexts[#nextContexts+1] = { leftRow, first }
                        end
                    elseif join.kind == 'left' then
                        nextContexts[#nextContexts+1] = { leftRow }
                    end
                end
            elseif ji == 1 and not directSingle then
                for _, leftRow in rowsBySource[1] do
                    local matched = false
                    for _, right in rhs do
                        local ctx = { leftRow, right }
                        if sqlTruthy(on(ctx, nil, params)) then nextContexts[#nextContexts+1]=ctx; matched=true end
                    end
                    if not matched and join.kind == 'left' then nextContexts[#nextContexts+1] = { leftRow } end
                end
            elseif joinPlan.strategy == 'hash' then
                local buckets = {}
                local duplicateBuckets = {}
                for _, right in rhs do
                    local key = right[joinPlan.rightColumn]
                    if key ~= nil then
                        local first = buckets[key]
                        if first == nil then
                            buckets[key] = right
                        else
                            local bucket = duplicateBuckets[key]
                            if bucket == nil then bucket = { first, right }; duplicateBuckets[key] = bucket
                            else bucket[#bucket+1] = right end
                        end
                    end
                end
                for _, left in contexts do
                    local sourceRow = left[joinPlan.leftSourceIndex]
                    local key = if sourceRow == nil then nil else sourceRow[joinPlan.leftColumn]
                    local first = if key == nil then nil else buckets[key]
                    if first ~= nil then
                        local bucket = duplicateBuckets[key]
                        if bucket ~= nil then
                            for _, right in bucket do
                                local ctx = table.clone(left); ctx[sourceIndex] = right
                                nextContexts[#nextContexts+1] = ctx
                            end
                        else
                            local right = first
                            local ctx = table.clone(left); ctx[sourceIndex] = right
                            nextContexts[#nextContexts+1] = ctx
                        end
                    elseif join.kind == 'left' then
                        local ctx = table.clone(left); ctx[sourceIndex] = nil; nextContexts[#nextContexts+1] = ctx
                    end
                end
            else
                for _, left in contexts do
                    local matched = false
                    for _, right in rhs do
                        local ctx = table.clone(left); ctx[sourceIndex] = right
                        if sqlTruthy(on(ctx, nil, params)) then nextContexts[#nextContexts+1]=ctx; matched=true end
                    end
                    if not matched and join.kind == 'left' then
                        local ctx = table.clone(left); ctx[sourceIndex] = nil; nextContexts[#nextContexts+1]=ctx
                    end
                end
            end
            contexts = nextContexts
        end
        end

        -- Single-source providers may stream rows instead of materializing their complete input.
        -- Joins keep the existing materialized/index-driver machinery; direct queries consume the
        -- provider iterator exactly once in the aggregate/projection stage below.
        local directIter = if directSingle then rowIterators[1] else nil
        local volatileContext = directIter ~= nil and directIter.volatileRows == true
        local function retainContext(ctx)
            if volatileContext then return table.clone(ctx) end
            return ctx
        end

        local function eachContext(visit)
            if indexedJoinIterator ~= nil then
                while true do
                    local ctx = indexedJoinIterator.next()
                    if ctx == nil then break end
                    if visit(ctx) == false then break end
                end
            elseif directIter ~= nil then
                while true do
                    local row = directIter.next()
                    if row == nil then break end
                    if visit(row) == false then break end
                end
            else
                for _, ctx in contexts do
                    if visit(ctx) == false then break end
                end
            end
        end

        local decorateOrder = nil
        local orderBefore = nil
        if #orderFns > 0 then
            decorateOrder = function(u)
                local keys = table.create(#orderFns)
                for i, o in orderFns do keys[i] = o.fn(u.ctx, u.group, params) end
                u.order = keys
            end
            orderBefore = function(a,b)
                for i, o in orderFns do
                    local x,y = a.order[i], b.order[i]
                    if x ~= y then
                        if x == nil then return not o.desc end
                        if y == nil then return o.desc end
                        if o.desc then return x > y else return x < y end
                    end
                end
                return false
            end
        end

        local units = {}
        local orderAlreadySorted = false
        if aggregate then
            local NIL_KEY = {}
            local order = {}

            local function newGroup(first, groupKey)
                if compactGroupColumn == nil and first ~= nil then first = retainContext(first) end
                local group = table.create(#aggregateSpecs)
                group.first = if compactGroupColumn == nil then first else nil
                if compactGroupColumn ~= nil then group.groupKey = groupKey end
                if hasAvg then group.avgCounts = table.create(#aggregateSpecs) end
                for i, spec in aggregateSpecs do
                    if spec.name == 'COUNT' or spec.name == 'AVG' then group[i] = 0 end
                    if spec.name == 'AVG' then group.avgCounts[i] = 0 end
                end
                return group
            end

            local function accumulate(g, ctx)
                if compactGroupColumn == nil and g.first == nil then g.first = retainContext(ctx) end
                for i, spec in aggregateSpecs do
                    if spec.name == 'COUNT' then
                        if spec.star or spec.argFn(ctx, nil, params) ~= nil then g[i] += 1 end
                    else
                        local v = spec.argFn(ctx, nil, params)
                        if v ~= nil then
                            if spec.name == 'SUM' then
                                g[i] = (g[i] or 0) + v
                            elseif spec.name == 'AVG' then
                                g[i] += v; g.avgCounts[i] += 1
                            elseif spec.name == 'MIN' then
                                if g[i] == nil or v < g[i] then g[i] = v end
                            elseif spec.name == 'MAX' then
                                if g[i] == nil or v > g[i] then g[i] = v end
                            end
                        end
                    end
                end
            end

            if #groupFns == 0 then
                local g = newGroup(nil)
                order[1] = g
                eachContext(function(ctx)
                    if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then accumulate(g, ctx) end
                end)
            else
                local root = {}
                eachContext(function(ctx)
                    if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                        local node = root
                        local g = nil
                        for gi, f in groupFns do
                            local key = f(ctx, nil, params)
                            if key == nil then key = NIL_KEY end
                            if gi == #groupFns then
                                g = node[key]
                                if g == nil then
                                    g = newGroup(ctx, if key == NIL_KEY then nil else key)
                                    node[key] = g
                                    order[#order+1] = g
                                end
                            else
                                local nextNode = node[key]
                                if nextNode == nil then nextNode = {}; node[key] = nextNode end
                                node = nextNode
                            end
                        end
                        accumulate(g, ctx)
                    end
                end)
            end

            local function groupContext(group)
                if compactGroupColumn == nil then
                    return group.first or (if directSingle then {} else table.create(#sources))
                end
                local sourceIndex = compactGroupColumn.sourceIndex
                local row = { [compactGroupColumn.column] = group.groupKey }
                if directSingle then return row end
                local ctx = table.create(#sources)
                ctx[sourceIndex] = row
                return ctx
            end

            local keep = if #orderFns > 0 and ast.limit ~= nil then ast.offset + ast.limit else nil
            local heap = if keep ~= nil and keep > 0 then table.create(keep) else nil
            local function worse(left, right) return orderBefore(right, left) end
            local function siftUp(index)
                while index > 1 do
                    local parent = math.floor(index / 2)
                    if not worse(heap[index], heap[parent]) then break end
                    heap[index], heap[parent] = heap[parent], heap[index]
                    index = parent
                end
            end
            local function siftDown(index)
                while true do
                    local left = index * 2
                    if left > #heap then return end
                    local right = left + 1
                    local worst = left
                    if right <= #heap and worse(heap[right], heap[left]) then worst = right end
                    if not worse(heap[worst], heap[index]) then return end
                    heap[index], heap[worst] = heap[worst], heap[index]
                    index = worst
                end
            end

            for _, g in order do
                for i, spec in aggregateSpecs do
                    if spec.name == 'AVG' then
                        local n = g.avgCounts[i]
                        g[i] = if n == 0 then nil else g[i] / n
                    end
                end
                local ctx = groupContext(g)
                if havingFn and not sqlTruthy(havingFn(ctx, g, params)) then continue end
                local unit = { ctx=ctx, group=g }
                if heap ~= nil then
                    decorateOrder(unit)
                    if #heap < keep then
                        heap[#heap+1] = unit
                        siftUp(#heap)
                    elseif orderBefore(unit, heap[1]) then
                        heap[1] = unit
                        siftDown(1)
                    end
                elseif keep ~= 0 then
                    units[#units+1] = unit
                end
            end
            if heap ~= nil then
                units = heap
                table.sort(units, orderBefore)
                orderAlreadySorted = true
            elseif keep == 0 then
                units = {}
                orderAlreadySorted = true
            end
        else
            local stopAfter = if ast.limit ~= nil then ast.offset + ast.limit else nil
            if #orderFns == 0 or orderHandled then
                if stopAfter ~= 0 then
                    eachContext(function(ctx)
                        if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                            units[#units+1] = { ctx=retainContext(ctx), group=nil }
                            if stopAfter ~= nil and #units >= stopAfter then return false end
                        end
                    end)
                end
            elseif stopAfter ~= nil then
                if stopAfter > 0 then
                    local heap = table.create(stopAfter)
                    if #orderFns == 1 then
                        local order = orderFns[1]
                        local function beforeKey(x, y)
                            if x ~= y then
                                if x == nil then return not order.desc end
                                if y == nil then return order.desc end
                                if order.desc then return x > y else return x < y end
                            end
                            return false
                        end
                        local function worse(a, b) return beforeKey(b.orderKey, a.orderKey) end
                        local function siftUp(index)
                            while index > 1 do
                                local parent = math.floor(index / 2)
                                if not worse(heap[index], heap[parent]) then break end
                                heap[index], heap[parent] = heap[parent], heap[index]
                                index = parent
                            end
                        end
                        local function siftDown(index)
                            while true do
                                local left = index * 2
                                if left > #heap then return end
                                local right = left + 1
                                local worst = left
                                if right <= #heap and worse(heap[right], heap[left]) then worst = right end
                                if not worse(heap[worst], heap[index]) then return end
                                heap[index], heap[worst] = heap[worst], heap[index]
                                index = worst
                            end
                        end
                        eachContext(function(ctx)
                            if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                                local key = order.fn(ctx, nil, params)
                                if #heap < stopAfter then
                                    local u = { ctx=retainContext(ctx), group=nil, orderKey=key }
                                    heap[#heap+1] = u
                                    siftUp(#heap)
                                elseif beforeKey(key, heap[1].orderKey) then
                                    heap[1] = { ctx=retainContext(ctx), group=nil, orderKey=key }
                                    siftDown(1)
                                end
                            end
                        end)
                        units = heap
                        table.sort(units, function(a,b) return beforeKey(a.orderKey, b.orderKey) end)
                    else
                        local function worse(a, b) return orderBefore(b, a) end
                        local function siftUp(index)
                            while index > 1 do
                                local parent = math.floor(index / 2)
                                if not worse(heap[index], heap[parent]) then break end
                                heap[index], heap[parent] = heap[parent], heap[index]
                                index = parent
                            end
                        end
                        local function siftDown(index)
                            while true do
                                local left = index * 2
                                if left > #heap then return end
                                local right = left + 1
                                local worst = left
                                if right <= #heap and worse(heap[right], heap[left]) then worst = right end
                                if not worse(heap[worst], heap[index]) then return end
                                heap[index], heap[worst] = heap[worst], heap[index]
                                index = worst
                            end
                        end
                        eachContext(function(ctx)
                            if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                                local u = { ctx=retainContext(ctx), group=nil }
                                decorateOrder(u)
                                if #heap < stopAfter then
                                    heap[#heap+1] = u
                                    siftUp(#heap)
                                elseif orderBefore(u, heap[1]) then
                                    heap[1] = u
                                    siftDown(1)
                                end
                            end
                        end)
                        units = heap
                        table.sort(units, orderBefore)
                    end
                end
                orderAlreadySorted = true
            else
                eachContext(function(ctx)
                    if not residualWhere or sqlTruthy(residualWhere(ctx, nil, params)) then
                        units[#units+1] = { ctx=retainContext(ctx), group=nil }
                    end
                end)
            end
        end

        if #orderFns > 0 and not orderHandled and not orderAlreadySorted then
            local keep = if ast.limit ~= nil then ast.offset + ast.limit else nil
            if keep ~= nil and keep < #units then
                if keep == 0 then
                    units = {}
                else
                    local heap = table.create(keep)
                    local function worse(a, b) return orderBefore(b, a) end
                    local function siftUp(index)
                        while index > 1 do
                            local parent = math.floor(index / 2)
                            if not worse(heap[index], heap[parent]) then break end
                            heap[index], heap[parent] = heap[parent], heap[index]
                            index = parent
                        end
                    end
                    local function siftDown(index)
                        while true do
                            local left = index * 2
                            if left > #heap then return end
                            local right = left + 1
                            local worst = left
                            if right <= #heap and worse(heap[right], heap[left]) then worst = right end
                            if not worse(heap[worst], heap[index]) then return end
                            heap[index], heap[worst] = heap[worst], heap[index]
                            index = worst
                        end
                    end
                    for _, u in units do
                        decorateOrder(u)
                        if #heap < keep then
                            heap[#heap+1] = u
                            siftUp(#heap)
                        elseif orderBefore(u, heap[1]) then
                            heap[1] = u
                            siftDown(1)
                        end
                    end
                    units = heap
                    table.sort(units, orderBefore)
                end
            else
                for _, u in units do decorateOrder(u) end
                table.sort(units, orderBefore)
            end
        end

        local first = ast.offset + 1
        local last = #units
        if ast.limit ~= nil then last = math.min(last, ast.offset + ast.limit) end
        local resultRows = table.create(math.max(0, last-first+1))
        for ui = first, last do
            local u = units[ui]
            local row = {}
            for i, fn in selectors do
                local v = fn(u.ctx, u.group, params)
                if v ~= nil then row[resultColumns[i]] = v end
            end
            resultRows[#resultRows+1] = row
        end
        return { columns=resultColumns, rows=resultRows }
    end
    plan.ast = ast
    plan.columns = resultColumns
    plan.parameterCount = ast.params
    function plan.explain()
        local joins = {}
        for i, j in ast.joins do joins[i] = { kind=j.kind, table=j.source.name, alias=j.source.alias, strategy=joinPlans[i].strategy } end
        local scans = {}
        for i, source in sources do scans[i] = { table=source.name, alias=source.alias, columns=neededColumns[i] } end
        return { scans=scans, joins=joins, grouped=aggregate, compactGroup=compactGroupColumn ~= nil, aggregateCount=#aggregateSpecs, providerCount=directProviderCount, parameterCount=ast.params }
    end
    return plan
end

function M.new()
    local db = { _tables = {} }

    function db:register(name, provider)
        if type(name) ~= 'string' or name == '' then error('jessql: table name must be a string', 2) end
        if type(provider) ~= 'table' or type(provider.scan) ~= 'function' then error('jessql: provider needs scan(request)', 2) end
        if type(provider.columns) ~= 'table' then error('jessql: provider needs columns', 2) end
        self._tables[lower(name)] = provider
        return self
    end

    function db:table(name, rows, columns)
        columns = columns or schemaFromRows(rows)
        return self:register(name, {
            columns = columns,
            count = function() return #rows end,
            scan = function(_request) return rows end,
        })
    end

    function db:prepare(sql)
        return prepare(self, sql)
    end

    function db:query(sql, params)
        return prepare(self, sql).run(params)
    end

    function db:tables()
        local out = {}
        for name, p in self._tables do out[#out+1] = { name=name, columns=p.columns } end
        table.sort(out, function(a,b) return a.name < b.name end)
        return out
    end

    return db
end

M.prepare = prepare
return M
