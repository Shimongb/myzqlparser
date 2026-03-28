/// SQL analysis utilities built on the AST visitor infrastructure.
///
/// Provides three main functions:
/// - classifyStatement: determine query type (DDL/DML) and subtype
/// - extractTables: collect all table references with schema/alias info
/// - extractColumns: collect all column dependencies with usage context
const std = @import("std");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const ast_dml = @import("ast_dml.zig");
const ast_ddl = @import("ast_ddl.zig");
const visitor = @import("visitor.zig");

const Statement = ast.Statement;
const Expr = ast.Expr;
const Ident = ast.Ident;
const ObjectName = ast.ObjectName;
const Query = ast_query.Query;
const Select = ast_query.Select;
const SetExpr = ast_query.SetExpr;
const SelectItem = ast_query.SelectItem;
const TableFactor = ast_query.TableFactor;
const TableWithJoins = ast_query.TableWithJoins;
const Join = ast_query.Join;
const JoinOperator = ast_query.JoinOperator;
const JoinConstraint = ast_query.JoinConstraint;
const GroupByExpr = ast_query.GroupByExpr;

// =========================================================================
// Query Classification
// =========================================================================

/// Top-level query category.
pub const QueryCategory = enum {
    ddl,
    dml,
    tcl,
    show,
    other,
};

/// Specific query type/subtype.
pub const QueryType = enum {
    // DML
    select,
    insert,
    replace,
    update,
    delete,
    // DDL
    create,
    alter,
    drop,
    truncate,
    // TCL
    begin,
    commit,
    rollback,
    // MySQL
    show,
    lock,
    unlock,
    set,
    use,
};

/// Full classification of a SQL statement.
pub const QueryClassification = struct {
    category: QueryCategory,
    query_type: QueryType,
};

/// Classify a statement by its type. For CTE-wrapped statements, the
/// classification is based on the outermost statement type, not the CTE body.
/// For CREATE TABLE ... AS SELECT, classification is .create (DDL), not .select.
pub fn classifyStatement(stmt: Statement) QueryClassification {
    return switch (stmt) {
        .select => |q| classifyQuery(q),
        .insert => |ins| .{
            .category = .dml,
            .query_type = if (ins.replace_into) .replace else .insert,
        },
        .update => .{ .category = .dml, .query_type = .update },
        .delete => .{ .category = .dml, .query_type = .delete },
        .create_table => .{ .category = .ddl, .query_type = .create },
        .alter_table => .{ .category = .ddl, .query_type = .alter },
        .drop => .{ .category = .ddl, .query_type = .drop },
        .create_index => .{ .category = .ddl, .query_type = .create },
        .create_view => .{ .category = .ddl, .query_type = .create },
        .drop_view => .{ .category = .ddl, .query_type = .drop },
        .show_tables, .show_columns, .show_create_table, .show_databases, .show_create_view => .{ .category = .show, .query_type = .show },
        .lock_tables => .{ .category = .other, .query_type = .lock },
        .unlock_tables => .{ .category = .other, .query_type = .unlock },
        .start_transaction => .{ .category = .tcl, .query_type = .begin },
        .commit => .{ .category = .tcl, .query_type = .commit },
        .rollback => .{ .category = .tcl, .query_type = .rollback },
        .set => .{ .category = .other, .query_type = .set },
        .use_db => .{ .category = .other, .query_type = .use },
    };
}

/// Classify a Query node. A CTE-wrapped query is classified by the body
/// of the outermost SELECT (the part after WITH ... AS (...)).
fn classifyQuery(query: *const Query) QueryClassification {
    return classifySetExpr(query.body);
}

fn classifySetExpr(set_expr: *const SetExpr) QueryClassification {
    return switch (set_expr.*) {
        .select => .{ .category = .dml, .query_type = .select },
        .query => |q| classifyQuery(q),
        .set_operation => .{ .category = .dml, .query_type = .select },
        .values => .{ .category = .dml, .query_type = .select },
    };
}

/// Classify multiple statements. Returns a slice of classifications.
pub fn classifyStatements(allocator: std.mem.Allocator, stmts: []const Statement) ![]QueryClassification {
    const result = try allocator.alloc(QueryClassification, stmts.len);
    for (stmts, 0..) |stmt, i| {
        result[i] = classifyStatement(stmt);
    }
    return result;
}

// =========================================================================
// Table Extraction
// =========================================================================

/// A table reference found in the query.
pub const TableRef = struct {
    /// Schema name, or null if not specified.
    schema_name: ?[]const u8,
    /// Table name.
    table_name: []const u8,
    /// Alias, or null if not aliased.
    alias: ?[]const u8,
};

/// Extract all table references from a slice of statements.
pub fn extractTables(allocator: std.mem.Allocator, stmts: []const Statement) ![]TableRef {
    var results: std.ArrayListUnmanaged(TableRef) = .empty;
    for (stmts) |stmt| {
        try extractTablesFromStatement(allocator, stmt, &results);
    }
    return results.toOwnedSlice(allocator);
}

