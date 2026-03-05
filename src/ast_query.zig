const std = @import("std");
const ast = @import("ast.zig");

pub const Ident = ast.Ident;
pub const ObjectName = ast.ObjectName;
pub const Expr = ast.Expr;
pub const OrderByExpr = ast.OrderByExpr;
pub const Value = ast.Value;

// ---------------------------------------------------------------------------
// Values clause (for INSERT VALUES or standalone VALUES)
// ---------------------------------------------------------------------------

/// A VALUES clause: `VALUES (row1...), (row2...), ...`
pub const Values = struct {
    /// Each inner slice is one row of values.
    rows: []const []const Expr,
};

// ---------------------------------------------------------------------------
// Set operations
// ---------------------------------------------------------------------------

/// Set operators combining two query expressions.
pub const SetOperator = enum {
    @"union",
    intersect,
    except,
    minus,
};

/// Quantifier on a set operator.
pub const SetQuantifier = enum {
    all,
    distinct,
    none,
};

/// A body expression: SELECT, set operation, or VALUES.
pub const SetExpr = union(enum) {
    /// A SELECT statement body.
    select: *const Select,
    /// A parenthesized query.
    query: *const Query,
    /// UNION / INTERSECT / EXCEPT.
    set_operation: struct {
        op: SetOperator,
        quantifier: SetQuantifier,
        left: *const SetExpr,
        right: *const SetExpr,
    },
    /// VALUES clause (may appear as body for INSERT ... VALUES or standalone).
    values: Values,
};

// ---------------------------------------------------------------------------
// WITH clause (CTEs)
// ---------------------------------------------------------------------------

/// CTE materialization hint.
pub const CteAsMaterialized = enum {
    materialized,
    not_materialized,
};

/// A single CTE: `alias [(cols)] AS [MATERIALIZED|NOT MATERIALIZED] (query)`.
pub const Cte = struct {
    /// The CTE alias.
    alias: TableAlias,
    /// The query body of the CTE.
    query: *const Query,
    /// Optional materialization hint.
    materialized: ?CteAsMaterialized,
    /// The closing paren token span (after the CTE query).
    closing_paren_token: ?@import("tokenizer.zig").TokenWithSpan = null,
};

/// A WITH clause introducing CTEs.
pub const With = struct {
    /// The WITH keyword token with source span.
    with_token: @import("tokenizer.zig").TokenWithSpan = .{ .token = .{ .EOF = {} }, .span = .empty },
    /// Whether the clause is `WITH RECURSIVE`.
    recursive: bool,
    /// The list of CTE definitions.
    cte_tables: []const Cte,
};

// ---------------------------------------------------------------------------
// LIMIT / OFFSET
// ---------------------------------------------------------------------------

/// A LIMIT clause with optional OFFSET.
pub const LimitClause = union(enum) {
    /// Standard: `LIMIT count [OFFSET offset]`
    limit_offset: struct {
        limit: ?Expr,
        offset: ?Expr,
    },
    /// MySQL comma syntax: `LIMIT offset, count`
    limit_comma: struct {
        offset: Expr,
        limit: Expr,
    },
};

// ---------------------------------------------------------------------------
// FETCH clause
// ---------------------------------------------------------------------------

/// A FETCH clause: `FETCH { FIRST | NEXT } [n [PERCENT]] { ROW | ROWS } { ONLY | WITH TIES }`.
pub const Fetch = struct {
    quantity: ?Expr,
    percent: bool,
    with_ties: bool,
};

// ---------------------------------------------------------------------------
// Top-level Query
// ---------------------------------------------------------------------------

/// The top-level query node, optionally with WITH and ORDER BY.
pub const Query = struct {
    /// Optional WITH clause (CTEs).
    with: ?With,
    /// The query body.
    body: *const SetExpr,
    /// ORDER BY clause.
    order_by: ?OrderBy,
    /// LIMIT / OFFSET / FETCH clause.
    limit_clause: ?LimitClause,
    /// FETCH clause.
    fetch: ?Fetch,
    /// FOR UPDATE / SHARE locks.
    locks: []const ast.LockClause,
};

// ---------------------------------------------------------------------------
// ORDER BY
// ---------------------------------------------------------------------------

/// An ORDER BY clause.
pub const OrderBy = struct {
    exprs: []const OrderByExpr,
};

// ---------------------------------------------------------------------------
// GROUP BY
// ---------------------------------------------------------------------------

/// A GROUP BY clause.
pub const GroupByExpr = union(enum) {
    /// GROUP BY ALL
    all,
    /// GROUP BY expr, expr, ...
    expressions: []const Expr,
};

// ---------------------------------------------------------------------------
// SELECT
// ---------------------------------------------------------------------------

/// DISTINCT modifier.
pub const Distinct = union(enum) {
    /// DISTINCT
    distinct,
    /// DISTINCT ON (expr, ...) (PostgreSQL -- kept for generic dialect)
    on: []const Expr,
};

