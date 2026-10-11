--!strict
--!native

local lexer = require('@jessql/lexer')

local parser = {}

local ClauseKeywords = {
    FROM = true, WHERE = true, GROUP = true, HAVING = true, ORDER = true, LIMIT = true, OFFSET = true,
    JOIN = true, INNER = true, LEFT = true, RIGHT = true, FULL = true, ON = true,
}

local function parse(sql)
    local tokens = lexer.lex(sql)
    local position = 1
    local paramCount = 0

    local function tok() return tokens[position] end

    local function advance()
        local token = tokens[position]
        position += 1
        return token
    end

    local function isWord(name)
        local token = tok()
        return token.kind == 'word' and token.value == name
    end

    local function isSym(name)
        local token = tok()
        return token.kind == 'symbol' and token.text == name
    end

    local function acceptWord(name)
        if isWord(name) then
            position += 1
            return true
        end

        return false
    end

    local function acceptSym(name)
        if isSym(name) then
            position += 1
            return true
        end

        return false
    end

    local function fail(message)
        local token = tok()
        error(string.format('jessql parser at byte %d: %s; got %s', token.at, message, token.text), 0)
    end

    local function expectWord(name)
        if not acceptWord(name) then fail('expected ' .. name) end
    end

    local function expectSym(name)
        if not acceptSym(name) then fail('expected ' .. name) end
    end

    local function ident()
        local token = tok()

        if token.kind == 'ident' then
            position += 1
            return token.value
        end

        if token.kind == 'word' then
            position += 1
            return token.text
        end

        fail('expected identifier')
    end

    local parseExpr

    local function primary()
        local token = tok()

        if acceptSym('(') then
            local node = parseExpr(0)
            expectSym(')')
            return node
        elseif acceptSym('?') then
            paramCount += 1
            return { tag = 'param', index = paramCount }
        elseif token.kind == 'number' then
            position += 1
            return { tag = 'literal', value = token.value }
        elseif token.kind == 'string' then
            position += 1
            return { tag = 'literal', value = token.value }
        elseif isWord('NULL') then
            position += 1
            return { tag = 'literal', value = nil, isNull = true }
        elseif isWord('TRUE') or isWord('FALSE') then
            local value = isWord('TRUE')
            position += 1
            return { tag = 'literal', value = value }
        elseif isWord('NOT') then
            position += 1
            return { tag = 'unary', op = 'NOT', expr = parseExpr(70) }
        elseif acceptSym('-') then
            return { tag = 'unary', op = '-', expr = parseExpr(70) }
        elseif acceptSym('+') then
            return { tag = 'unary', op = '+', expr = parseExpr(70) }
        elseif token.kind == 'word' or token.kind == 'ident' then
            local first = ident()

            if acceptSym('(') then
                local args = {}
                local star = false

                if acceptSym('*') then
                    star = true
                elseif not isSym(')') then
                    repeat
                        args[#args + 1] = parseExpr(0)
                    until not acceptSym(',')
                end

                expectSym(')')
                return { tag = 'call', name = string.upper(first), args = args, star = star }
            end

            if acceptSym('.') then
                if acceptSym('*') then
                    return { tag = 'star', qualifier = first }
                end

                return { tag = 'column', qualifier = first, name = ident() }
            end

            return { tag = 'column', name = first }
        elseif acceptSym('*') then
            return { tag = 'star' }
        end

        fail('expected expression')
    end

    local precedence = {
        OR = 10, AND = 20,
        ['='] = 30, ['!='] = 30, ['<>'] = 30, ['<'] = 30, ['<='] = 30, ['>'] = 30, ['>='] = 30, LIKE = 30,
        ['||'] = 40,
        ['+'] = 50, ['-'] = 50,
        ['*'] = 60, ['/'] = 60, ['%'] = 60,
    }

    parseExpr = function(minPrec)
        local left = primary()

        while true do
            local token = tok()
            local op = nil
            if token.kind == 'word' and precedence[token.value] then op = token.value end
            if token.kind == 'symbol' and precedence[token.text] then op = token.text end
            if op == nil then break end
            local prec = precedence[op]
            if prec < minPrec then break end
            position += 1
            local right = parseExpr(prec + 1)
            left = { tag = 'binary', op = op, left = left, right = right }
        end

        if minPrec <= 30 and acceptWord('IS') then
            local negated = acceptWord('NOT')
            expectWord('NULL')
            left = { tag = 'isnull', expr = left, negated = negated }
        end

        return left
    end

    local function source()
        local parts = { ident() }
        while acceptSym('.') do parts[#parts + 1] = ident() end
        local name = table.concat(parts, '.')
        local alias = nil

        if acceptWord('AS') then
            alias = ident()
        else
            local token = tok()

            if (token.kind == 'word' or token.kind == 'ident') and not ClauseKeywords[token.value] then
                alias = ident()
            end
        end

        return { name = name, alias = alias or parts[#parts] }
    end

    expectWord('SELECT')
    local selectList = {}

    repeat
        local expr = parseExpr(0)
        local alias = nil

        if acceptWord('AS') then
            alias = ident()
        else
            local token = tok()

            if (token.kind == 'word' or token.kind == 'ident') and not ClauseKeywords[token.value] then
                alias = ident()
            end
        end

        selectList[#selectList + 1] = { expr = expr, alias = alias }
    until not acceptSym(',')

    expectWord('FROM')
    local from = source()
    local joins = {}

    while isWord('JOIN') or isWord('INNER') or isWord('LEFT') do
        local kind = 'inner'

        if acceptWord('LEFT') then
            kind = 'left'
            acceptWord('OUTER')
        elseif acceptWord('INNER') then
            kind = 'inner'
        end

        expectWord('JOIN')
        local joined = source()
        expectWord('ON')
        joins[#joins + 1] = { kind = kind, source = joined, on = parseExpr(0) }
    end

    local where = nil
    if acceptWord('WHERE') then where = parseExpr(0) end

    local groupBy = {}

    if acceptWord('GROUP') then
        expectWord('BY')
        repeat groupBy[#groupBy + 1] = parseExpr(0) until not acceptSym(',')
    end

    local having = nil
    if acceptWord('HAVING') then having = parseExpr(0) end

    local orderBy = {}

    if acceptWord('ORDER') then
        expectWord('BY')

        repeat
            local node = parseExpr(0)
            local desc = false
            if acceptWord('DESC') then desc = true else acceptWord('ASC') end
            orderBy[#orderBy + 1] = { expr = node, desc = desc }
        until not acceptSym(',')
    end

    local limit = nil
    local offset = nil

    if acceptWord('LIMIT') then
        local token = advance()
        if token.kind ~= 'number' or token.value < 0 or token.value % 1 ~= 0 then fail('LIMIT needs a nonnegative integer') end
        limit = token.value

        if acceptWord('OFFSET') then
            local offsetToken = advance()
            if offsetToken.kind ~= 'number' or offsetToken.value < 0 or offsetToken.value % 1 ~= 0 then fail('OFFSET needs a nonnegative integer') end
            offset = offsetToken.value
        end
    end

    if offset == nil and acceptWord('OFFSET') then
        local offsetToken = advance()
        if offsetToken.kind ~= 'number' or offsetToken.value < 0 or offsetToken.value % 1 ~= 0 then fail('OFFSET needs a nonnegative integer') end
        offset = offsetToken.value
    end

    acceptSym(';')
    if tok().kind ~= 'eof' then fail('unexpected trailing input') end

    return {
        tag = 'select', select = selectList, from = from, joins = joins, where = where,
        groupBy = groupBy, having = having, orderBy = orderBy, limit = limit, offset = offset or 0,
        params = paramCount,
    }
end

parser.parse = parse
return parser