fn extractTablesFromStatement(alloc: std.mem.Allocator, stmt: Statement, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    switch (stmt) {
        .select => |q| try extractTablesFromQuery(alloc, q, out),
        .insert => |ins| {
            try addTableRef(alloc, out, ins.table, if (ins.table_alias) |a| a.value else null);
            switch (ins.source) {
                .select => |q| try extractTablesFromQuery(alloc, q, out),
                .values => |vals| {
                    for (vals.rows) |row| {
                        for (row) |*e| try extractTablesFromExpr(alloc, e, out);
                    }
                },
                .assignments => |assigns| {
                    for (assigns) |a| try extractTablesFromExpr(alloc, &a.value, out);
                },
                .default_values => {},
            }
            if (ins.on_duplicate_key_update) |odku| {
                for (odku) |a| try extractTablesFromExpr(alloc, &a.value, out);
            }
        },
        .update => |upd| {
            if (upd.with) |with| try extractTablesFromWith(alloc, with, out);
            for (upd.table) |twj| try extractTablesFromTWJ(alloc, twj, out);
            if (upd.from) |from| {
                for (from) |twj| try extractTablesFromTWJ(alloc, twj, out);
            }
        },
        .delete => |del| {
            if (del.with) |with| try extractTablesFromWith(alloc, with, out);
            for (del.from) |twj| try extractTablesFromTWJ(alloc, twj, out);
            if (del.using) |using| {
                for (using) |twj| try extractTablesFromTWJ(alloc, twj, out);
            }
        },
        .create_table => |ct| {
            try addTableRef(alloc, out, ct.name, null);
            if (ct.as_select) |q| try extractTablesFromQuery(alloc, q, out);
        },
        .alter_table => |at| try addTableRef(alloc, out, at.name, null),
        .drop => |d| {
            for (d.names) |name| try addTableRef(alloc, out, name, null);
        },
        .create_index => |ci| try addTableRef(alloc, out, ci.table_name, null),
        .create_view => |cv| {
            try addTableRef(alloc, out, cv.name, null);
            try extractTablesFromQuery(alloc, cv.query, out);
        },
        .drop_view => |dv| try addTableRef(alloc, out, dv.name, null),
        else => {},
    }
    // Also extract tables from subqueries in expressions
    try extractTablesFromExprInStatement(alloc, stmt, out);
}

fn extractTablesFromExprInStatement(alloc: std.mem.Allocator, stmt: Statement, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    switch (stmt) {
        .update => |upd| {
            if (upd.selection) |sel| try extractTablesFromExpr(alloc, &sel, out);
        },
        .delete => |del| {
            if (del.selection) |sel| try extractTablesFromExpr(alloc, &sel, out);
        },
        else => {},
    }
}

fn extractTablesFromQuery(alloc: std.mem.Allocator, query: *const Query, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    if (query.with) |with| try extractTablesFromWith(alloc, with, out);
    try extractTablesFromSetExpr(alloc, query.body, out);
    // ORDER BY, LIMIT may contain subqueries
    if (query.order_by) |ob| {
        for (ob.exprs) |obe| try extractTablesFromExpr(alloc, &obe.expr, out);
    }
}

fn extractTablesFromWith(alloc: std.mem.Allocator, with: ast_query.With, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    for (with.cte_tables) |cte| {
        try extractTablesFromQuery(alloc, cte.query, out);
    }
}

fn extractTablesFromSetExpr(alloc: std.mem.Allocator, se: *const SetExpr, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    switch (se.*) {
        .select => |sel| try extractTablesFromSelect(alloc, sel, out),
        .query => |q| try extractTablesFromQuery(alloc, q, out),
        .set_operation => |sop| {
            try extractTablesFromSetExpr(alloc, sop.left, out);
            try extractTablesFromSetExpr(alloc, sop.right, out);
        },
        .values => {},
    }
}

fn extractTablesFromSelect(alloc: std.mem.Allocator, sel: *const Select, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    for (sel.from) |twj| try extractTablesFromTWJ(alloc, twj, out);
    // Walk expressions for subqueries
    for (sel.projection) |item| {
        switch (item) {
            .unnamed_expr => |*e| try extractTablesFromExpr(alloc, e, out),
            .expr_with_alias => |*ewa| try extractTablesFromExpr(alloc, &ewa.expr, out),
            .qualified_wildcard, .wildcard => {},
        }
    }
    if (sel.selection) |*e| try extractTablesFromExpr(alloc, e, out);
    switch (sel.group_by) {
        .expressions => |exprs| {
            for (exprs) |*e| try extractTablesFromExpr(alloc, e, out);
        },
        .all => {},
    }
    if (sel.having) |*e| try extractTablesFromExpr(alloc, e, out);
}

fn extractTablesFromTWJ(alloc: std.mem.Allocator, twj: TableWithJoins, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    try extractTablesFromTableFactor(alloc, twj.relation, out);
    for (twj.joins) |join| {
        try extractTablesFromTableFactor(alloc, join.relation, out);
        // Walk join constraint for subqueries
        const constraint = switch (join.join_operator) {
            .join => |c| c,
            .inner => |c| c,
            .left_outer => |c| c,
            .right_outer => |c| c,
            .full_outer => |c| c,
            .cross_join, .natural_inner, .natural_left, .natural_right, .natural_full => JoinConstraint.none,
        };
        switch (constraint) {
            .on => |*e| try extractTablesFromExpr(alloc, e, out),
            .using, .natural, .none => {},
        }
    }
}

fn extractTablesFromTableFactor(alloc: std.mem.Allocator, tf: TableFactor, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    switch (tf) {
        .table => |t| {
            try addTableRef(alloc, out, t.name, if (t.alias) |a| a.name.value else null);
        },
        .derived => |d| try extractTablesFromQuery(alloc, d.subquery, out),
        .table_function => |f| try extractTablesFromExpr(alloc, &f.expr, out),
        .unnest => |u| {
            for (u.array_exprs) |*e| try extractTablesFromExpr(alloc, e, out);
        },
        .nested_join => |nj| try extractTablesFromTWJ(alloc, nj.table_with_joins.*, out),
    }
}

