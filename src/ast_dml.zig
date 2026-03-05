const std = @import("std");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

pub const Ident = ast.Ident;
pub const ObjectName = ast.ObjectName;
pub const Expr = ast.Expr;
pub const Assignment = ast.Assignment;
pub const Query = ast_query.Query;
pub const With = ast_query.With;
pub const SelectItem = ast_query.SelectItem;
pub const TableWithJoins = ast_query.TableWithJoins;
pub const TableFactor = ast_query.TableFactor;
pub const Values = ast_query.Values;

// ---------------------------------------------------------------------------
// ON DUPLICATE KEY UPDATE / ON CONFLICT (MySQL)
// ---------------------------------------------------------------------------

/// The MySQL ON DUPLICATE KEY UPDATE clause.
pub const OnDuplicateKeyUpdate = []const Assignment;

// ---------------------------------------------------------------------------
// INSERT priority (MySQL)
// ---------------------------------------------------------------------------

/// MySQL INSERT priority modifier.
pub const MysqlInsertPriority = enum {
    low_priority,
    delayed,
    high_priority,
};

// ---------------------------------------------------------------------------
// INSERT statement
// ---------------------------------------------------------------------------

/// An INSERT, REPLACE, or INSERT IGNORE statement.
pub const Insert = struct {
    /// The INSERT/REPLACE keyword token with source span.
    token: @import("tokenizer.zig").TokenWithSpan = .{ .token = .{ .EOF = {} }, .span = .empty },
    /// `REPLACE INTO` (MySQL) instead of `INSERT INTO`.
    replace_into: bool,
    /// `INSERT IGNORE` (MySQL): ignore duplicate key errors.
    ignore: bool,
    /// `INTO` keyword was present.
    into: bool,
    /// Target table name.
    table: ObjectName,
    /// Optional table alias (PostgreSQL).
    table_alias: ?Ident,
    /// Target column list (if specified).
    columns: []const Ident,
    /// Source: either a VALUES clause or a SELECT query.
    source: InsertSource,
    /// MySQL ON DUPLICATE KEY UPDATE.
    on_duplicate_key_update: ?OnDuplicateKeyUpdate,
    /// Optional priority modifier (MySQL).
    priority: ?MysqlInsertPriority,
};

/// The source data for an INSERT statement.
pub const InsertSource = union(enum) {
    /// `VALUES (row1), (row2), ...`
    values: Values,
    /// `SELECT ...`
    select: *const Query,
    /// `SET col = val, ...` (MySQL SET form of INSERT)
    assignments: []const Assignment,
    /// DEFAULT VALUES
    default_values,
};

// ---------------------------------------------------------------------------
// UPDATE statement
// ---------------------------------------------------------------------------

/// An UPDATE statement.
pub const Update = struct {
    /// The UPDATE keyword token with source span.
    token: @import("tokenizer.zig").TokenWithSpan = .{ .token = .{ .EOF = {} }, .span = .empty },
    /// Optional WITH clause (CTEs).
    with: ?With = null,
    /// Table(s) to update.
    table: []const TableWithJoins,
    /// SET col = expr, ... assignments.
    assignments: []const Assignment,
    /// Optional FROM clause (some dialects).
    from: ?[]const TableWithJoins,
    /// WHERE clause.
    selection: ?Expr,
    /// ORDER BY (MySQL).
    order_by: []const ast.OrderByExpr,
    /// LIMIT (MySQL).
    limit: ?Expr,
};

// ---------------------------------------------------------------------------
// DELETE statement
// ---------------------------------------------------------------------------

/// A DELETE statement.
pub const Delete = struct {
    /// The DELETE keyword token with source span.
    token: @import("tokenizer.zig").TokenWithSpan = .{ .token = .{ .EOF = {} }, .span = .empty },
    /// Optional WITH clause (CTEs).
    with: ?With = null,
    /// Target table(s) to delete from.
    ///
    /// MySQL allows multi-table DELETE: `DELETE t1, t2 FROM t1 JOIN t2 ...`
    /// In the single-table case, this is the FROM table.
    tables: []const ObjectName,
    /// The FROM clause (contains the actual table or join).
    from: []const TableWithJoins,
    /// USING clause (PostgreSQL).
    using: ?[]const TableWithJoins,
    /// WHERE clause.
    selection: ?Expr,
    /// ORDER BY (MySQL).
    order_by: []const ast.OrderByExpr,
    /// LIMIT (MySQL).
    limit: ?Expr,
};

test "Insert compiles" {
    const ins: Insert = .{
        .replace_into = false,
        .ignore = false,
        .into = true,
        .table = .{ .parts = &.{} },
        .table_alias = null,
        .columns = &.{},
        .source = .{ .default_values = {} },
        .on_duplicate_key_update = null,
        .priority = null,
    };
    try std.testing.expect(!ins.ignore);
}

test "Delete compiles" {
    const del: Delete = .{
        .tables = &.{},
        .from = &.{},
        .using = null,
        .selection = null,
        .order_by = &.{},
        .limit = null,
    };
    try std.testing.expectEqual(@as(usize, 0), del.tables.len);
}

test "Update compiles" {
    const upd: Update = .{
        .table = &.{},
        .assignments = &.{},
        .from = null,
        .selection = null,
        .order_by = &.{},
        .limit = null,
    };
    try std.testing.expectEqual(@as(usize, 0), upd.assignments.len);
}
