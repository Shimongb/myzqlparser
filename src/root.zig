/// Public library API for myzqlparser.
///
/// Re-exports all core types from the tokenizer, AST, and operator modules.
const std = @import("std");

// Phase 1: foundation modules
pub const span_mod = @import("span.zig");
pub const errors_mod = @import("errors.zig");
pub const keywords_mod = @import("keywords.zig");
pub const tokenizer_mod = @import("tokenizer.zig");

// Phase 1 re-exports
pub const Location = span_mod.Location;
pub const Span = span_mod.Span;
pub const TokenizerError = errors_mod.TokenizerError;
pub const ParserError = errors_mod.ParserError;
pub const Keyword = keywords_mod.Keyword;
pub const lookupKeyword = keywords_mod.lookupKeyword;
pub const lookupKeywordCaseInsensitive = keywords_mod.lookupKeywordCaseInsensitive;
pub const Token = tokenizer_mod.Token;
pub const TokenWithSpan = tokenizer_mod.TokenWithSpan;
pub const Tokenizer = tokenizer_mod.Tokenizer;
pub const Dialect = tokenizer_mod.Dialect;
pub const Word = tokenizer_mod.Word;
pub const Whitespace = tokenizer_mod.Whitespace;

// Phase 3: dialect and parser
pub const dialect_mod = @import("dialect.zig");
pub const parser_mod = @import("parser.zig");
pub const parser_dml_ddl_mod = @import("parser_dml_ddl.zig");
pub const Parser = parser_mod.Parser;

// Phase 4: display and JSON serialization
pub const ast_display = @import("ast_display.zig");
pub const ast_json = @import("ast_json.zig");

pub const ast_operator = @import("ast_operator.zig");
pub const ast_types = @import("ast_types.zig");
pub const ast = @import("ast.zig");
pub const ast_query = @import("ast_query.zig");
pub const ast_ddl = @import("ast_ddl.zig");
pub const ast_dml = @import("ast_dml.zig");

// Core types re-exported at the top level.
pub const BinaryOp = ast_operator.BinaryOp;
pub const UnaryOp = ast_operator.UnaryOp;
pub const DataType = ast_types.DataType;
pub const Ident = ast.Ident;
pub const ObjectName = ast.ObjectName;
pub const Value = ast.Value;
pub const Expr = ast.Expr;
pub const Statement = ast.Statement;
pub const Assignment = ast.Assignment;
pub const OrderByExpr = ast.OrderByExpr;

// Query types
pub const Query = ast_query.Query;
pub const Select = ast_query.Select;
pub const SelectItem = ast_query.SelectItem;
pub const SetExpr = ast_query.SetExpr;
pub const SetOperator = ast_query.SetOperator;
pub const TableWithJoins = ast_query.TableWithJoins;
pub const TableFactor = ast_query.TableFactor;
pub const Join = ast_query.Join;
pub const JoinOperator = ast_query.JoinOperator;
pub const JoinConstraint = ast_query.JoinConstraint;
pub const With = ast_query.With;
pub const Cte = ast_query.Cte;
pub const Values = ast_query.Values;
pub const GroupByExpr = ast_query.GroupByExpr;
pub const OrderBy = ast_query.OrderBy;

// Dialect (parser)
pub const ParserDialect = dialect_mod.Dialect;
pub const DialectKind = dialect_mod.DialectKind;

// DDL types
pub const CreateTable = ast_ddl.CreateTable;
pub const AlterTable = ast_ddl.AlterTable;
pub const AlterTableOperation = ast_ddl.AlterTableOperation;
pub const ColumnDef = ast_ddl.ColumnDef;
pub const ColumnOption = ast_ddl.ColumnOption;
pub const ColumnOptionDef = ast_ddl.ColumnOptionDef;
pub const TableConstraint = ast_ddl.TableConstraint;
pub const ReferentialAction = ast_ddl.ReferentialAction;
pub const CreateIndex = ast_ddl.CreateIndex;
pub const CreateView = ast_ddl.CreateView;
pub const Drop = ast_ddl.Drop;

// DML types
pub const Insert = ast_dml.Insert;
pub const Update = ast_dml.Update;
pub const Delete = ast_dml.Delete;
pub const InsertSource = ast_dml.InsertSource;

/// Options for controlling parser behavior.
pub const ParseOptions = struct {
    /// Maximum recursion depth for nested expressions.
    max_recursion_depth: u32 = 50,
};

/// Diagnostic info populated on parse failure.
pub const ParseDiagnostics = struct {
    /// Human-readable error message, e.g. "Expected: identifier, found: ;".
    error_message: []const u8 = "",
    /// Source location where the error occurred.
    error_location: Location = Location.empty,
};

/// Parse all SQL statements in `sql` using the given tokenizer dialect and
/// parser dialect.  Returns a slice of `Statement` values allocated from
/// `allocator`.  The caller owns the returned slice and all AST nodes.
///
/// Statements may be separated by semicolons.  Empty input returns an empty
/// slice.  On error, returns `error.ParseFailed`, `error.OutOfMemory`, or a
/// tokenizer error.
///
/// Performance note: for best throughput, pass an arena allocator pre-sized
/// to approximately 4x the byte length of `sql`.  This amortises the many
/// small allocations made while building AST nodes and avoids repeated OS
/// memory requests during a parse.
pub fn parse(
    allocator: std.mem.Allocator,
    sql: []const u8,
    tok_dialect: Dialect,
    parser_dialect: ParserDialect,
) ![]Statement {
    return parseDiag(allocator, sql, tok_dialect, parser_dialect, null);
}

/// Like `parse`, but populates `diagnostics` with error detail on failure.
/// The `diagnostics.error_message` slice is allocated from `allocator` and
/// remains valid as long as the allocator's memory is live. When using an
/// arena allocator (recommended), it is freed with the arena.
pub fn parseDiag(
    allocator: std.mem.Allocator,
    sql: []const u8,
    tok_dialect: Dialect,
    parser_dialect: ParserDialect,
    diagnostics: ?*ParseDiagnostics,
) ![]Statement {
    var tokenizer = Tokenizer.init(tok_dialect, sql);
    const raw_tokens = try tokenizer.tokenizeWithLocation(allocator);
    defer allocator.free(raw_tokens);

    const tokens = try parser_mod.stripWhitespace(allocator, raw_tokens);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, parser_dialect, tokens);
    return parser.parseStatements() catch |err| {
        if (diagnostics) |diag| {
            diag.error_message = parser.error_message;
            diag.error_location = parser.error_location;
        }
        return err;
    };
}

/// Parse all SQL statements with default options. Convenience wrapper around `parse`.
pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    sql: []const u8,
    tok_dialect: Dialect,
    parser_dialect: ParserDialect,
    _: ParseOptions,
) ![]Statement {
    return parse(allocator, sql, tok_dialect, parser_dialect);
}

test {
    // Pull in all tests from submodules.
    std.testing.refAllDecls(@This());
}