fn extractTablesFromExpr(alloc: std.mem.Allocator, expr: *const Expr, out: *std.ArrayListUnmanaged(TableRef)) std.mem.Allocator.Error!void {
    switch (expr.*) {
        .subquery => |q| try extractTablesFromQuery(alloc, q, out),
        .in_subquery => |is| {
            try extractTablesFromExpr(alloc, is.expr, out);
            try extractTablesFromQuery(alloc, is.subquery, out);
        },
        .exists => |e| try extractTablesFromQuery(alloc, e.subquery, out),
        .binary_op => |b| {
            try extractTablesFromExpr(alloc, b.left, out);
            try extractTablesFromExpr(alloc, b.right, out);
        },
        .unary_op => |u| try extractTablesFromExpr(alloc, u.expr, out),
        .nested => |n| try extractTablesFromExpr(alloc, n, out),
        .function => |f| {
            for (f.args) |arg| {
                switch (arg) {
                    .unnamed => |fa| switch (fa) {
                        .expr => |e| try extractTablesFromExpr(alloc, e, out),
                        .qualified_wildcard, .wildcard => {},
                    },
                    .named => |na| switch (na.arg) {
                        .expr => |e| try extractTablesFromExpr(alloc, e, out),
                        .qualified_wildcard, .wildcard => {},
                    },
                }
            }
            if (f.filter) |fl| try extractTablesFromExpr(alloc, fl, out);
        },
        .case => |c| {
            if (c.operand) |op| try extractTablesFromExpr(alloc, op, out);
            for (c.conditions) |cw| {
                try extractTablesFromExpr(alloc, &cw.condition, out);
                try extractTablesFromExpr(alloc, &cw.result, out);
            }
            if (c.else_result) |er| try extractTablesFromExpr(alloc, er, out);
        },
        .between => |b| {
            try extractTablesFromExpr(alloc, b.expr, out);
            try extractTablesFromExpr(alloc, b.low, out);
            try extractTablesFromExpr(alloc, b.high, out);
        },
        .in_list => |il| {
            try extractTablesFromExpr(alloc, il.expr, out);
            for (il.list) |*e| try extractTablesFromExpr(alloc, e, out);
        },
        .like => |l| {
            try extractTablesFromExpr(alloc, l.expr, out);
            try extractTablesFromExpr(alloc, l.pattern, out);
        },
        .ilike => |l| {
            try extractTablesFromExpr(alloc, l.expr, out);
            try extractTablesFromExpr(alloc, l.pattern, out);
        },
        .rlike => |r| {
            try extractTablesFromExpr(alloc, r.expr, out);
            try extractTablesFromExpr(alloc, r.pattern, out);
        },
        .cast => |c| try extractTablesFromExpr(alloc, c.expr, out),
        .is_null, .is_not_null, .is_true, .is_not_true, .is_false, .is_not_false => |e| {
            try extractTablesFromExpr(alloc, e, out);
        },
        .is_distinct_from => |d| {
            try extractTablesFromExpr(alloc, d.left, out);
            try extractTablesFromExpr(alloc, d.right, out);
        },
        .is_not_distinct_from => |d| {
            try extractTablesFromExpr(alloc, d.left, out);
            try extractTablesFromExpr(alloc, d.right, out);
        },
        .tuple, .array => |elems| {
            for (elems) |*e| try extractTablesFromExpr(alloc, e, out);
        },
        .at_time_zone => |atz| {
            try extractTablesFromExpr(alloc, atz.timestamp, out);
            try extractTablesFromExpr(alloc, atz.time_zone, out);
        },
        .extract => |e| try extractTablesFromExpr(alloc, e.expr, out),
        .convert => |c| try extractTablesFromExpr(alloc, c.expr, out),
        .substring => |s| {
            try extractTablesFromExpr(alloc, s.expr, out);
            if (s.from) |f| try extractTablesFromExpr(alloc, f, out);
            if (s.@"for") |f| try extractTablesFromExpr(alloc, f, out);
        },
        .trim => |t| {
            try extractTablesFromExpr(alloc, t.expr, out);
            if (t.trim_what) |tw| try extractTablesFromExpr(alloc, tw, out);
        },
        .position => |p| {
            try extractTablesFromExpr(alloc, p.expr, out);
            try extractTablesFromExpr(alloc, p.in, out);
        },
        .interval => |i| try extractTablesFromExpr(alloc, i.value, out),
        .collate => |c| try extractTablesFromExpr(alloc, c.expr, out),
        .grouping_sets, .rollup, .cube => |sets| {
            for (sets) |group| {
                for (group) |*e| try extractTablesFromExpr(alloc, e, out);
            }
        },
        // Leaves that cannot contain subqueries
        .identifier, .compound_identifier, .value, .wildcard, .qualified_wildcard, .match_against => {},
    }
}

fn addTableRef(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(TableRef), name: ObjectName, alias: ?[]const u8) !void {
    if (name.parts.len == 0) return;
    const ref: TableRef = if (name.parts.len == 1) .{
        .schema_name = null,
        .table_name = name.parts[0].value,
        .alias = alias,
    } else .{
        .schema_name = name.parts[0].value,
        .table_name = name.parts[name.parts.len - 1].value,
        .alias = alias,
    };
    try out.append(alloc, ref);
}

