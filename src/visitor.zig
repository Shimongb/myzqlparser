/// Generic AST visitor/walker infrastructure.
///
/// Provides a comptime-generic Walker that traverses all AST nodes in pre-order.
/// Users supply a visitor struct with optional callback methods; the walker calls
/// them at each node and respects the returned Action to control traversal.
///
/// Example usage:
///   const MyVisitor = struct {
///       count: usize = 0,
///       pub fn visitExpr(self: *MyVisitor, _: *const Expr) Action {
///           self.count += 1;
///           return .@"continue";
///       }
///       const Action = Walker(MyVisitor).Action;
///   };
///   var v = MyVisitor{};
///   var w = Walker(MyVisitor).init(&v);
///   w.walkStatements(stmts);
const std = @import("std");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const ast_dml = @import("ast_dml.zig");
const ast_ddl = @import("ast_ddl.zig");

pub const Statement = ast.Statement;
pub const Expr = ast.Expr;
pub const Query = ast_query.Query;
pub const Select = ast_query.Select;
pub const SetExpr = ast_query.SetExpr;
pub const SelectItem = ast_query.SelectItem;
pub const TableWithJoins = ast_query.TableWithJoins;
pub const TableFactor = ast_query.TableFactor;
pub const Join = ast_query.Join;
pub const JoinOperator = ast_query.JoinOperator;
pub const JoinConstraint = ast_query.JoinConstraint;
pub const GroupByExpr = ast_query.GroupByExpr;
pub const Insert = ast_dml.Insert;
pub const Update = ast_dml.Update;
pub const Delete = ast_dml.Delete;
pub const CreateTable = ast_ddl.CreateTable;
pub const AlterTable = ast_ddl.AlterTable;
pub const CreateIndex = ast_ddl.CreateIndex;
pub const CreateView = ast_ddl.CreateView;

