--!native

local parser = require('@jessql/parser')

local engine = {}
local AGG = { COUNT = true, SUM = true, AVG = true, MIN = true, MAX = true }

local function lower(text) return string.lower(text) end

local function hasAggregate(expr)
    if expr == nil then return false end
    if expr.tag == 'call' and AGG[expr.name] then return true end
    if expr.tag == 'binary' then return hasAggregate(expr.left) or hasAggregate(expr.right) end
    if expr.tag == 'unary' or expr.tag == 'isnull' then return hasAggregate(expr.expr) end

    if expr.tag == 'call' then
        for _, argument in expr.args do
            if hasAggregate(argument) then return true end
        end
    end

    return false
end

local function sqlTruthy(value) return value ~= nil and value ~= false end

local function like(value, pattern)
    if value == nil or pattern == nil then return nil end
    value = tostring(value)
    pattern = tostring(pattern)
    local valueIndex, patternIndex, starValueIndex, starPatternIndex = 1, 1, nil, nil

    while valueIndex <= #value do
        local patternChar = string.sub(pattern, patternIndex, patternIndex)

        if patternChar == '_' then
            valueIndex += 1
            patternIndex += 1
        elseif patternChar == '%' then
            starPatternIndex = patternIndex + 1
            starValueIndex = valueIndex
            patternIndex += 1
        elseif patternChar ~= '' and string.sub(value, valueIndex, valueIndex) == patternChar then
            valueIndex += 1
            patternIndex += 1
        elseif starPatternIndex ~= nil then
            starValueIndex += 1
            valueIndex = starValueIndex
            patternIndex = starPatternIndex
        else
            return false
        end
    end

    while string.sub(pattern, patternIndex, patternIndex) == '%' do patternIndex += 1 end
    return patternIndex > #pattern
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
        local length = #prefix

        return function(value)
            if value == nil then return nil end
            value = tostring(value)
            return #value >= length and string.sub(value, 1, length) == prefix
        end
    elseif firstPercent == 1 then
        local suffix = string.sub(pattern, 2)
        local length = #suffix

        return function(value)
            if value == nil then return nil end
            value = tostring(value)
            return #value >= length and string.sub(value, #value - length + 1) == suffix
        end
    end

    return nil
end