// =========================================================================
// Column Dependency Extraction
// =========================================================================

/// How a column is used in the query.
pub const ColumnUsage = enum {
    select,
    join,
    where,
    group_by,
    order_by,
    having,
    insert,
    update,
};

/// A column reference found in the query.
pub const ColumnRef = struct {
    /// Schema name, or null if not specified or not resolvable.
    schema: ?[]const u8,
    /// Table name or alias prefix. Null if column has no table qualifier.
    table: ?[]const u8,
    /// Table alias if the table qualifier matches a known alias. Null otherwise.
    table_alias: ?[]const u8,
    /// Column name.
    column_name: []const u8,
    /// Column alias from SELECT projection. Null if not aliased or not in projection.
    column_alias: ?[]const u8,
    /// Where this column is used.
    usage: ColumnUsage,
};

/// Extract all column dependencies from statements.
pub fn extractColumns(allocator: std.mem.Allocator, stmts: []const Statement) ![]ColumnRef {
    var ctx = ColumnExtractor{
        .results = .empty,
        .alias_map = .empty,
        .alloc = allocator,
    };
    for (stmts) |stmt| {
        try ctx.walkStatement(stmt);
    }
    return ctx.results.toOwnedSlice(allocator);
}

const Err = std.mem.Allocator.Error;

const AliasEntry = struct {
    alias_name: []const u8,
    schema: ?[]const u8,
    table_name: []const u8,
};

