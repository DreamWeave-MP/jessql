--!strict
--!native

local lexer = {}

local function isSpace(byte)
    return byte == 32 or byte == 9 or byte == 10 or byte == 13 or byte == 12
end

local function isDigit(byte)
    return byte >= 48 and byte <= 57
end

local function isIdentStart(byte)
    return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95 or byte == 64
end

local function isIdent(byte)
    return isIdentStart(byte) or isDigit(byte) or byte == 36
end

local function fail(sql, at, message)
    error(string.format('jessql lexer at byte %d: %s near %q', at, message, string.sub(sql, at, math.min(#sql, at + 20))), 0)
end

function lexer.lex(sql)
    local out = table.create(math.max(8, math.floor(#sql / 4)))
    local count = 0
    local position = 1
    local len = #sql

    local function push(kind, text, value, at)
        count += 1
        out[count] = { kind = kind, text = text, value = value, at = at }
    end

    while position <= len do
        local byte = string.byte(sql, position)

        if isSpace(byte) then
            position += 1
        elseif byte == 45 and position < len and string.byte(sql, position + 1) == 45 then
            position += 2
            while position <= len and string.byte(sql, position) ~= 10 do position += 1 end
        elseif byte == 47 and position < len and string.byte(sql, position + 1) == 42 then
            local at = position
            position += 2

            while position + 1 <= len and not (string.byte(sql, position) == 42 and string.byte(sql, position + 1) == 47) do
                position += 1
            end

            if position + 1 > len then fail(sql, at, 'unterminated block comment') end
            position += 2
        elseif byte == 39 then
            local at = position
            position += 1
            local parts = {}
            local partCount = 0
            local start = position

            while position <= len do
                if string.byte(sql, position) == 39 then
                    if position < len and string.byte(sql, position + 1) == 39 then
                        partCount += 1
                        parts[partCount] = string.sub(sql, start, position - 1)
                        partCount += 1
                        parts[partCount] = "'"
                        position += 2
                        start = position
                    else
                        partCount += 1
                        parts[partCount] = string.sub(sql, start, position - 1)
                        position += 1
                        local value = table.concat(parts)
                        push('string', value, value, at)
                        break
                    end
                else
                    position += 1
                end
            end

            if out[count] == nil or out[count].at ~= at then fail(sql, at, 'unterminated string') end
        elseif byte == 34 then
            local at = position
            position += 1
            local parts = {}
            local partCount = 0
            local start = position

            while position <= len do
                if string.byte(sql, position) == 34 then
                    if position < len and string.byte(sql, position + 1) == 34 then
                        partCount += 1
                        parts[partCount] = string.sub(sql, start, position - 1)
                        partCount += 1
                        parts[partCount] = '"'
                        position += 2
                        start = position
                    else
                        partCount += 1
                        parts[partCount] = string.sub(sql, start, position - 1)
                        position += 1
                        local value = table.concat(parts)
                        push('ident', value, value, at)
                        break
                    end
                else
                    position += 1
                end
            end

            if out[count] == nil or out[count].at ~= at then fail(sql, at, 'unterminated quoted identifier') end
        elseif isDigit(byte) or (byte == 46 and position < len and isDigit(string.byte(sql, position + 1))) then
            local at = position

            if byte == 46 then
                position += 1
                while position <= len and isDigit(string.byte(sql, position)) do position += 1 end
            else
                while position <= len and isDigit(string.byte(sql, position)) do position += 1 end

                if position <= len and string.byte(sql, position) == 46 then
                    position += 1
                    while position <= len and isDigit(string.byte(sql, position)) do position += 1 end
                end
            end

            if position <= len then
                local exponentByte = string.byte(sql, position)

                if exponentByte == 69 or exponentByte == 101 then
                    local exponentAt = position
                    position += 1

                    if position <= len then
                        local signByte = string.byte(sql, position)
                        if signByte == 43 or signByte == 45 then position += 1 end
                    end

                    local digits = position
                    while position <= len and isDigit(string.byte(sql, position)) do position += 1 end
                    if digits == position then fail(sql, exponentAt, 'malformed exponent') end
                end
            end

            local text = string.sub(sql, at, position - 1)
            push('number', text, tonumber(text), at)
        elseif isIdentStart(byte) then
            local at = position
            position += 1
            while position <= len and isIdent(string.byte(sql, position)) do position += 1 end
            local text = string.sub(sql, at, position - 1)
            push('word', text, string.upper(text), at)
        else
            local at = position
            local character = string.sub(sql, position, position)
            local two = if position < len then string.sub(sql, position, position + 1) else ''

            if two == '<=' or two == '>=' or two == '<>' or two == '!=' or two == '||' then
                push('symbol', two, two, at)
                position += 2
            elseif
                character == '('
                or character == ')'
                or character == ','
                or character == '.'
                or character == '*'
                or character == '+'
                or character == '-'
                or character == '/'
                or character == '%'
                or character == '='
                or character == '<'
                or character == '>'
                or character == ';'
                or character == '?'
            then
                push('symbol', character, character, at)
                position += 1
            else
                fail(sql, position, 'unexpected character')
            end
        end
    end

    push('eof', '<eof>', nil, len + 1)
    return out
end

return lexer