/// Comptime-generic AST walker. V is a visitor struct that may define optional
/// callback methods. Each callback receives the relevant AST node and returns
/// an Action controlling traversal.
///
/// Supported callbacks (all optional):
///   visitStatement(*V, Statement) Action
///   visitQuery(*V, *const Query) Action
///   visitSelect(*V, *const Select) Action
///   visitExpr(*V, *const Expr) Action
///   visitTableFactor(*V, TableFactor) Action
///   visitJoin(*V, Join) Action
///   visitSelectItem(*V, SelectItem) Action
///
/// Leave callbacks (called after children are walked):
///   leaveStatement(*V, Statement) void
///   leaveQuery(*V, *const Query) void
///   leaveSelect(*V, *const Select) void
pub fn Walker(comptime V: type) type {
    return struct {
        visitor: *V,
        stopped: bool = false,

        const Self = @This();

        /// Controls walker traversal after a visitor callback.
        pub const Action = enum {
            /// Continue walking into children.
            @"continue",
            /// Skip this node's children but continue with siblings.
            skip_children,
            /// Stop all traversal immediately.
            stop,
        };

        /// Create a walker bound to a visitor instance.
        pub fn init(visitor: *V) Self {
            return .{ .visitor = visitor };
        }

        /// Walk a slice of statements.
        pub fn walkStatements(self: *Self, stmts: []const Statement) void {
            for (stmts) |stmt| {
                self.walkStatement(stmt);
                if (self.stopped) return;
            }
        }

        /// Walk a single statement.
        pub fn walkStatement(self: *Self, stmt: Statement) void {
            if (self.stopped) return;
            if (self.callVisit("visitStatement", .{stmt}) != .@"continue") {
                if (!self.stopped) {
                    if (@hasDecl(V, "leaveStatement")) self.visitor.leaveStatement(stmt);
                }
                return;
            }
            self.walkStatementChildren(stmt);
            if (@hasDecl(V, "leaveStatement")) self.visitor.leaveStatement(stmt);
        }

        fn walkStatementChildren(self: *Self, stmt: Statement) void {
            switch (stmt) {
                .select => |q| self.walkQuery(q),
                .insert => |ins| self.walkInsert(ins),
                .update => |upd| self.walkUpdate(upd),
                .delete => |del| self.walkDelete(del),
                .create_table => |ct| self.walkCreateTable(ct),
                .alter_table => |at| self.walkAlterTable(at),
                .create_index => |ci| self.walkCreateIndex(ci),
                .create_view => |cv| self.walkQuery(cv.query),
                .set => |s| self.walkExpr(&s.value),
                .drop, .drop_view, .rename_table, .show_tables, .show_columns, .show_create_table, .show_databases, .show_create_view, .lock_tables, .unlock_tables, .start_transaction, .commit, .rollback, .use_db => {},
            }
        }

        /// Walk a Query node.
        pub fn walkQuery(self: *Self, query: *const Query) void {
            if (self.stopped) return;
            if (self.callVisit("visitQuery", .{query}) != .@"continue") {
                if (!self.stopped) {
                    if (@hasDecl(V, "leaveQuery")) self.visitor.leaveQuery(query);
                }
                return;
            }
            // CTEs
            if (query.with) |with| {
                for (with.cte_tables) |cte| {
                    self.walkQuery(cte.query);
                    if (self.stopped) return;
                }
            }
            // Body
            self.walkSetExpr(query.body);
            if (self.stopped) return;
            // ORDER BY
            if (query.order_by) |ob| {
                for (ob.exprs) |obe| {
                    self.walkExpr(&obe.expr);
                    if (self.stopped) return;
                }
            }
            // LIMIT
            if (query.limit_clause) |lc| {
                switch (lc) {
                    .limit_offset => |lo| {
                        if (lo.limit) |*l| self.walkExpr(l);
                        if (lo.offset) |*o| self.walkExpr(o);
                    },
                    .limit_comma => |lm| {
                        self.walkExpr(&lm.offset);
                        self.walkExpr(&lm.limit);
                    },
                }
            }
            if (query.fetch) |f| {
                if (f.quantity) |*q| self.walkExpr(q);
            }
            if (@hasDecl(V, "leaveQuery")) self.visitor.leaveQuery(query);
        }

        fn walkSetExpr(self: *Self, set_expr: *const SetExpr) void {
            if (self.stopped) return;
            switch (set_expr.*) {
                .select => |sel| self.walkSelect(sel),
                .query => |q| self.walkQuery(q),
                .set_operation => |sop| {
                    self.walkSetExpr(sop.left);
                    if (!self.stopped) self.walkSetExpr(sop.right);
                },
                .values => |vals| {
                    for (vals.rows) |row| {
                        for (row) |*expr| {
                            self.walkExpr(expr);
                            if (self.stopped) return;
                        }
                    }
                },
            }
        }

        /// Walk a Select node.
        pub fn walkSelect(self: *Self, sel: *const Select) void {
            if (self.stopped) return;
            if (self.callVisit("visitSelect", .{sel}) != .@"continue") {
                if (!self.stopped) {
                    if (@hasDecl(V, "leaveSelect")) self.visitor.leaveSelect(sel);
                }
                return;
            }
            // Projection
            for (sel.projection) |item| {
                self.walkSelectItem(item);
                if (self.stopped) return;
            }
            // FROM
            for (sel.from) |twj| {
                self.walkTableWithJoins(twj);
                if (self.stopped) return;
            }
            // WHERE
            if (sel.selection) |*expr| {
                self.walkExpr(expr);
                if (self.stopped) return;
            }
            // GROUP BY
            switch (sel.group_by) {
                .expressions => |exprs| {
                    for (exprs) |*expr| {
                        self.walkExpr(expr);
                        if (self.stopped) return;
                    }
                },
                .all => {},
            }
            // HAVING
            if (sel.having) |*expr| {
                self.walkExpr(expr);
                if (self.stopped) return;
            }
            // WINDOW definitions
            for (sel.named_window) |nw| {
                self.walkWindowSpec(nw.spec);
                if (self.stopped) return;
            }
            if (@hasDecl(V, "leaveSelect")) self.visitor.leaveSelect(sel);
        }

        fn walkWindowSpec(self: *Self, spec: ast.WindowSpec) void {
            for (spec.partition_by) |*expr| {
                self.walkExpr(expr);
                if (self.stopped) return;
            }
            for (spec.order_by) |obe| {
                self.walkExpr(&obe.expr);
                if (self.stopped) return;
            }
            if (spec.window_frame) |wf| {
                self.walkWindowFrameBound(wf.start_bound);
                if (wf.end_bound) |eb| self.walkWindowFrameBound(eb);
            }
        }

        fn walkWindowFrameBound(self: *Self, bound: ast.WindowFrameBound) void {
            switch (bound) {
                .preceding => |e| self.walkExpr(e),
                .following => |e| self.walkExpr(e),
                .current_row, .unbounded_preceding, .unbounded_following => {},
            }
        }

        pub fn walkTableWithJoins(self: *Self, twj: TableWithJoins) void {
            if (self.stopped) return;
            self.walkTableFactor(twj.relation);
            if (self.stopped) return;
            for (twj.joins) |join| {
                self.walkJoin(join);
                if (self.stopped) return;
            }
        }

        pub fn walkTableFactor(self: *Self, tf: TableFactor) void {
            if (self.stopped) return;
            if (self.callVisit("visitTableFactor", .{tf}) != .@"continue") return;
            switch (tf) {
                .table => {},
                .derived => |d| self.walkQuery(d.subquery),
                .table_function => |f| self.walkExpr(&f.expr),
                .unnest => |u| {
                    for (u.array_exprs) |*expr| {
                        self.walkExpr(expr);
                        if (self.stopped) return;
                    }
                },
                .nested_join => |nj| self.walkTableWithJoins(nj.table_with_joins.*),
            }
        }

        pub fn walkJoin(self: *Self, join: Join) void {
            if (self.stopped) return;
            if (self.callVisit("visitJoin", .{join}) != .@"continue") return;
            self.walkTableFactor(join.relation);
            if (self.stopped) return;
            // Walk join constraint expressions
            const constraint = switch (join.join_operator) {
                .join => |c| c,
                .inner => |c| c,
                .left_outer => |c| c,
                .right_outer => |c| c,
                .full_outer => |c| c,
                .cross_join, .natural_inner, .natural_left, .natural_right, .natural_full => return,
            };
            switch (constraint) {
                .on => |*expr| self.walkExpr(expr),
                .using, .natural, .none => {},
            }
        }

        fn walkSelectItem(self: *Self, item: SelectItem) void {
            if (self.stopped) return;
            if (self.callVisit("visitSelectItem", .{item}) != .@"continue") return;
            switch (item) {
                .unnamed_expr => |*expr| self.walkExpr(expr),
                .expr_with_alias => |*ewa| self.walkExpr(&ewa.expr),
                .qualified_wildcard, .wildcard => {},
            }
        }

        /// Walk an expression and all its children.
        pub fn walkExpr(self: *Self, expr: *const Expr) void {
            if (self.stopped) return;
            if (self.callVisit("visitExpr", .{expr}) != .@"continue") return;
            switch (expr.*) {
                // Leaves
                .identifier, .compound_identifier, .value, .wildcard, .qualified_wildcard => {},
                // Unary wrappers
                .is_null, .is_not_null, .is_true, .is_not_true, .is_false, .is_not_false => |e| self.walkExpr(e),
                .unary_op => |u| self.walkExpr(u.expr),
                .nested => |e| self.walkExpr(e),
                // Binary
                .binary_op => |b| {
                    self.walkExpr(b.left);
                    if (!self.stopped) self.walkExpr(b.right);
                },
                .is_distinct_from => |d| {
                    self.walkExpr(d.left);
                    if (!self.stopped) self.walkExpr(d.right);
                },
                .is_not_distinct_from => |d| {
                    self.walkExpr(d.left);
                    if (!self.stopped) self.walkExpr(d.right);
                },
                // Range
                .between => |b| {
                    self.walkExpr(b.expr);
                    if (!self.stopped) self.walkExpr(b.low);
                    if (!self.stopped) self.walkExpr(b.high);
                },
                .in_list => |il| {
                    self.walkExpr(il.expr);
                    if (self.stopped) return;
                    for (il.list) |*e| {
                        self.walkExpr(e);
                        if (self.stopped) return;
                    }
                },
                .in_subquery => |is| {
                    self.walkExpr(is.expr);
                    if (!self.stopped) self.walkQuery(is.subquery);
                },
                // Pattern matching
                .like => |l| {
                    self.walkExpr(l.expr);
                    if (!self.stopped) self.walkExpr(l.pattern);
                },
                .ilike => |l| {
                    self.walkExpr(l.expr);
                    if (!self.stopped) self.walkExpr(l.pattern);
                },
                .rlike => |l| {
                    self.walkExpr(l.expr);
                    if (!self.stopped) self.walkExpr(l.pattern);
                },
                // CASE
                .case => |c| {
                    if (c.operand) |op| self.walkExpr(op);
                    for (c.conditions) |cw| {
                        if (self.stopped) return;
                        self.walkExpr(&cw.condition);
                        if (!self.stopped) self.walkExpr(&cw.result);
                    }
                    if (c.else_result) |er| {
                        if (!self.stopped) self.walkExpr(er);
                    }
                },
                // Subqueries
                .exists => |e| self.walkQuery(e.subquery),
                .subquery => |q| self.walkQuery(q),
                // Type ops
                .cast => |c| self.walkExpr(c.expr),
                .at_time_zone => |atz| {
                    self.walkExpr(atz.timestamp);
                    if (!self.stopped) self.walkExpr(atz.time_zone);
                },
                .extract => |e| self.walkExpr(e.expr),
                .convert => |c| self.walkExpr(c.expr),
                // String functions
                .substring => |s| {
                    self.walkExpr(s.expr);
                    if (s.from) |f| {
                        if (!self.stopped) self.walkExpr(f);
                    }
                    if (s.@"for") |f| {
                        if (!self.stopped) self.walkExpr(f);
                    }
                },
                .trim => |t| {
                    self.walkExpr(t.expr);
                    if (t.trim_what) |tw| {
                        if (!self.stopped) self.walkExpr(tw);
                    }
                },
                .position => |p| {
                    self.walkExpr(p.expr);
                    if (!self.stopped) self.walkExpr(p.in);
                },
                // Interval
                .interval => |i| self.walkExpr(i.value),
                // Grouping
                .grouping_sets, .rollup, .cube => |sets| {
                    for (sets) |group| {
                        for (group) |*e| {
                            self.walkExpr(e);
                            if (self.stopped) return;
                        }
                    }
                },
                // Collections
                .tuple, .array => |elems| {
                    for (elems) |*e| {
                        self.walkExpr(e);
                        if (self.stopped) return;
                    }
                },
                // Function
                .function => |func| self.walkFunction(func),
                // Match against
                .match_against => {},
                // Collate
                .collate => |c| self.walkExpr(c.expr),
            }
        }

        fn walkFunction(self: *Self, func: ast.Function) void {
            for (func.args) |arg| {
                switch (arg) {
                    .unnamed => |fa| {
                        switch (fa) {
                            .expr => |e| self.walkExpr(e),
                            .qualified_wildcard, .wildcard => {},
                        }
                    },
                    .named => |na| {
                        switch (na.arg) {
                            .expr => |e| self.walkExpr(e),
                            .qualified_wildcard, .wildcard => {},
                        }
                    },
                }
                if (self.stopped) return;
            }
            if (func.filter) |f| {
                self.walkExpr(f);
                if (self.stopped) return;
            }
            if (func.over) |over| {
                self.walkWindowSpec(over);
                if (self.stopped) return;
            }
            for (func.within_group) |obe| {
                self.walkExpr(&obe.expr);
                if (self.stopped) return;
            }
        }

        fn walkInsert(self: *Self, ins: Insert) void {
            switch (ins.source) {
                .values => |vals| {
                    for (vals.rows) |row| {
                        for (row) |*expr| {
                            self.walkExpr(expr);
                            if (self.stopped) return;
                        }
                    }
                },
                .select => |q| self.walkQuery(q),
                .assignments => |assigns| {
                    for (assigns) |a| {
                        self.walkExpr(&a.value);
                        if (self.stopped) return;
                    }
                },
                .default_values => {},
            }
            if (ins.on_duplicate_key_update) |odku| {
                for (odku) |a| {
                    self.walkExpr(&a.value);
                    if (self.stopped) return;
                }
            }
        }

        fn walkUpdate(self: *Self, upd: Update) void {
            for (upd.table) |twj| {
                self.walkTableWithJoins(twj);
                if (self.stopped) return;
            }
            for (upd.assignments) |a| {
                self.walkExpr(&a.value);
                if (self.stopped) return;
            }
            if (upd.from) |from| {
                for (from) |twj| {
                    self.walkTableWithJoins(twj);
                    if (self.stopped) return;
                }
            }
            if (upd.selection) |*expr| {
                self.walkExpr(expr);
                if (self.stopped) return;
            }
            for (upd.order_by) |obe| {
                self.walkExpr(&obe.expr);
                if (self.stopped) return;
            }
            if (upd.limit) |*expr| self.walkExpr(expr);
        }

        fn walkDelete(self: *Self, del: Delete) void {
            for (del.from) |twj| {
                self.walkTableWithJoins(twj);
                if (self.stopped) return;
            }
            if (del.using) |using| {
                for (using) |twj| {
                    self.walkTableWithJoins(twj);
                    if (self.stopped) return;
                }
            }
            if (del.selection) |*expr| {
                self.walkExpr(expr);
                if (self.stopped) return;
            }
            for (del.order_by) |obe| {
                self.walkExpr(&obe.expr);
                if (self.stopped) return;
            }
            if (del.limit) |*expr| self.walkExpr(expr);
        }

        fn walkCreateTable(self: *Self, ct: CreateTable) void {
            for (ct.columns) |col| {
                for (col.options) |opt| {
                    switch (opt.option) {
                        .default => |*expr| self.walkExpr(expr),
                        .check => |*expr| self.walkExpr(expr),
                        .on_update => |*expr| self.walkExpr(expr),
                        .generated => |g| {
                            if (g.generation_expr) |ge| self.walkExpr(ge);
                        },
                        else => {},
                    }
                    if (self.stopped) return;
                }
            }
            for (ct.constraints) |c| {
                switch (c) {
                    .check => |ch| self.walkExpr(&ch.expr),
                    else => {},
                }
                if (self.stopped) return;
            }
            if (ct.as_select) |q| self.walkQuery(q);
        }

        fn walkAlterTable(self: *Self, at: AlterTable) void {
            for (at.operations) |op| {
                switch (op) {
                    .add_column => |ac| {
                        for (ac.column_def.options) |opt| {
                            switch (opt.option) {
                                .default => |*expr| self.walkExpr(expr),
                                .check => |*expr| self.walkExpr(expr),
                                .on_update => |*expr| self.walkExpr(expr),
                                .generated => |g| {
                                    if (g.generation_expr) |ge| self.walkExpr(ge);
                                },
                                else => {},
                            }
                            if (self.stopped) return;
                        }
                    },
                    .alter_column => |ac| {
                        switch (ac.op) {
                            .set_default => |*expr| self.walkExpr(expr),
                            else => {},
                        }
                    },
                    else => {},
                }
                if (self.stopped) return;
            }
        }

        fn walkCreateIndex(self: *Self, ci: CreateIndex) void {
            for (ci.columns) |col| {
                self.walkExpr(&col.column);
                if (self.stopped) return;
            }
        }

        /// Helper to call a visitor method if it exists on V.
        fn callVisit(self: *Self, comptime method: []const u8, args: anytype) Action {
            if (@hasDecl(V, method)) {
                const func = @field(V, method);
                const action = @call(.auto, func, .{self.visitor} ++ args);
                if (action == .stop) self.stopped = true;
                return action;
            }
            return .@"continue";
        }
    };
}