const ColumnExtractor = struct {
    results: std.ArrayListUnmanaged(ColumnRef),
    alias_map: std.ArrayListUnmanaged(AliasEntry),
    alloc: std.mem.Allocator,
    current_usage: ColumnUsage = .select,
    current_column_alias: ?[]const u8 = null,

    fn walkStatement(self: *ColumnExtractor, stmt: Statement) Err!void {
        switch (stmt) {
            .select => |q| try self.walkQuery(q),
            .insert => |ins| {
                switch (ins.source) {
                    .select => |q| try self.walkQuery(q),
                    .values => |vals| {
                        const prev = self.current_usage;
                        self.current_usage = .insert;
                        for (vals.rows) |row| {
                            for (row) |*e| try self.walkExpr(e);
                        }
                        self.current_usage = prev;
                    },
                    .assignments => |assigns| {
                        const prev = self.current_usage;
                        self.current_usage = .insert;
                        for (assigns) |a| try self.walkExpr(&a.value);
                        self.current_usage = prev;
                    },
                    .default_values => {},
                }
                if (ins.on_duplicate_key_update) |odku| {
                    const prev = self.current_usage;
                    self.current_usage = .update;
                    for (odku) |a| try self.walkExpr(&a.value);
                    self.current_usage = prev;
                }
            },
            .update => |upd| {
                const saved_map_len = self.alias_map.items.len;
                defer self.alias_map.shrinkRetainingCapacity(saved_map_len);
                for (upd.table) |twj| try self.collectAliases(twj);
                if (upd.from) |from| {
                    for (from) |twj| try self.collectAliases(twj);
                }
                const prev = self.current_usage;
                self.current_usage = .update;
                for (upd.assignments) |a| try self.walkExpr(&a.value);
                if (upd.selection) |*e| {
                    self.current_usage = .where;
                    try self.walkExpr(e);
                }
                for (upd.order_by) |obe| {
                    self.current_usage = .order_by;
                    try self.walkExpr(&obe.expr);
                }
                self.current_usage = prev;
            },
            .delete => |del| {
                const saved_map_len = self.alias_map.items.len;
                defer self.alias_map.shrinkRetainingCapacity(saved_map_len);
                for (del.from) |twj| try self.collectAliases(twj);
                const prev = self.current_usage;
                if (del.selection) |*e| {
                    self.current_usage = .where;
                    try self.walkExpr(e);
                }
                for (del.order_by) |obe| {
                    self.current_usage = .order_by;
                    try self.walkExpr(&obe.expr);
                }
                self.current_usage = prev;
            },
            else => {},
        }
    }

    fn walkQuery(self: *ColumnExtractor, query: *const Query) Err!void {
        if (query.with) |with| {
            for (with.cte_tables) |cte| try self.walkQuery(cte.query);
        }
        try self.walkSetExpr(query.body);
        if (query.order_by) |ob| {
            const prev = self.current_usage;
            self.current_usage = .order_by;
            for (ob.exprs) |obe| try self.walkExpr(&obe.expr);
            self.current_usage = prev;
        }
    }

    fn walkSetExpr(self: *ColumnExtractor, se: *const SetExpr) Err!void {
        switch (se.*) {
            .select => |sel| try self.walkSelect(sel),
            .query => |q| try self.walkQuery(q),
            .set_operation => |sop| {
                try self.walkSetExpr(sop.left);
                try self.walkSetExpr(sop.right);
            },
            .values => {},
        }
    }

    fn walkSelect(self: *ColumnExtractor, sel: *const Select) Err!void {
        const saved_map_len = self.alias_map.items.len;
        defer self.alias_map.shrinkRetainingCapacity(saved_map_len);
        for (sel.from) |twj| try self.collectAliases(twj);

        const prev = self.current_usage;
        self.current_usage = .select;
        for (sel.projection) |item| {
            switch (item) {
                .unnamed_expr => |*e| {
                    self.current_column_alias = null;
                    try self.walkExpr(e);
                },
                .expr_with_alias => |*ewa| {
                    self.current_column_alias = ewa.alias.value;
                    try self.walkExpr(&ewa.expr);
                    self.current_column_alias = null;
                },
                .qualified_wildcard, .wildcard => {},
            }
        }

        for (sel.from) |twj| {
            try self.walkTableWithJoinsExprs(twj);
        }

        if (sel.selection) |*e| {
            self.current_usage = .where;
            try self.walkExpr(e);
        }

        switch (sel.group_by) {
            .expressions => |exprs| {
                self.current_usage = .group_by;
                for (exprs) |*e| try self.walkExpr(e);
            },
            .all => {},
        }

        if (sel.having) |*e| {
            self.current_usage = .having;
            try self.walkExpr(e);
        }

        self.current_usage = prev;
    }

    fn walkTableWithJoinsExprs(self: *ColumnExtractor, twj: TableWithJoins) Err!void {
        switch (twj.relation) {
            .derived => |d| try self.walkQuery(d.subquery),
            .table_function => |f| try self.walkExpr(&f.expr),
            .nested_join => |nj| try self.walkTableWithJoinsExprs(nj.table_with_joins.*),
            .table, .unnest => {},
        }
        for (twj.joins) |join| {
            switch (join.relation) {
                .derived => |d| try self.walkQuery(d.subquery),
                .table_function => |f| try self.walkExpr(&f.expr),
                .nested_join => |nj| try self.walkTableWithJoinsExprs(nj.table_with_joins.*),
                .table, .unnest => {},
            }
            const constraint = switch (join.join_operator) {
                .join => |c| c,
                .inner => |c| c,
                .left_outer => |c| c,
                .right_outer => |c| c,
                .full_outer => |c| c,
                .cross_join, .natural_inner, .natural_left, .natural_right, .natural_full => JoinConstraint.none,
            };
            switch (constraint) {
                .on => |*e| {
                    const prev = self.current_usage;
                    self.current_usage = .join;
                    try self.walkExpr(e);
                    self.current_usage = prev;
                },
                .using, .natural, .none => {},
            }
        }
    }

    fn collectAliases(self: *ColumnExtractor, twj: TableWithJoins) Err!void {
        try self.collectAliasFromTableFactor(twj.relation);
        for (twj.joins) |join| {
            try self.collectAliasFromTableFactor(join.relation);
        }
    }

    fn collectAliasFromTableFactor(self: *ColumnExtractor, tf: TableFactor) Err!void {
        switch (tf) {
            .table => |t| {
                if (t.alias) |a| {
                    const schema = if (t.name.parts.len > 1) t.name.parts[0].value else null;
                    const table_name = if (t.name.parts.len > 0) t.name.parts[t.name.parts.len - 1].value else return;
                    try self.alias_map.append(self.alloc, .{
                        .alias_name = a.name.value,
                        .schema = schema,
                        .table_name = table_name,
                    });
                }
            },
            .derived => {},
            .nested_join => |nj| try self.collectAliases(nj.table_with_joins.*),
            .table_function, .unnest => {},
        }
    }

    fn resolveAlias(self: *ColumnExtractor, name: []const u8) ?AliasEntry {
        var i: usize = self.alias_map.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.alias_map.items[i].alias_name, name)) {
                return self.alias_map.items[i];
            }
        }
        return null;
    }

    fn walkExpr(self: *ColumnExtractor, expr: *const Expr) Err!void {
        switch (expr.*) {
            .identifier => |ident| {
                try self.emitColumnRef(null, null, null, ident.value);
            },
            .compound_identifier => |parts| {
                switch (parts.len) {
                    2 => {
                        const prefix = parts[0].value;
                        const col = parts[1].value;
                        if (self.resolveAlias(prefix)) |entry| {
                            try self.emitColumnRef(entry.schema, entry.table_name, entry.alias_name, col);
                        } else {
                            try self.emitColumnRef(null, prefix, null, col);
                        }
                    },
                    3 => {
                        try self.emitColumnRef(parts[0].value, parts[1].value, null, parts[2].value);
                    },
                    else => {
                        if (parts.len == 1) {
                            try self.emitColumnRef(null, null, null, parts[0].value);
                        }
                    },
                }
            },
            .binary_op => |b| {
                try self.walkExpr(b.left);
                try self.walkExpr(b.right);
            },
            .unary_op => |u| try self.walkExpr(u.expr),
            .nested => |n| try self.walkExpr(n),
            .is_null, .is_not_null, .is_true, .is_not_true, .is_false, .is_not_false => |e| try self.walkExpr(e),
            .is_distinct_from => |d| {
                try self.walkExpr(d.left);
                try self.walkExpr(d.right);
            },
            .is_not_distinct_from => |d| {
                try self.walkExpr(d.left);
                try self.walkExpr(d.right);
            },
            .between => |b| {
                try self.walkExpr(b.expr);
                try self.walkExpr(b.low);
                try self.walkExpr(b.high);
            },
            .in_list => |il| {
                try self.walkExpr(il.expr);
                for (il.list) |*e| try self.walkExpr(e);
            },
            .in_subquery => |is| {
                try self.walkExpr(is.expr);
                try self.walkQuery(is.subquery);
            },
            .like => |l| {
                try self.walkExpr(l.expr);
                try self.walkExpr(l.pattern);
            },
            .ilike => |l| {
                try self.walkExpr(l.expr);
                try self.walkExpr(l.pattern);
            },
            .rlike => |r| {
                try self.walkExpr(r.expr);
                try self.walkExpr(r.pattern);
            },
            .case => |c| {
                if (c.operand) |op| try self.walkExpr(op);
                for (c.conditions) |cw| {
                    try self.walkExpr(&cw.condition);
                    try self.walkExpr(&cw.result);
                }
                if (c.else_result) |er| try self.walkExpr(er);
            },
            .exists => |e| try self.walkQuery(e.subquery),
            .subquery => |q| try self.walkQuery(q),
            .cast => |c| try self.walkExpr(c.expr),
            .at_time_zone => |atz| {
                try self.walkExpr(atz.timestamp);
                try self.walkExpr(atz.time_zone);
            },
            .extract => |e| try self.walkExpr(e.expr),
            .convert => |c| try self.walkExpr(c.expr),
            .substring => |s| {
                try self.walkExpr(s.expr);
                if (s.from) |f| try self.walkExpr(f);
                if (s.@"for") |f| try self.walkExpr(f);
            },
            .trim => |t| {
                try self.walkExpr(t.expr);
                if (t.trim_what) |tw| try self.walkExpr(tw);
            },
            .position => |p| {
                try self.walkExpr(p.expr);
                try self.walkExpr(p.in);
            },
            .interval => |i| try self.walkExpr(i.value),
            .function => |func| {
                for (func.args) |arg| {
                    switch (arg) {
                        .unnamed => |fa| switch (fa) {
                            .expr => |e| try self.walkExpr(e),
                            .qualified_wildcard, .wildcard => {},
                        },
                        .named => |na| switch (na.arg) {
                            .expr => |e| try self.walkExpr(e),
                            .qualified_wildcard, .wildcard => {},
                        },
                    }
                }
                if (func.filter) |f| try self.walkExpr(f);
                if (func.over) |over| {
                    for (over.partition_by) |*e| try self.walkExpr(e);
                    for (over.order_by) |obe| try self.walkExpr(&obe.expr);
                }
            },
            .collate => |c| try self.walkExpr(c.expr),
            .tuple, .array => |elems| {
                for (elems) |*e| try self.walkExpr(e);
            },
            .grouping_sets, .rollup, .cube => |sets| {
                for (sets) |group| {
                    for (group) |*e| try self.walkExpr(e);
                }
            },
            .value, .wildcard, .qualified_wildcard, .match_against => {},
        }
    }

    fn emitColumnRef(self: *ColumnExtractor, schema: ?[]const u8, table: ?[]const u8, table_alias: ?[]const u8, column_name: []const u8) Err!void {
        try self.results.append(self.alloc, .{
            .schema = schema,
            .table = table,
            .table_alias = table_alias,
            .column_name = column_name,
            .column_alias = self.current_column_alias,
            .usage = self.current_usage,
        });
    }
};

