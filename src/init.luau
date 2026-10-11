--!strict
--!native

local engine = require('@jessql/engine')
local parser = require('@jessql/parser')
local lexer = require('@jessql/lexer')

export type Database = engine.Database
export type Plan = engine.Plan
export type Result = engine.Result
export type Row = engine.Row
export type Explanation = engine.Explanation
export type ExplainedScan = engine.ExplainedScan
export type ExplainedJoin = engine.ExplainedJoin
export type TableInfo = engine.TableInfo

export type Provider = engine.Provider
export type Request = engine.Request
export type Constraint = engine.Constraint
export type Order = engine.Order
export type ScanResult = engine.ScanResult
export type Iterator = engine.Iterator
export type SourceRow = engine.SourceRow
export type SourceRows = engine.SourceRows

export type Select = parser.Select
export type Expr = parser.Expr
export type Token = lexer.Token

return {
  new = engine.new,
  parse = parser.parse,
  lex = lexer.lex,
}
