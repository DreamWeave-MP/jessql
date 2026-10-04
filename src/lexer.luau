--!native

local M = {}

local function isSpace(b)
    return b == 32 or b == 9 or b == 10 or b == 13 or b == 12
end

local function isDigit(b)
    return b >= 48 and b <= 57
end

local function isIdentStart(b)
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 64
end

local function isIdent(b)
    return isIdentStart(b) or isDigit(b) or b == 36
end

local function fail(sql, at, message)
    error(string.format("jessql lexer at byte %d: %s near %q", at, message, string.sub(sql, at, math.min(#sql, at + 20))), 0)
end

function M.lex(sql)
    local out = table.create(math.max(8, math.floor(#sql / 4)))
    local n = 0
    local i = 1
    local len = #sql

    local function push(kind, text, value, at)
        n += 1
        out[n] = { kind = kind, text = text, value = value, at = at }
    end

    while i <= len do
        local b = string.byte(sql, i)
        if isSpace(b) then
            i += 1
        elseif b == 45 and i < len and string.byte(sql, i + 1) == 45 then
            i += 2
            while i <= len and string.byte(sql, i) ~= 10 do i += 1 end
        elseif b == 47 and i < len and string.byte(sql, i + 1) == 42 then
            local at = i
            i += 2
            while i + 1 <= len and not (string.byte(sql, i) == 42 and string.byte(sql, i + 1) == 47) do
                i += 1
            end
            if i + 1 > len then fail(sql, at, "unterminated block comment") end
            i += 2
        elseif b == 39 then
            local at = i
            i += 1
            local parts = {}
            local pn = 0
            local start = i
            while i <= len do
                if string.byte(sql, i) == 39 then
                    if i < len and string.byte(sql, i + 1) == 39 then
                        pn += 1; parts[pn] = string.sub(sql, start, i - 1)
                        pn += 1; parts[pn] = "'"
                        i += 2
                        start = i
                    else
                        pn += 1; parts[pn] = string.sub(sql, start, i - 1)
                        i += 1
                        local value = table.concat(parts)
                        push("string", value, value, at)
                        break
                    end
                else
                    i += 1
                end
            end
            if out[n] == nil or out[n].at ~= at then fail(sql, at, "unterminated string") end
        elseif b == 34 then
            local at = i
            i += 1
            local parts = {}
            local pn = 0
            local start = i
            while i <= len do
                if string.byte(sql, i) == 34 then
                    if i < len and string.byte(sql, i + 1) == 34 then
                        pn += 1; parts[pn] = string.sub(sql, start, i - 1)
                        pn += 1; parts[pn] = '"'
                        i += 2
                        start = i
                    else
                        pn += 1; parts[pn] = string.sub(sql, start, i - 1)
                        i += 1
                        local value = table.concat(parts)
                        push("ident", value, value, at)
                        break
                    end
                else
                    i += 1
                end
            end
            if out[n] == nil or out[n].at ~= at then fail(sql, at, "unterminated quoted identifier") end
        elseif isDigit(b) or (b == 46 and i < len and isDigit(string.byte(sql, i + 1))) then
            local at = i
            if b == 46 then
                i += 1
                while i <= len and isDigit(string.byte(sql, i)) do i += 1 end
            else
                while i <= len and isDigit(string.byte(sql, i)) do i += 1 end
                if i <= len and string.byte(sql, i) == 46 then
                    i += 1
                    while i <= len and isDigit(string.byte(sql, i)) do i += 1 end
                end
            end
            if i <= len then
                local eb = string.byte(sql, i)
                if eb == 69 or eb == 101 then
                    local e = i
                    i += 1
                    if i <= len then
                        local sb = string.byte(sql, i)
                        if sb == 43 or sb == 45 then i += 1 end
                    end
                    local digits = i
                    while i <= len and isDigit(string.byte(sql, i)) do i += 1 end
                    if digits == i then fail(sql, e, "malformed exponent") end
                end
            end
            local text = string.sub(sql, at, i - 1)
            push("number", text, tonumber(text), at)
        elseif isIdentStart(b) then
            local at = i
            i += 1
            while i <= len and isIdent(string.byte(sql, i)) do i += 1 end
            local text = string.sub(sql, at, i - 1)
            push("word", text, string.upper(text), at)
        else
            local at = i
            local c = string.sub(sql, i, i)
            local two = if i < len then string.sub(sql, i, i + 1) else ""
            if two == "<=" or two == ">=" or two == "<>" or two == "!=" or two == "||" then
                push("symbol", two, two, at)
                i += 2
            elseif c == "(" or c == ")" or c == "," or c == "." or c == "*" or c == "+" or c == "-" or c == "/" or c == "%" or c == "=" or c == "<" or c == ">" or c == ";" or c == "?" then
                push("symbol", c, c, at)
                i += 1
            else
                fail(sql, i, "unexpected character")
            end
        end
    end

    push("eof", "<eof>", nil, len + 1)
    return out
end

return M