// =========================================================================
// Tests
// =========================================================================

fn testParse(alloc: std.mem.Allocator, sql: []const u8) ![]Statement {
    const root = @import("root.zig");
    return root.parse(alloc, sql, .Generic, .{ .kind = .generic });
}

// -- Query Classification Tests --

test "classify SELECT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "SELECT 1");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.dml, c.category);
    try std.testing.expectEqual(QueryType.select, c.query_type);
}

test "classify INSERT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "INSERT INTO t1 (a) VALUES (1)");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.dml, c.category);
    try std.testing.expectEqual(QueryType.insert, c.query_type);
}

test "classify REPLACE INTO" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "REPLACE INTO t1 (a) VALUES (1)");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.dml, c.category);
    try std.testing.expectEqual(QueryType.replace, c.query_type);
}

test "classify UPDATE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "UPDATE t1 SET a = 1");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.dml, c.category);
    try std.testing.expectEqual(QueryType.update, c.query_type);
}

test "classify DELETE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "DELETE FROM t1 WHERE id = 1");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.dml, c.category);
    try std.testing.expectEqual(QueryType.delete, c.query_type);
}

test "classify CREATE TABLE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "CREATE TABLE t1 (id INT)");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.ddl, c.category);
    try std.testing.expectEqual(QueryType.create, c.query_type);
}

test "classify ALTER TABLE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "ALTER TABLE t1 ADD COLUMN x INT");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.ddl, c.category);
    try std.testing.expectEqual(QueryType.alter, c.query_type);
}

test "classify DROP TABLE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "DROP TABLE t1");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.ddl, c.category);
    try std.testing.expectEqual(QueryType.drop, c.query_type);
}

test "classify CTE as SELECT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "WITH cte AS (SELECT 1) SELECT * FROM cte");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.dml, c.category);
    try std.testing.expectEqual(QueryType.select, c.query_type);
}

test "classify CREATE TABLE AS SELECT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "CREATE TABLE foo AS SELECT 1 AS c");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.ddl, c.category);
    try std.testing.expectEqual(QueryType.create, c.query_type);
}

test "classify SHOW TABLES" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "SHOW TABLES");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryCategory.show, c.category);
    try std.testing.expectEqual(QueryType.show, c.query_type);
}

test "classify BEGIN/COMMIT/ROLLBACK" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    {
        const stmts = try testParse(arena.allocator(), "BEGIN");
        try std.testing.expectEqual(QueryType.begin, classifyStatement(stmts[0]).query_type);
    }
    {
        const stmts = try testParse(arena.allocator(), "COMMIT");
        try std.testing.expectEqual(QueryType.commit, classifyStatement(stmts[0]).query_type);
    }
    {
        const stmts = try testParse(arena.allocator(), "ROLLBACK");
        try std.testing.expectEqual(QueryType.rollback, classifyStatement(stmts[0]).query_type);
    }
}