/// MySQL SELECT modifiers (HIGH_PRIORITY, STRAIGHT_JOIN, etc.).
pub const SelectModifiers = struct {
    high_priority: bool = false,
    straight_join: bool = false,
    sql_small_result: bool = false,
    sql_big_result: bool = false,
    sql_buffer_result: bool = false,
    sql_no_cache: bool = false,
    sql_calc_found_rows: bool = false,
};

/// A SELECT item.
pub const SelectItem = union(enum) {
    /// An expression without an alias: `SELECT expr`.
    unnamed_expr: Expr,
    /// An expression with an alias: `SELECT expr AS alias`.
    expr_with_alias: struct { expr: Expr, alias: Ident },
    /// Qualified wildcard: `SELECT table.*`.
    qualified_wildcard: ObjectName,
    /// Unqualified wildcard: `SELECT *` with the span of the `*` token.
    wildcard: @import("span.zig").Span,
};

/// A restricted SELECT body (no ORDER BY or set ops).
pub const Select = struct {
    /// The SELECT keyword token with its source span.
    select_token: ?@import("tokenizer.zig").TokenWithSpan,
    /// DISTINCT or DISTINCT ON.
    distinct: ?Distinct,
    /// MySQL-specific modifiers after SELECT keyword.
    select_modifiers: ?SelectModifiers,
    /// Projection list.
    projection: []const SelectItem,
    /// FROM clause.
    from: []const TableWithJoins,
    /// WHERE clause.
    selection: ?Expr,
    /// GROUP BY clause.
    group_by: GroupByExpr,
    /// HAVING clause.
    having: ?Expr,
    /// WINDOW definitions.
    named_window: []const NamedWindowDefinition,
};

// ---------------------------------------------------------------------------
// Named window definitions (WINDOW clause)
// ---------------------------------------------------------------------------

/// A named window definition: `name AS (window_spec)`.
pub const NamedWindowDefinition = struct {
    name: Ident,
    spec: ast.WindowSpec,
};

// ---------------------------------------------------------------------------
// FROM clause
// ---------------------------------------------------------------------------

/// A table reference with optional joins.
pub const TableWithJoins = struct {
    /// The primary table or subquery.
    relation: TableFactor,
    /// Any joins attached to this table.
    joins: []const Join,
};

/// A table reference in the FROM clause.
pub const TableFactor = union(enum) {
    /// A named table, optionally with an alias.
    table: struct {
        name: ObjectName,
        alias: ?TableAlias,
        /// MySQL index hints (USE INDEX, FORCE INDEX, IGNORE INDEX).
        index_hints: []const TableIndexHint,
    },
    /// A derived table (subquery) with alias.
    derived: struct {
        lateral: bool,
        subquery: *const Query,
        alias: ?TableAlias,
    },
    /// A table-valued function, e.g. `generate_series(1, 10)`.
    table_function: struct {
        expr: Expr,
        alias: ?TableAlias,
    },
    /// `UNNEST(array)` table function.
    unnest: struct {
        array_exprs: []const Expr,
        alias: ?TableAlias,
        with_offset: bool,
        with_offset_alias: ?Ident,
    },
    /// A parenthesized FROM: `(table1, table2)`.
    nested_join: struct {
        table_with_joins: *const TableWithJoins,
        alias: ?TableAlias,
    },
};

/// A table alias, optionally with column aliases.
pub const TableAlias = struct {
    name: Ident,
    columns: []const Ident,
    /// Whether the AS keyword was present.
    explicit: bool = false,
};

/// MySQL index hint type.
pub const TableIndexHintType = enum {
    use_index,
    ignore_index,
    force_index,
};

/// A MySQL index hint: `USE INDEX (idx1, idx2)`.
pub const TableIndexHint = struct {
    hint_type: TableIndexHintType,
    index_names: []const Ident,
};

// ---------------------------------------------------------------------------
// JOIN
// ---------------------------------------------------------------------------

/// A join constraint.
pub const JoinConstraint = union(enum) {
    /// `ON expr`
    on: Expr,
    /// `USING (col1, col2, ...)`
    using: []const Ident,
    /// NATURAL join (no explicit constraint).
    natural,
    /// No constraint (CROSS JOIN).
    none,
};

/// The join operator type.
pub const JoinOperator = union(enum) {
    /// Bare JOIN (no INNER keyword)
    join: JoinConstraint,
    /// INNER JOIN
    inner: JoinConstraint,
    left_outer: JoinConstraint,
    right_outer: JoinConstraint,
    full_outer: JoinConstraint,
    cross_join,
    natural_inner,
    natural_left,
    natural_right,
    natural_full,
};

/// A single join.
pub const Join = struct {
    /// The joined table or subquery.
    relation: TableFactor,
    /// The type and constraint of the join.
    join_operator: JoinOperator,
};

test "SetExpr union tag" {
    const v: Values = .{ .rows = &.{} };
    const expr: SetExpr = .{ .values = v };
    try std.testing.expect(expr == .values);
}

test "Select struct can be constructed" {
    const s: Select = .{
        .select_token = null,
        .distinct = null,
        .select_modifiers = null,
        .projection = &.{},
        .from = &.{},
        .selection = null,
        .group_by = .{ .expressions = &.{} },
        .having = null,
        .named_window = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), s.projection.len);
}
