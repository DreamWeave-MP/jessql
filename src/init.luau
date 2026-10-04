--!native

local engine = require("@jessql/engine")
local parser = require("@jessql/parser")
local lexer = require("@jessql/lexer")

return {
    new = engine.new,
    parse = parser.parse,
    lex = lexer.lex,
}