test "classify UNION as SELECT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stmts = try testParse(arena.allocator(), "SELECT 1 UNION SELECT 2");
    const c = classifyStatement(stmts[0]);
    try std.testing.expectEqual(QueryType.select, c.query_type);
}

// -- Table Extraction Tests --

test "extract tables from simple SELECT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM users");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqualStrings("users", tables[0].table_name);
    try std.testing.expect(tables[0].schema_name == null);
    try std.testing.expect(tables[0].alias == null);
}

test "extract tables with schema" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM mydb.users");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqualStrings("mydb", tables[0].schema_name.?);
    try std.testing.expectEqualStrings("users", tables[0].table_name);
}

test "extract tables with alias" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM users AS u");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqualStrings("users", tables[0].table_name);
    try std.testing.expectEqualStrings("u", tables[0].alias.?);
}

test "extract tables from JOIN" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 2), tables.len);
    try std.testing.expectEqualStrings("t1", tables[0].table_name);
    try std.testing.expectEqualStrings("t2", tables[1].table_name);
}

test "extract tables from subquery" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM t1 WHERE id IN (SELECT id FROM t2)");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 2), tables.len);
    try std.testing.expectEqualStrings("t1", tables[0].table_name);
    try std.testing.expectEqualStrings("t2", tables[1].table_name);
}

test "extract tables from CTE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "WITH cte AS (SELECT * FROM t1) SELECT * FROM cte JOIN t2 ON cte.id = t2.id");
    const tables = try extractTables(alloc, stmts);
    // t1 from CTE body, cte from main query, t2 from main query
    try std.testing.expectEqual(@as(usize, 3), tables.len);
}

test "extract tables from INSERT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "INSERT INTO t1 SELECT * FROM t2");
    const tables = try extractTables(alloc, stmts);
    // t1 (target) + t2 (source)
    try std.testing.expectEqual(@as(usize, 2), tables.len);
}

test "extract tables from UPDATE with JOIN" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "UPDATE t1 SET a = 1 WHERE id IN (SELECT id FROM t2)");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expect(tables.len >= 2);
}

test "extract tables from CREATE TABLE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "CREATE TABLE mydb.new_table (id INT)");
    const tables = try extractTables(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), tables.len);
    try std.testing.expectEqualStrings("mydb", tables[0].schema_name.?);
    try std.testing.expectEqualStrings("new_table", tables[0].table_name);
}

// -- Column Extraction Tests --

test "extract columns from simple SELECT" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT a, b FROM t1");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("a", cols[0].column_name);
    try std.testing.expectEqual(ColumnUsage.select, cols[0].usage);
    try std.testing.expect(cols[0].table == null);
    try std.testing.expectEqualStrings("b", cols[1].column_name);
}

test "extract columns with table prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT t.col1, t.col2 FROM users AS t");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("col1", cols[0].column_name);
    // t is an alias for users
    try std.testing.expectEqualStrings("users", cols[0].table.?);
    try std.testing.expectEqualStrings("t", cols[0].table_alias.?);
}

test "extract columns with schema.table.column" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT mydb.users.name FROM mydb.users");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("mydb", cols[0].schema.?);
    try std.testing.expectEqualStrings("users", cols[0].table.?);
    try std.testing.expectEqualStrings("name", cols[0].column_name);
}

test "extract columns with alias" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT name AS n FROM users");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("name", cols[0].column_name);
    try std.testing.expectEqualStrings("n", cols[0].column_alias.?);
}

test "extract columns from WHERE" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM t1 WHERE active = 1");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("active", cols[0].column_name);
    try std.testing.expectEqual(ColumnUsage.where, cols[0].usage);
}

test "extract columns from JOIN ON" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM t1 JOIN t2 ON t1.id = t2.fk");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqual(ColumnUsage.join, cols[0].usage);
    try std.testing.expectEqualStrings("id", cols[0].column_name);
    try std.testing.expectEqualStrings("t1", cols[0].table.?);
    try std.testing.expectEqualStrings("fk", cols[1].column_name);
    try std.testing.expectEqualStrings("t2", cols[1].table.?);
}

test "extract columns from GROUP BY" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT dept, COUNT(*) FROM emp GROUP BY dept");
    const cols = try extractColumns(alloc, stmts);
    // dept in SELECT + dept in GROUP BY = 2
    var group_by_count: usize = 0;
    for (cols) |c| {
        if (c.usage == .group_by) group_by_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), group_by_count);
}

test "extract columns from ORDER BY" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT name FROM users ORDER BY created_at");
    const cols = try extractColumns(alloc, stmts);
    var order_count: usize = 0;
    for (cols) |c| {
        if (c.usage == .order_by) {
            try std.testing.expectEqualStrings("created_at", c.column_name);
            order_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), order_count);
}

test "extract columns from HAVING" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT dept FROM emp GROUP BY dept HAVING COUNT(salary) > 100");
    const cols = try extractColumns(alloc, stmts);
    var having_count: usize = 0;
    for (cols) |c| {
        if (c.usage == .having) {
            try std.testing.expectEqualStrings("salary", c.column_name);
            having_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), having_count);
}

test "extract columns inside function" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT SUM(t.amount) FROM orders AS t");
    const cols = try extractColumns(alloc, stmts);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("amount", cols[0].column_name);
    try std.testing.expectEqualStrings("orders", cols[0].table.?);
    try std.testing.expectEqualStrings("t", cols[0].table_alias.?);
}