local function bindColumn(expr, sources)
    if expr.sourceIndex ~= nil and expr.boundName ~= nil then return expr.sourceIndex, expr.boundName end
    local name = lower(expr.name)
    local sourceIndex = nil

    if expr.qualifier then
        local qualifier = lower(expr.qualifier)

        for index, source in sources do
            if lower(source.alias) == qualifier or lower(source.name) == qualifier then
                sourceIndex = index
                break
            end
        end

        if sourceIndex == nil then error('jessql: unknown table/alias ' .. expr.qualifier, 0) end
    else
        local hit = nil

        for index, source in sources do
            if source.columnSet[name] then
                if hit ~= nil then error('jessql: ambiguous column ' .. expr.name, 0) end
                hit = index
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
        return function(_context, _group, _params) return value end
    elseif tag == 'param' then
        local index = expr.index
        return function(_context, _group, params) return params[index] end
    elseif tag == 'column' then
        local sourceIndex, boundName = bindColumn(expr, sources)
        local key = boundName
        local slot = sourceIndex

        if directSingle then
            return function(row, _group, _params) return row[key] end
        end

        return function(context, _group, _params)
            local row = context[slot]
            return if row == nil then nil else row[key]
        end
    elseif tag == 'unary' then
        local operand = compileExpr(expr.expr, sources, directSingle, aggregateIds)

        if expr.op == 'NOT' then
            return function(context, group, params)
                local value = operand(context, group, params)
                return if value == nil then nil else not sqlTruthy(value)
            end
        end

        if expr.op == '-' then
            return function(context, group, params)
                local value = operand(context, group, params)
                return if value == nil then nil else -value
            end
        end

        return function(context, group, params) return operand(context, group, params) end
    elseif tag == 'isnull' then
        local operand = compileExpr(expr.expr, sources, directSingle, aggregateIds)

        if expr.negated then
            return function(context, group, params) return operand(context, group, params) ~= nil end
        end

        return function(context, group, params) return operand(context, group, params) == nil end
    elseif tag == 'binary' then
        local leftOperand = compileExpr(expr.left, sources, directSingle, aggregateIds)
        local rightOperand = compileExpr(expr.right, sources, directSingle, aggregateIds)
        local op = expr.op

        if op == 'AND' then
            return function(context, group, params)
                local left = leftOperand(context, group, params)
                if left == false then return false end
                local right = rightOperand(context, group, params)
                if right == false then return false end
                if left == nil or right == nil then return nil end
                return sqlTruthy(left) and sqlTruthy(right)
            end
        end

        if op == 'OR' then
            return function(context, group, params)
                local left = leftOperand(context, group, params)
                if sqlTruthy(left) then return true end
                local right = rightOperand(context, group, params)
                if sqlTruthy(right) then return true end
                if left == nil or right == nil then return nil end
                return false
            end
        end

        if op == '=' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left == right
            end
        end

        if op == '!=' or op == '<>' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left ~= right
            end
        end

        if op == '<' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left < right
            end
        end

        if op == '<=' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left <= right
            end
        end

        if op == '>' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left > right
            end
        end

        if op == '>=' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left >= right
            end
        end

        if op == '+' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left + right
            end
        end

        if op == '-' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left - right
            end
        end

        if op == '*' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left * right
            end
        end

        if op == '/' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left / right
            end
        end

        if op == '%' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return left % right
            end
        end

        if op == '||' then
            return function(context, group, params)
                local left, right = leftOperand(context, group, params), rightOperand(context, group, params)
                if left == nil or right == nil then return nil end
                return tostring(left) .. tostring(right)
            end
        end

        if op == 'LIKE' then
            if expr.right.tag == 'literal' then
                local fast = compileLiteralLike(expr.right.value)

                if fast ~= nil then
                    return function(context, group, params) return fast(leftOperand(context, group, params)) end
                end
            end

            return function(context, group, params)
                return like(leftOperand(context, group, params), rightOperand(context, group, params))
            end
        end

        error('jessql: unsupported operator ' .. tostring(op), 0)
    elseif tag == 'call' then
        local name = expr.name

        if AGG[name] and aggregateIds ~= nil then
            local id = aggregateIds[expr]
            if id == nil then error('jessql: aggregate expression was not planned', 0) end
            return function(_context, group, _params) return group[id] end
        elseif AGG[name] then
            local arg = nil

            if not expr.star then
                if #expr.args ~= 1 then error('jessql: aggregate ' .. name .. ' needs one argument', 0) end
                arg = compileExpr(expr.args[1], sources, directSingle, aggregateIds)
            end

            if name == 'COUNT' then
                if expr.star then
                    return function(_context, group, _params) return #group end
                end

                return function(_context, group, params)
                    local count = 0

                    for _, member in group do
                        if arg(member, group, params) ~= nil then count += 1 end
                    end

                    return count
                end
            elseif name == 'SUM' then
                return function(_context, group, params)
                    local total = nil

                    for _, member in group do
                        local value = arg(member, group, params)
                        if value ~= nil then total = (total or 0) + value end
                    end

                    return total
                end
            elseif name == 'AVG' then
                return function(_context, group, params)
                    local total, count = 0, 0

                    for _, member in group do
                        local value = arg(member, group, params)

                        if value ~= nil then
                            total += value
                            count += 1
                        end
                    end

                    return if count == 0 then nil else total / count
                end
            elseif name == 'MIN' then
                return function(_context, group, params)
                    local best = nil

                    for _, member in group do
                        local value = arg(member, group, params)
                        if value ~= nil and (best == nil or value < best) then best = value end
                    end

                    return best
                end
            else
                return function(_context, group, params)
                    local best = nil

                    for _, member in group do
                        local value = arg(member, group, params)
                        if value ~= nil and (best == nil or value > best) then best = value end
                    end

                    return best
                end
            end
        end

        local args = table.create(#expr.args)

        for index, argument in expr.args do
            args[index] = compileExpr(argument, sources, directSingle, aggregateIds)
        end

        if name == 'LOWER' then
            return function(context, group, params)
                local value = args[1](context, group, params)
                return if value == nil then nil else string.lower(tostring(value))
            end
        elseif name == 'UPPER' then
            return function(context, group, params)
                local value = args[1](context, group, params)
                return if value == nil then nil else string.upper(tostring(value))
            end
        elseif name == 'LENGTH' then
            return function(context, group, params)
                local value = args[1](context, group, params)
                return if value == nil then nil else #tostring(value)
            end
        elseif name == 'ABS' then
            return function(context, group, params)
                local value = args[1](context, group, params)
                return if value == nil then nil else math.abs(value)
            end
        elseif name == 'COALESCE' then
            return function(context, group, params)
                for _, operand in args do
                    local value = operand(context, group, params)
                    if value ~= nil then return value end
                end

                return nil
            end
        else
            error('jessql: unknown function ' .. name, 0)
        end
    end

    error('jessql: cannot compile expression ' .. tostring(tag), 0)
end

local function schemaFromRows(rows)
    local columns, seen = {}, {}

    for index = 1, math.min(#rows, 32) do
        for key in rows[index] do
            if type(key) == 'string' and not seen[lower(key)] then
                seen[lower(key)] = true
                columns[#columns + 1] = key
            end
        end
    end

    table.sort(columns)
    return columns
end

local function makeSource(db, spec, index)
    local provider = db._tables[lower(spec.name)]
    if provider == nil then error('jessql: unknown table ' .. spec.name, 0) end
    local columns = provider.columns
    local columnMap, columnSet = {}, {}

    for _, column in columns do
        columnMap[lower(column)] = column
        columnSet[lower(column)] = true
    end

    return {
        name = spec.name,
        alias = spec.alias,
        provider = provider,
        columns = columns,
        columnMap = columnMap,
        columnSet = columnSet,
        index = index,
    }
end

local function constraintFrom(expr)
    if expr == nil then return {}, true end
    local out = {}

    local function walk(node)
        if node.tag == 'binary' and node.op == 'AND' then return walk(node.left) and walk(node.right) end
        if node.tag ~= 'binary' then return false end
        local op = node.op
        if op ~= '=' and op ~= '!=' and op ~= '<>' and op ~= '<' and op ~= '<=' and op ~= '>' and op ~= '>=' and op ~= 'LIKE' then return false end
        local col, lit = node.left, node.right
        local flip = false

        if col.tag ~= 'column' or (lit.tag ~= 'literal' and lit.tag ~= 'param') then
            col, lit = node.right, node.left
            flip = true
        end

        if col.tag ~= 'column' or (lit.tag ~= 'literal' and lit.tag ~= 'param') or col.sourceIndex == nil then return false end

        if flip then
            if op == '<' then
                op = '>'
            elseif op == '>' then
                op = '<'
            elseif op == '<=' then
                op = '>='
            elseif op == '>=' then
                op = '<='
            end
        end

        out[#out + 1] = { sourceIndex = col.sourceIndex, column = col.boundName, op = op, value = lit.value, param = lit.index }
        return true
    end

    local complete = walk(expr)
    return out, complete
end

local function conjuncts(expr)
    local out = {}

    local function walk(node)
        if node ~= nil and node.tag == 'binary' and node.op == 'AND' then
            walk(node.left)
            walk(node.right)
        elseif node ~= nil then
            out[#out + 1] = node
        end
    end

    walk(expr)
    return out
end

local function singleSourceOf(expr)
    local source = nil
    local mixed = false

    local function walk(node)
        if node == nil or mixed then return end

        if node.tag == 'column' then
            local sourceIndex = node.sourceIndex

            if sourceIndex ~= nil then
                if source == nil then
                    source = sourceIndex
                elseif source ~= sourceIndex then
                    mixed = true
                end
            end
        elseif node.tag == 'binary' then
            walk(node.left)
            walk(node.right)
        elseif node.tag == 'unary' or node.tag == 'isnull' then
            walk(node.expr)
        elseif node.tag == 'call' then
            for _, argument in node.args do walk(argument) end
        end
    end

    walk(expr)
    return if mixed then nil else source
end

local function valueKey(value)
    if value == nil then return 'N;' end
    local valueType = type(value)
    if valueType == 'string' then return 'S' .. #value .. ':' .. value end
    if valueType == 'number' then return 'D' .. tostring(value) .. ';' end
    if valueType == 'boolean' then return if value then 'B1;' else 'B0;' end
    return 'O' .. tostring(value) .. ';'
end

local function prepare(db, sql)
    local ast = parser.parse(sql)
    local sources = { makeSource(db, ast.from, 1) }
    for index, join in ast.joins do sources[#sources + 1] = makeSource(db, join.source, index + 1) end
    local directSingle = #sources == 1

    if hasAggregate(ast.where) then error('jessql: aggregates are not allowed in WHERE', 0) end

    for _, node in ast.groupBy do
        if hasAggregate(node) then error('jessql: aggregates are not allowed in GROUP BY', 0) end
    end

    for _, join in ast.joins do
        if hasAggregate(join.on) then error('jessql: aggregates are not allowed in JOIN ON', 0) end
    end

    local aggregateIds, aggregateSpecs, aggregateByKey = {}, {}, {}

    local function exprKey(node)
        if node == nil then return 'nil' end
        if node.tag == 'literal' then return 'lit:' .. type(node.value) .. ':' .. tostring(node.value) end
        if node.tag == 'param' then return 'param:' .. tostring(node.index) end
        if node.tag == 'column' then return 'col:' .. lower(node.qualifier or '') .. '.' .. lower(node.name) end
        if node.tag == 'star' then return 'star:' .. lower(node.qualifier or '') end
        if node.tag == 'unary' then return 'u:' .. node.op .. '(' .. exprKey(node.expr) .. ')' end
        if node.tag == 'isnull' then return 'null:' .. tostring(node.negated) .. '(' .. exprKey(node.expr) .. ')' end
        if node.tag == 'binary' then return 'b:' .. node.op .. '(' .. exprKey(node.left) .. ',' .. exprKey(node.right) .. ')' end

        if node.tag == 'call' then
            local parts = table.create(#node.args)
            for index, argument in node.args do parts[index] = exprKey(argument) end
            return 'call:' .. node.name .. ':' .. tostring(node.star) .. '(' .. table.concat(parts, ',') .. ')'
        end

        return tostring(node.tag)
    end

    local function registerAggregates(node)
        if node == nil then return end

        if node.tag == 'call' and AGG[node.name] then
            local key = exprKey(node)
            local id = aggregateByKey[key]

            if id == nil then
                id = #aggregateSpecs + 1
                aggregateByKey[key] = id
                aggregateSpecs[id] = { name = node.name, star = node.star, expr = node }
            end

            aggregateIds[node] = id
            return
        elseif node.tag == 'binary' then
            registerAggregates(node.left)
            registerAggregates(node.right)
        elseif node.tag == 'unary' or node.tag == 'isnull' then
            registerAggregates(node.expr)
        elseif node.tag == 'call' then
            for _, argument in node.args do registerAggregates(argument) end
        end
    end

    for _, item in ast.select do registerAggregates(item.expr) end
    registerAggregates(ast.having)
    for _, order in ast.orderBy do registerAggregates(order.expr) end

    local whereFn = if ast.where then compileExpr(ast.where, sources, directSingle, nil) else nil
    local whereTermPlans = {}

    if ast.where ~= nil then
        for _, term in conjuncts(ast.where) do
            local _, pushable = constraintFrom(term)
            whereTermPlans[#whereTermPlans + 1] = {
                predicate = compileExpr(term, sources, directSingle, nil),
                sourceIndex = singleSourceOf(term),
                pushable = pushable,
            }
        end
    end

    local sourceWhereFns = table.create(#sources)

    if #sources > 1 and ast.where ~= nil then
        local bySource = table.create(#sources)

        for _, term in conjuncts(ast.where) do
            local sourceIndex = singleSourceOf(term)
            if sourceIndex ~= nil then
                local list = bySource[sourceIndex]

                if list == nil then
                    list = {}
                    bySource[sourceIndex] = list
                end

                list[#list + 1] = compileExpr(term, sources, true, nil)
            end
        end

        for sourceIndex, list in bySource do
            if list ~= nil then
                sourceWhereFns[sourceIndex] = function(row, params)
                    for _, predicate in list do
                        if not sqlTruthy(predicate(row, nil, params)) then return false end
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

    local joinFns, joinPlans = {}, {}

    for index, join in ast.joins do
        joinFns[index] = compileExpr(join.on, sources, directSingle, nil)
        local rightIndex = index + 1
        local node = join.on
        local plan = { strategy = 'nested-loop' }

        if node.tag == 'binary' and node.op == '=' and node.left.tag == 'column' and node.right.tag == 'column' then
            local leftCol, rightCol = node.left, node.right
            if leftCol.sourceIndex == rightIndex and rightCol.sourceIndex < rightIndex then leftCol, rightCol = rightCol, leftCol end

            if leftCol.sourceIndex < rightIndex and rightCol.sourceIndex == rightIndex then
                plan = {
                    strategy = 'hash',
                    leftSourceIndex = leftCol.sourceIndex,
                    leftColumn = leftCol.boundName,
                    rightColumn = rightCol.boundName,
                }

                if #sources == 2 and #ast.joins == 1 and join.kind == 'inner' then
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

        joinPlans[index] = plan
    end

    local groupFns = {}
    for index, node in ast.groupBy do groupFns[index] = compileExpr(node, sources, directSingle, nil) end

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

    for _, spec in aggregateSpecs do
        if spec.name == 'AVG' then
            hasAvg = true
            break
        end
    end

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
            if safe then compactGroupColumn = { sourceIndex = groupedSource, column = groupedName } end
        end
    end

    local selectors, resultColumns, selectorByAlias, selectorSource = {}, {}, {}, {}

    local function addSelector(name, selector, sourceInfo)
        selectors[#selectors + 1] = selector
        resultColumns[#resultColumns + 1] = name
        selectorByAlias[lower(name)] = selector
        selectorSource[lower(name)] = sourceInfo
    end

    for _, item in ast.select do
        local node = item.expr

        if node.tag == 'star' then
            for sourceIndex, source in sources do
                if node.qualifier == nil or lower(node.qualifier) == lower(source.alias) or lower(node.qualifier) == lower(source.name) then
                    for _, column in source.columns do
                        local key = column
                        local slot = sourceIndex
                        local selector

                        if directSingle then
                            selector = function(row) return row[key] end
                        else
                            selector = function(context)
                                local row = context[slot]
                                return if row then row[key] else nil
                            end
                        end

                        addSelector(if directSingle then column else source.alias .. '.' .. column, selector, { sourceIndex = sourceIndex, column = column })
                    end
                end
            end
        else
            local name = item.alias

            if name == nil then
                if node.tag == 'column' then
                    name = node.name
                elseif node.tag == 'call' then
                    name = string.lower(node.name)
                else
                    name = 'expr' .. tostring(#selectors + 1)
                end
            end

            local selector = compileExpr(node, sources, directSingle, aggregateIds)
            local sourceInfo = if node.tag == 'column' and node.sourceIndex ~= nil then { sourceIndex = node.sourceIndex, column = node.boundName } else nil
            addSelector(name, selector, sourceInfo)
        end
    end

    local orderFns, orderSourceInfo = {}, {}

    for index, order in ast.orderBy do
        local evaluate = nil

        if order.expr.tag == 'column' and order.expr.qualifier == nil then
            local key = lower(order.expr.name)
            evaluate = selectorByAlias[key]
            orderSourceInfo[index] = selectorSource[key]
        end

        if evaluate == nil then
            evaluate = compileExpr(order.expr, sources, directSingle, aggregateIds)

            if order.expr.tag == 'column' and order.expr.sourceIndex ~= nil then
                orderSourceInfo[index] = { sourceIndex = order.expr.sourceIndex, column = order.expr.boundName }
            end
        end

        orderFns[index] = { evaluate = evaluate, desc = order.desc }
    end

    local neededSets = {}
    for index = 1, #sources do neededSets[index] = {} end

    local function markExpr(node)
        if node == nil then return end

        if node.tag == 'column' and node.sourceIndex ~= nil then
            neededSets[node.sourceIndex][node.boundName] = true
        elseif node.tag == 'star' then
            for sourceIndex, source in sources do
                if node.qualifier == nil or lower(node.qualifier) == lower(source.alias) or lower(node.qualifier) == lower(source.name) then
                    for _, column in source.columns do neededSets[sourceIndex][column] = true end
                end
            end
        elseif node.tag == 'binary' then
            markExpr(node.left)
            markExpr(node.right)
        elseif node.tag == 'unary' or node.tag == 'isnull' then
            markExpr(node.expr)
        elseif node.tag == 'call' then
            for _, argument in node.args do markExpr(argument) end
        end
    end

    for _, item in ast.select do markExpr(item.expr) end
    markExpr(ast.where)
    markExpr(ast.having)
    for _, node in ast.groupBy do markExpr(node) end
    for _, order in ast.orderBy do markExpr(order.expr) end
    for _, join in ast.joins do markExpr(join.on) end
    local neededColumns = {}

    for sourceIndex, source in sources do
        local needed = {}

        for _, column in source.columns do
            if neededSets[sourceIndex][column] then needed[#needed + 1] = column end
        end

        neededColumns[sourceIndex] = needed
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

        for index, order in ast.orderBy do
            local info = orderSourceInfo[index]

            if info == nil or info.sourceIndex ~= 1 then
                ok = false
                break
            end

            pushed[index] = { column = info.column, desc = order.desc }
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

            for index, order in ast.orderBy do
                local info = orderSourceInfo[index]

                if info == nil or info.sourceIndex ~= indexedDriverSource then
                    ok = false
                    break
                end

                pushed[index] = { column = info.column, desc = order.desc }
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
            return { columns = resultColumns, rows = { row } }
        end

        local rowsBySource = table.create(#sources)
        local rowIterators = table.create(#sources)
        local scanMeta = table.create(#sources)
        local scanRequests = table.create(#sources)
        local skipScan, lazyDriver = {}, {}

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

        for sourceIndex, source in sources do
            local sourceConstraints = {}

            for _, constraint in constraints do
                if constraint.sourceIndex == sourceIndex then
                    sourceConstraints[#sourceConstraints + 1] = {
                        column = constraint.column,
                        op = constraint.op,
                        value = if constraint.param then params[constraint.param] else constraint.value,
                    }
                end
            end

            local request = {
                columns = neededColumns[sourceIndex],
                constraints = sourceConstraints,
                limit = if #sources == 1 and ast.where == nil then ast.limit else nil,
                limitHint = if directSingle and not aggregate and ast.limit ~= nil and ast.where == nil then ast.offset + ast.limit else nil,
                orderBy = if directSingle and sourceIndex == 1 then providerOrder
                    elseif indexedDriverSource == sourceIndex then indexedDriverOrder
                    else nil,
                whereComplete = directSingle and (ast.where == nil or constraintsComplete),
                allowVolatileRows = directSingle,
            }

            scanRequests[sourceIndex] = request

            if lazyDriver[sourceIndex] then
                local iter = source.provider.iterate(request)

                if type(iter) ~= 'table' or iter._jessqlIter ~= 'v1' or type(iter.next) ~= 'function' then
                    error('jessql: provider iterate(request) must return a v1 iterator', 0)
                end

                rowIterators[sourceIndex] = iter
                scanMeta[sourceIndex] = iter
            elseif not skipScan[sourceIndex] then
                local scanned = source.provider.scan(request)

                if type(scanned) == 'table' and scanned._jessqlScan == 'v1' then
                    rowsBySource[sourceIndex] = scanned.rows
                    scanMeta[sourceIndex] = scanned
                else
                    rowsBySource[sourceIndex] = scanned
                end

                local sourceWhere = sourceWhereFns[sourceIndex]
                local meta = scanMeta[sourceIndex]

                if sourceWhere ~= nil and not (meta ~= nil and meta.handledConstraints == true) then
                    local input = rowsBySource[sourceIndex]
                    local filtered = {}

                    for _, row in input do
                        if sourceWhere(row, params) then filtered[#filtered + 1] = row end
                    end

                    rowsBySource[sourceIndex] = filtered
                end
            end
        end

        local residualWhere = whereFn

        if #whereTermPlans > 0 then
            local active = {}

            for _, term in whereTermPlans do
                local meta = if term.sourceIndex ~= nil then scanMeta[term.sourceIndex] else nil

                if not (term.pushable and meta ~= nil and meta.handledConstraints == true) then
                    active[#active + 1] = term.predicate
                end
            end

            if #active == 0 then
                residualWhere = nil
            elseif #active ~= #whereTermPlans then
                residualWhere = function(context, group, runParams)
                    for _, predicate in active do
                        if not sqlTruthy(predicate(context, group, runParams)) then return false end
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
            for joinIndex, join in ast.joins do
                local sourceIndex = joinIndex + 1
                local rhs = rowsBySource[sourceIndex]
                local on = joinFns[joinIndex]
                local joinPlan = joinPlans[joinIndex]
                local nextContexts = {}

                if joinIndex == 1 and not directSingle and joinPlan.strategy == 'index-left' then
                    local provider = sources[1].provider
                    local request = scanRequests[1]
                    local cache, missing = {}, {}
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
                                    local context = { leftRow, right }

                                    if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                                        nextContexts[#nextContexts + 1] = context

                                        if stopAfter ~= nil and #nextContexts >= stopAfter then
                                            done = true
                                            break
                                        end
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
                elseif joinIndex == 1 and not directSingle and joinPlan.strategy == 'index-right' then
                    local provider = sources[2].provider
                    local request = scanRequests[2]
                    local cache, missing = {}, {}
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
                                    local context = { leftRow, right }

                                    if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                                        nextContexts[#nextContexts + 1] = context

                                        if stopAfter ~= nil and #nextContexts >= stopAfter then
                                            done = true
                                            break
                                        end
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
                elseif joinIndex == 1 and not directSingle and joinPlan.strategy == 'hash' then
                    local buckets, duplicateBuckets = {}, {}

                    for _, right in rhs do
                        local key = right[joinPlan.rightColumn]

                        if key ~= nil then
                            local first = buckets[key]

                            if first == nil then
                                buckets[key] = right
                            else
                                local bucket = duplicateBuckets[key]

                                if bucket == nil then
                                    bucket = { first, right }
                                    duplicateBuckets[key] = bucket
                                else
                                    bucket[#bucket + 1] = right
                                end
                            end
                        end
                    end

                    for _, leftRow in rowsBySource[1] do
                        local key = leftRow[joinPlan.leftColumn]
                        local first = if key == nil then nil else buckets[key]

                        if first ~= nil then
                            local bucket = duplicateBuckets[key]

                            if bucket ~= nil then
                                for _, right in bucket do nextContexts[#nextContexts + 1] = { leftRow, right } end
                            else
                                nextContexts[#nextContexts + 1] = { leftRow, first }
                            end
                        elseif join.kind == 'left' then
                            nextContexts[#nextContexts + 1] = { leftRow }
                        end
                    end
                elseif joinIndex == 1 and not directSingle then
                    for _, leftRow in rowsBySource[1] do
                        local matched = false

                        for _, right in rhs do
                            local context = { leftRow, right }

                            if sqlTruthy(on(context, nil, params)) then
                                nextContexts[#nextContexts + 1] = context
                                matched = true
                            end
                        end

                        if not matched and join.kind == 'left' then nextContexts[#nextContexts + 1] = { leftRow } end
                    end
                elseif joinPlan.strategy == 'hash' then
                    local buckets, duplicateBuckets = {}, {}

                    for _, right in rhs do
                        local key = right[joinPlan.rightColumn]

                        if key ~= nil then
                            local first = buckets[key]

                            if first == nil then
                                buckets[key] = right
                            else
                                local bucket = duplicateBuckets[key]

                                if bucket == nil then
                                    bucket = { first, right }
                                    duplicateBuckets[key] = bucket
                                else
                                    bucket[#bucket + 1] = right
                                end
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
                                    local context = table.clone(left)
                                    context[sourceIndex] = right
                                    nextContexts[#nextContexts + 1] = context
                                end
                            else
                                local right = first
                                local context = table.clone(left)
                                context[sourceIndex] = right
                                nextContexts[#nextContexts + 1] = context
                            end
                        elseif join.kind == 'left' then
                            local context = table.clone(left)
                            context[sourceIndex] = nil
                            nextContexts[#nextContexts + 1] = context
                        end
                    end
                else
                    for _, left in contexts do
                        local matched = false

                        for _, right in rhs do
                            local context = table.clone(left)
                            context[sourceIndex] = right

                            if sqlTruthy(on(context, nil, params)) then
                                nextContexts[#nextContexts + 1] = context
                                matched = true
                            end
                        end

                        if not matched and join.kind == 'left' then
                            local context = table.clone(left)
                            context[sourceIndex] = nil
                            nextContexts[#nextContexts + 1] = context
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

        local function retainContext(context)
            if volatileContext then return table.clone(context) end
            return context
        end

        local function eachContext(visit)
            if indexedJoinIterator ~= nil then
                while true do
                    local context = indexedJoinIterator.next()
                    if context == nil then break end
                    if visit(context) == false then break end
                end
            elseif directIter ~= nil then
                while true do
                    local row = directIter.next()
                    if row == nil then break end
                    if visit(row) == false then break end
                end
            else
                for _, context in contexts do
                    if visit(context) == false then break end
                end
            end
        end

        local decorateOrder = nil
        local orderBefore = nil

        if #orderFns > 0 then
            decorateOrder = function(unit)
                local keys = table.create(#orderFns)
                for index, order in orderFns do keys[index] = order.evaluate(unit.context, unit.group, params) end
                unit.order = keys
            end

            orderBefore = function(left, right)
                for index, order in orderFns do
                    local leftKey, rightKey = left.order[index], right.order[index]
                    if leftKey ~= rightKey then
                        if leftKey == nil then return not order.desc end
                        if rightKey == nil then return order.desc end
                        if order.desc then return leftKey > rightKey else return leftKey < rightKey end
                    end
                end

                return false
            end
        end

        local units = {}
        local orderAlreadySorted = false

        if aggregate then
            local nilKey, order = {}, {}

            local function newGroup(first, groupKey)
                if compactGroupColumn == nil and first ~= nil then first = retainContext(first) end
                local group = table.create(#aggregateSpecs)
                group.first = if compactGroupColumn == nil then first else nil
                if compactGroupColumn ~= nil then group.groupKey = groupKey end
                if hasAvg then group.avgCounts = table.create(#aggregateSpecs) end

                for index, spec in aggregateSpecs do
                    if spec.name == 'COUNT' or spec.name == 'AVG' then group[index] = 0 end
                    if spec.name == 'AVG' then group.avgCounts[index] = 0 end
                end

                return group
            end

            local function accumulate(group, context)
                if compactGroupColumn == nil and group.first == nil then group.first = retainContext(context) end

                for index, spec in aggregateSpecs do
                    if spec.name == 'COUNT' then
                        if spec.star or spec.argFn(context, nil, params) ~= nil then group[index] += 1 end
                    else
                        local value = spec.argFn(context, nil, params)

                        if value ~= nil then
                            if spec.name == 'SUM' then
                                group[index] = (group[index] or 0) + value
                            elseif spec.name == 'AVG' then
                                group[index] += value
                                group.avgCounts[index] += 1
                            elseif spec.name == 'MIN' then
                                if group[index] == nil or value < group[index] then group[index] = value end
                            elseif spec.name == 'MAX' then
                                if group[index] == nil or value > group[index] then group[index] = value end
                            end
                        end
                    end
                end
            end

            if #groupFns == 0 then
                local group = newGroup(nil)
                order[1] = group

                eachContext(function(context)
                    if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then accumulate(group, context) end
                end)
            else
                local root = {}

                eachContext(function(context)
                    if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                        local node = root
                        local group = nil

                        for keyIndex, evaluate in groupFns do
                            local key = evaluate(context, nil, params)
                            if key == nil then key = nilKey end

                            if keyIndex == #groupFns then
                                group = node[key]

                                if group == nil then
                                    group = newGroup(context, if key == nilKey then nil else key)
                                    node[key] = group
                                    order[#order + 1] = group
                                end
                            else
                                local nextNode = node[key]

                                if nextNode == nil then
                                    nextNode = {}
                                    node[key] = nextNode
                                end

                                node = nextNode
                            end
                        end

                        accumulate(group, context)
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
                local context = table.create(#sources)
                context[sourceIndex] = row
                return context
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

            for _, group in order do
                for index, spec in aggregateSpecs do
                    if spec.name == 'AVG' then
                        local count = group.avgCounts[index]
                        group[index] = if count == 0 then nil else group[index] / count
                    end
                end

                local context = groupContext(group)
                if havingFn and not sqlTruthy(havingFn(context, group, params)) then continue end
                local unit = { context = context, group = group }

                if heap ~= nil then
                    decorateOrder(unit)

                    if #heap < keep then
                        heap[#heap + 1] = unit
                        siftUp(#heap)
                    elseif orderBefore(unit, heap[1]) then
                        heap[1] = unit
                        siftDown(1)
                    end
                elseif keep ~= 0 then
                    units[#units + 1] = unit
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
                    eachContext(function(context)
                        if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                            units[#units + 1] = { context = retainContext(context), group = nil }
                            if stopAfter ~= nil and #units >= stopAfter then return false end
                        end
                    end)
                end
            elseif stopAfter ~= nil then
                if stopAfter > 0 then
                    local heap = table.create(stopAfter)

                    if #orderFns == 1 then
                        local order = orderFns[1]

                        local function beforeKey(left, right)
                            if left ~= right then
                                if left == nil then return not order.desc end
                                if right == nil then return order.desc end
                                if order.desc then return left > right else return left < right end
                            end

                            return false
                        end

                        local function worse(left, right) return beforeKey(right.orderKey, left.orderKey) end

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

                        eachContext(function(context)
                            if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                                local key = order.evaluate(context, nil, params)

                                if #heap < stopAfter then
                                    local unit = { context = retainContext(context), group = nil, orderKey = key }
                                    heap[#heap + 1] = unit
                                    siftUp(#heap)
                                elseif beforeKey(key, heap[1].orderKey) then
                                    heap[1] = { context = retainContext(context), group = nil, orderKey = key }
                                    siftDown(1)
                                end
                            end
                        end)

                        units = heap
                        table.sort(units, function(left, right) return beforeKey(left.orderKey, right.orderKey) end)
                    else
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

                        eachContext(function(context)
                            if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                                local unit = { context = retainContext(context), group = nil }
                                decorateOrder(unit)

                                if #heap < stopAfter then
                                    heap[#heap + 1] = unit
                                    siftUp(#heap)
                                elseif orderBefore(unit, heap[1]) then
                                    heap[1] = unit
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
                eachContext(function(context)
                    if not residualWhere or sqlTruthy(residualWhere(context, nil, params)) then
                        units[#units + 1] = { context = retainContext(context), group = nil }
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

                    for _, unit in units do
                        decorateOrder(unit)

                        if #heap < keep then
                            heap[#heap + 1] = unit
                            siftUp(#heap)
                        elseif orderBefore(unit, heap[1]) then
                            heap[1] = unit
                            siftDown(1)
                        end
                    end

                    units = heap
                    table.sort(units, orderBefore)
                end
            else
                for _, unit in units do decorateOrder(unit) end
                table.sort(units, orderBefore)
            end
        end

        local first = ast.offset + 1
        local last = #units
        if ast.limit ~= nil then last = math.min(last, ast.offset + ast.limit) end
        local resultRows = table.create(math.max(0, last - first + 1))

        for unitIndex = first, last do
            local unit = units[unitIndex]
            local row = {}

            for index, selector in selectors do
                local value = selector(unit.context, unit.group, params)
                if value ~= nil then row[resultColumns[index]] = value end
            end

            resultRows[#resultRows + 1] = row
        end

        return { columns = resultColumns, rows = resultRows }
    end

    plan.ast = ast
    plan.columns = resultColumns
    plan.parameterCount = ast.params

    function plan.explain()
        local joins = {}

        for index, join in ast.joins do
            joins[index] = { kind = join.kind, table = join.source.name, alias = join.source.alias, strategy = joinPlans[index].strategy }
        end

        local scans = {}

        for index, source in sources do
            scans[index] = { table = source.name, alias = source.alias, columns = neededColumns[index] }
        end

        return {
            scans = scans,
            joins = joins,
            grouped = aggregate,
            compactGroup = compactGroupColumn ~= nil,
            aggregateCount = #aggregateSpecs,
            providerCount = directProviderCount,
            parameterCount = ast.params,
        }
    end

    return plan
end

function engine.new()
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
        for name, provider in self._tables do out[#out + 1] = { name = name, columns = provider.columns } end
        table.sort(out, function(left, right) return left.name < right.name end)
        return out
    end

    return db
end

engine.prepare = prepare
return engine