// =========================================================================
// Tests
// =========================================================================

test "Walker counts expressions" {
    const root = @import("root.zig");

    const ExprCounter = struct {
        count: usize = 0,
        pub fn visitExpr(self: *@This(), _: *const Expr) Walker(@This()).Action {
            self.count += 1;
            return .@"continue";
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stmts = try root.parse(alloc, "SELECT a, b + c FROM t1 WHERE x = 1", .Generic, .{ .kind = .generic });
    var v = ExprCounter{};
    var w = Walker(ExprCounter).init(&v);
    w.walkStatements(stmts);
    // a, b, c, b+c, x, 1, x=1 = 7 exprs minimum (exact count depends on nesting)
    try std.testing.expect(v.count >= 7);
}

test "Walker counts tables" {
    const root = @import("root.zig");

    const TableCounter = struct {
        count: usize = 0,
        pub fn visitTableFactor(self: *@This(), tf: TableFactor) Walker(@This()).Action {
            if (tf == .table) self.count += 1;
            return .@"continue";
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stmts = try root.parse(alloc, "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id", .Generic, .{ .kind = .generic });
    var v = TableCounter{};
    var w = Walker(TableCounter).init(&v);
    w.walkStatements(stmts);
    try std.testing.expectEqual(@as(usize, 2), v.count);
}

test "Walker stop action halts traversal" {
    const root = @import("root.zig");

    const StopAfterTwo = struct {
        count: usize = 0,
        pub fn visitExpr(self: *@This(), _: *const Expr) Walker(@This()).Action {
            self.count += 1;
            if (self.count >= 2) return .stop;
            return .@"continue";
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stmts = try root.parse(alloc, "SELECT a, b, c, d, e FROM t1", .Generic, .{ .kind = .generic });
    var v = StopAfterTwo{};
    var w = Walker(StopAfterTwo).init(&v);
    w.walkStatements(stmts);
    try std.testing.expectEqual(@as(usize, 2), v.count);
}

test "Walker skip_children skips subtree" {
    const root = @import("root.zig");

    const SkipBinaryOp = struct {
        count: usize = 0,
        pub fn visitExpr(self: *@This(), expr: *const Expr) Walker(@This()).Action {
            self.count += 1;
            if (expr.* == .binary_op) return .skip_children;
            return .@"continue";
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // "a + b" is a binary_op; if we skip its children, we should not visit a and b individually
    const stmts = try root.parse(alloc, "SELECT a + b", .Generic, .{ .kind = .generic });
    var v = SkipBinaryOp{};
    var w = Walker(SkipBinaryOp).init(&v);
    w.walkStatements(stmts);
    // Should visit the binary_op (a+b) but not its children a, b
    // So count = 1 (just the binary_op)
    try std.testing.expectEqual(@as(usize, 1), v.count);
}

test "Walker visits subquery expressions" {
    const root = @import("root.zig");

    const TableCounter = struct {
        count: usize = 0,
        pub fn visitTableFactor(self: *@This(), tf: TableFactor) Walker(@This()).Action {
            if (tf == .table) self.count += 1;
            return .@"continue";
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stmts = try root.parse(alloc, "SELECT * FROM t1 WHERE id IN (SELECT id FROM t2)", .Generic, .{ .kind = .generic });
    var v = TableCounter{};
    var w = Walker(TableCounter).init(&v);
    w.walkStatements(stmts);
    try std.testing.expectEqual(@as(usize, 2), v.count);
}

test "Walker visits CTE tables" {
    const root = @import("root.zig");

    const TableCounter = struct {
        count: usize = 0,
        pub fn visitTableFactor(self: *@This(), tf: TableFactor) Walker(@This()).Action {
            if (tf == .table) self.count += 1;
            return .@"continue";
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stmts = try root.parse(alloc, "WITH cte AS (SELECT * FROM t1) SELECT * FROM cte JOIN t2 ON cte.id = t2.id", .Generic, .{ .kind = .generic });
    var v = TableCounter{};
    var w = Walker(TableCounter).init(&v);
    w.walkStatements(stmts);
    // t1 (inside CTE), cte (in main query), t2 (in main query) = 3
    try std.testing.expectEqual(@as(usize, 3), v.count);
}