test "extract columns skips literals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT 1, 'hello', a FROM t1");
    const cols = try extractColumns(alloc, stmts);
    // Only 'a' should be extracted; 1 and 'hello' are literals
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("a", cols[0].column_name);
}

test "extract columns from subquery" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stmts = try testParse(alloc, "SELECT * FROM t1 WHERE id IN (SELECT fk FROM t2 WHERE active = 1)");
    const cols = try extractColumns(alloc, stmts);
    // id (where), fk (select in subquery), active (where in subquery)
    try std.testing.expect(cols.len >= 3);
}

test "extract columns from complex query" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const sql =
        \\SELECT u.name AS user_name, o.total
        \\FROM users AS u
        \\JOIN orders AS o ON u.id = o.user_id
        \\WHERE o.status = 'active'
        \\GROUP BY u.name
        \\HAVING SUM(o.total) > 100
        \\ORDER BY u.name
    ;
    const stmts = try testParse(alloc, sql);
    const cols = try extractColumns(alloc, stmts);

    // Verify we get columns from different contexts
    var select_count: usize = 0;
    var join_count: usize = 0;
    var where_count: usize = 0;
    var group_count: usize = 0;
    var having_count: usize = 0;
    var order_count: usize = 0;
    for (cols) |c| {
        switch (c.usage) {
            .select => select_count += 1,
            .join => join_count += 1,
            .where => where_count += 1,
            .group_by => group_count += 1,
            .having => having_count += 1,
            .order_by => order_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), select_count); // u.name, o.total
    try std.testing.expectEqual(@as(usize, 2), join_count); // u.id, o.user_id
    try std.testing.expectEqual(@as(usize, 1), where_count); // o.status
    try std.testing.expectEqual(@as(usize, 1), group_count); // u.name
    try std.testing.expectEqual(@as(usize, 1), having_count); // o.total
    try std.testing.expectEqual(@as(usize, 1), order_count); // u.name

    // Verify alias resolution
    for (cols) |c| {
        if (std.mem.eql(u8, c.column_name, "name") and c.usage == .select) {
            try std.testing.expectEqualStrings("users", c.table.?);
            try std.testing.expectEqualStrings("u", c.table_alias.?);
            try std.testing.expectEqualStrings("user_name", c.column_alias.?);
        }
    }
}

test "extract columns from expressions and functions" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const sql = "SELECT col1, col2, col3 + col4 AS colx, UPPER(col5) AS coly FROM tbl WHERE CONCAT(col6, col7) = col8";
    const stmts = try testParse(alloc, sql);
    const cols = try extractColumns(alloc, stmts);

    // All 8 columns should be found
    const expected = [_][]const u8{ "col1", "col2", "col3", "col4", "col5", "col6", "col7", "col8" };
    for (expected) |exp| {
        var found = false;
        for (cols) |c| {
            if (std.mem.eql(u8, c.column_name, exp)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Missing column: {s}\n", .{exp});
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expectEqual(@as(usize, 8), cols.len);

    // Verify usage contexts
    for (cols) |c| {
        if (std.mem.eql(u8, c.column_name, "col3")) {
            try std.testing.expectEqual(ColumnUsage.select, c.usage);
            try std.testing.expectEqualStrings("colx", c.column_alias.?);
        }
        if (std.mem.eql(u8, c.column_name, "col5")) {
            try std.testing.expectEqual(ColumnUsage.select, c.usage);
            try std.testing.expectEqualStrings("coly", c.column_alias.?);
        }
        if (std.mem.eql(u8, c.column_name, "col6") or std.mem.eql(u8, c.column_name, "col7")) {
            try std.testing.expectEqual(ColumnUsage.where, c.usage);
        }
        if (std.mem.eql(u8, c.column_name, "col8")) {
            try std.testing.expectEqual(ColumnUsage.where, c.usage);
        }
    }
}

test "extract columns from nested expressions" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // CASE expression with nested columns
    const sql1 = "SELECT CASE WHEN a > 0 THEN b ELSE c END AS result FROM t1";
    const cols1 = try extractColumns(alloc, try testParse(alloc, sql1));
    const exp1 = [_][]const u8{ "a", "b", "c" };
    for (exp1) |exp| {
        var found = false;
        for (cols1) |c| {
            if (std.mem.eql(u8, c.column_name, exp)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Missing column in CASE: {s}\n", .{exp});
            return error.TestExpectedEqual;
        }
    }

    // Arithmetic in WHERE with function in SELECT
    const sql2 = "SELECT COUNT(x) FROM t1 WHERE (a + b) * c > d";
    const cols2 = try extractColumns(alloc, try testParse(alloc, sql2));
    const exp2 = [_][]const u8{ "x", "a", "b", "c", "d" };
    for (exp2) |exp| {
        var found = false;
        for (cols2) |col| {
            if (std.mem.eql(u8, col.column_name, exp)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Missing column in nested arith: {s}\n", .{exp});
            return error.TestExpectedEqual;
        }
    }

    // CAST and nested function
    const sql3 = "SELECT CAST(price AS INT) FROM t1 WHERE COALESCE(a, b) = c";
    const cols3 = try extractColumns(alloc, try testParse(alloc, sql3));
    const exp3 = [_][]const u8{ "price", "a", "b", "c" };
    for (exp3) |exp| {
        var found = false;
        for (cols3) |col| {
            if (std.mem.eql(u8, col.column_name, exp)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Missing column in CAST/COALESCE: {s}\n", .{exp});
            return error.TestExpectedEqual;
        }
    }
}
