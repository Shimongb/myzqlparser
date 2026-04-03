const std = @import("std");

pub const BinaryOp = @import("ast_operator.zig").BinaryOp;
pub const UnaryOp = @import("ast_operator.zig").UnaryOp;
pub const DataType = @import("ast_types.zig").DataType;

// Forward declarations -- types defined in other AST modules that Expr/Statement need.
// These are used via pointer indirection to avoid circular dependency issues.
pub const Query = @import("ast_query.zig").Query;
pub const Select = @import("ast_query.zig").Select;
pub const Values = @import("ast_query.zig").Values;
pub const Insert = @import("ast_dml.zig").Insert;
pub const Update = @import("ast_dml.zig").Update;
pub const Delete = @import("ast_dml.zig").Delete;
pub const CreateTable = @import("ast_ddl.zig").CreateTable;
pub const AlterTable = @import("ast_ddl.zig").AlterTable;
pub const CreateIndex = @import("ast_ddl.zig").CreateIndex;
pub const CreateView = @import("ast_ddl.zig").CreateView;
pub const Drop = @import("ast_ddl.zig").Drop;

// ---------------------------------------------------------------------------
// Identifier
// ---------------------------------------------------------------------------

/// A SQL identifier, optionally quoted.
///
/// `value` holds the unquoted text. `quote_style` is the opening quote character
/// if any: `'`, `"`, `` ` `` (backtick), or `[` (MSSQL bracket style).
pub const Ident = struct {
    /// The identifier text, without quote characters.
    value: []const u8,
    /// Optional opening quote character.
    quote_style: ?u8,
    /// Source location of this identifier. Defaults to empty (unknown) when
    /// constructed without span information (e.g. in tests or synthesized nodes).
    span: @import("span.zig").Span = .empty,
};

// ---------------------------------------------------------------------------
// ObjectName
// ---------------------------------------------------------------------------

/// A (possibly multi-part) SQL object name, e.g. `db.schema.table`.
///
/// Each part is a single `Ident`. The dot separator is implied by the slice
/// order.
pub const ObjectName = struct {
    /// The identifier parts composing the name, in order.
    parts: []const Ident,
};

// ---------------------------------------------------------------------------
// Literal Value
// ---------------------------------------------------------------------------

/// Primitive SQL literal values.
///
/// String data is stored as slices into the original input (zero-copy where
/// possible). The allocator passed to the parser is used when unescaping
/// requires a new allocation.
pub const Value = union(enum) {
    /// Numeric literal, e.g. `42`, `3.14`, `1e10`.
    /// `is_long` is true when a trailing `L` suffix was present (MySQL BIGINT hint).
    number: struct { raw: []const u8, is_long: bool },
    /// Single-quoted string, e.g. `'hello'`.
    single_quoted_string: []const u8,
    /// Double-quoted string used as a string literal (MySQL mode), e.g. `"hello"`.
    double_quoted_string: []const u8,
    /// X'hex' hex literal.
    hex_string: []const u8,
    /// N'national string' (national character set literal).
    national_string: []const u8,
    /// Boolean literal `TRUE` or `FALSE`.
    boolean: bool,
    /// `NULL` literal.
    null,
    /// Prepared-statement placeholder, e.g. `?` or `$1`.
    placeholder: []const u8,
};

// ---------------------------------------------------------------------------
// DateTimeField (used in EXTRACT, INTERVAL)
// ---------------------------------------------------------------------------

/// Date/time fields for EXTRACT and INTERVAL expressions.
pub const DateTimeField = enum {
    year,
    month,
    week,
    day,
    hour,
    minute,
    second,
    microsecond,
    millisecond,
    quarter,
    epoch,
    custom,
};

// ---------------------------------------------------------------------------
// TrimWhereField
// ---------------------------------------------------------------------------

/// Which side to trim in a TRIM expression.
pub const TrimWhereField = enum {
    both,
    leading,
    trailing,
};

// ---------------------------------------------------------------------------
// CaseWhen
// ---------------------------------------------------------------------------

/// A single WHEN ... THEN ... clause in a CASE expression.
pub const CaseWhen = struct {
    /// The WHEN condition.
    condition: Expr,
    /// The THEN result.
    result: Expr,
};

// ---------------------------------------------------------------------------
// Function call
// ---------------------------------------------------------------------------

/// A SQL function argument.
pub const FunctionArg = union(enum) {
    /// An unnamed expression argument, e.g. `f(x)`.
    unnamed: FunctionArgExpr,
    /// A named argument, e.g. `f(x => 1)`.
    named: struct { name: Ident, arg: FunctionArgExpr },
};

/// The expression within a function argument (may be a wildcard).
pub const FunctionArgExpr = union(enum) {
    /// A normal expression argument.
    expr: *const Expr,
    /// Qualified wildcard, e.g. `f(t.*)`.
    qualified_wildcard: ObjectName,
    /// Unqualified wildcard `f(*)`.
    wildcard,
};

/// OVER clause for window functions.
pub const WindowSpec = struct {
    /// Optional window name reference.
    window_name: ?Ident,
    /// PARTITION BY expressions.
    partition_by: []const Expr,
    /// ORDER BY expressions.
    order_by: []const OrderByExpr,
    /// ROWS/RANGE/GROUPS frame.
    window_frame: ?WindowFrame,
};

/// Window frame kind.
pub const WindowFrameUnits = enum { rows, range, groups };

/// A window frame boundary.
pub const WindowFrameBound = union(enum) {
    /// CURRENT ROW
    current_row,
    /// UNBOUNDED PRECEDING
    unbounded_preceding,
    /// UNBOUNDED FOLLOWING
    unbounded_following,
    /// n PRECEDING
    preceding: *const Expr,
    /// n FOLLOWING
    following: *const Expr,
};

/// Window frame specification.
pub const WindowFrame = struct {
    units: WindowFrameUnits,
    start_bound: WindowFrameBound,
    end_bound: ?WindowFrameBound,
};

/// ORDER BY expression used in ORDER BY and window specs.
pub const OrderByExpr = struct {
    /// The expression to order by.
    expr: Expr,
    /// Optional ascending/descending override.
    asc: ?bool,
    /// NULLS FIRST / NULLS LAST.
    nulls_first: ?bool,
};

/// A SQL function call.
pub const Function = struct {
    /// Function name (may be multi-part, e.g. `schema.func`).
    name: ObjectName,
    /// Argument list.
    args: []const FunctionArg,
    /// FILTER (WHERE ...) clause.
    filter: ?*const Expr,
    /// Optional OVER clause (for window functions).
    over: ?WindowSpec,
    /// WITHIN GROUP (ORDER BY ...) for ordered-set aggregates.
    within_group: []const OrderByExpr,
    /// DISTINCT flag inside the argument list.
    distinct: bool,
};

// ---------------------------------------------------------------------------
// Expr
// ---------------------------------------------------------------------------

/// A SQL expression of any kind.
///
/// Recursive variants hold their children via `*const Expr` pointers to
/// enable stack-allocated and arena-allocated usage. All allocations should
/// use the arena allocator supplied to the parser.
pub const Expr = union(enum) {
    // --- Identifiers ---
    /// A simple identifier, e.g. column name or table alias.
    identifier: Ident,
    /// A multi-part identifier, e.g. `schema.table.column`.
    compound_identifier: []const Ident,

    // --- Literals ---
    /// A literal value (number, string, boolean, null) with its source span.
    value: struct { val: Value, span: @import("span.zig").Span = .empty },

    // --- Arithmetic / Logic ---
    /// Binary operation, e.g. `a + b`, `x AND y`.
    binary_op: struct {
        left: *const Expr,
        op: BinaryOp,
        right: *const Expr,
    },
    /// Unary operation, e.g. `NOT x`, `-1`.
    unary_op: struct {
        op: UnaryOp,
        expr: *const Expr,
    },

    // --- Comparison predicates ---
    /// `expr IS NULL`
    is_null: *const Expr,
    /// `expr IS NOT NULL`
    is_not_null: *const Expr,
    /// `expr IS TRUE`
    is_true: *const Expr,
    /// `expr IS NOT TRUE`
    is_not_true: *const Expr,
    /// `expr IS FALSE`
    is_false: *const Expr,
    /// `expr IS NOT FALSE`
    is_not_false: *const Expr,
    /// `expr IS DISTINCT FROM other`
    is_distinct_from: struct { left: *const Expr, right: *const Expr },
    /// `expr IS NOT DISTINCT FROM other`
    is_not_distinct_from: struct { left: *const Expr, right: *const Expr },

    // --- Range / membership ---
    /// `expr [NOT] BETWEEN low AND high`
    between: struct {
        expr: *const Expr,
        negated: bool,
        low: *const Expr,
        high: *const Expr,
    },
    /// `expr [NOT] IN (list...)`
    in_list: struct {
        expr: *const Expr,
        list: []const Expr,
        negated: bool,
    },
    /// `expr [NOT] IN (SELECT ...)`
    in_subquery: struct {
        expr: *const Expr,
        subquery: *const Query,
        negated: bool,
    },

    // --- Pattern matching ---
    /// `expr [NOT] LIKE pattern [ESCAPE char]`
    like: struct {
        negated: bool,
        expr: *const Expr,
        pattern: *const Expr,
        escape_char: ?u8,
    },
    /// `expr [NOT] ILIKE pattern [ESCAPE char]`
    ilike: struct {
        negated: bool,
        expr: *const Expr,
        pattern: *const Expr,
        escape_char: ?u8,
    },
    /// MySQL REGEXP/RLIKE: `expr [NOT] REGEXP pattern`
    rlike: struct {
        negated: bool,
        expr: *const Expr,
        pattern: *const Expr,
        regexp: bool,
    },

    // --- CASE ---
    /// `CASE [operand] WHEN ... THEN ... [ELSE ...] END`
    case: struct {
        operand: ?*const Expr,
        conditions: []const CaseWhen,
        else_result: ?*const Expr,
    },

    // --- Subqueries ---
    /// `[NOT] EXISTS (SELECT ...)`
    exists: struct { subquery: *const Query, negated: bool },
    /// Scalar subquery `(SELECT ...)`
    subquery: *const Query,

    // --- Type operations ---
    /// `CAST(expr AS type)`
    cast: struct {
        expr: *const Expr,
        data_type: DataType,
    },
    /// `expr AT TIME ZONE tz`
    at_time_zone: struct {
        timestamp: *const Expr,
        time_zone: *const Expr,
    },
    /// `EXTRACT(field FROM expr)` or `EXTRACT(field, expr)`
    extract: struct {
        field: DateTimeField,
        expr: *const Expr,
    },
    /// `CONVERT(expr USING charset)` or `CONVERT(expr, type)` (MySQL)
    convert: struct {
        expr: *const Expr,
        data_type: ?DataType,
        charset: ?ObjectName,
    },

    // --- String functions ---
    /// `SUBSTRING(expr [FROM start] [FOR len])`
    substring: struct {
        expr: *const Expr,
        from: ?*const Expr,
        @"for": ?*const Expr,
    },
    /// `TRIM([BOTH|LEADING|TRAILING] [what FROM] expr)`
    trim: struct {
        expr: *const Expr,
        trim_where: ?TrimWhereField,
        trim_what: ?*const Expr,
    },
    /// `POSITION(sub IN expr)`
    position: struct {
        expr: *const Expr,
        in: *const Expr,
    },

    // --- Aggregate extras ---
    /// `INTERVAL 'value' [unit [TO unit]]`
    interval: struct {
        value: *const Expr,
        leading_field: ?DateTimeField,
        last_field: ?DateTimeField,
    },

    // --- Grouping sets ---
    /// `GROUPING SETS ((a, b), (c))`
    grouping_sets: []const []const Expr,
    /// `ROLLUP (a, b, c)`
    rollup: []const []const Expr,
    /// `CUBE (a, b, c)`
    cube: []const []const Expr,

    // --- Row / tuple ---
    /// `(expr1, expr2)` tuple / ROW
    tuple: []const Expr,
    /// `ARRAY[expr1, expr2]`
    array: []const Expr,

    // --- Wildcard (in SELECT context) ---
    /// Unqualified `*` with its source span.
    wildcard: @import("span.zig").Span,
    /// Qualified wildcard, e.g. `t.*`
    qualified_wildcard: ObjectName,

    // --- Misc ---
    /// Parenthesized expression `(expr)`.
    nested: *const Expr,
    /// Function call, including aggregate and window functions.
    function: Function,
    /// `MATCH (cols) AGAINST (pattern)` (MySQL full-text search)
    match_against: struct {
        columns: []const ObjectName,
        match_value: Value,
        /// Search modifier string (IN NATURAL LANGUAGE MODE, etc.)
        modifier: ?[]const u8,
    },
    /// `expr COLLATE collation`
    collate: struct {
        expr: *const Expr,
        collation: ObjectName,
    },
};

// ---------------------------------------------------------------------------
// Assignment (for UPDATE SET and INSERT ... ON DUPLICATE KEY UPDATE)
// ---------------------------------------------------------------------------

/// An assignment expression: `column = value` used in UPDATE SET and
/// INSERT ... ON DUPLICATE KEY UPDATE.
pub const Assignment = struct {
    /// The target column identifier(s). Multi-part for `(a, b) = (1, 2)`.
    target: []const Ident,
    /// The value expression.
    value: Expr,
};

// ---------------------------------------------------------------------------
// SQL Options
// ---------------------------------------------------------------------------

/// A `key = value` SQL option pair, used in WITH clauses and table options.
pub const SqlOption = struct {
    name: ObjectName,
    value: Expr,
};

// ---------------------------------------------------------------------------
// Lock clause (SELECT FOR UPDATE / SHARE)
// ---------------------------------------------------------------------------

/// The type of lock in a FOR UPDATE/SHARE clause.
pub const LockType = enum { update, share };

/// A FOR UPDATE / FOR SHARE clause on a SELECT.
pub const LockClause = struct {
    lock_type: LockType,
    /// Optional table names to lock.
    of: []const ObjectName,
    /// SKIP LOCKED or NOWAIT.
    nonblock: ?enum { skip_locked, nowait },
};

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

/// A top-level SQL statement.
pub const Statement = union(enum) {
    // DML
    /// SELECT statement.
    select: *const Query,
    /// INSERT statement.
    insert: Insert,
    /// UPDATE statement.
    update: Update,
    /// DELETE statement.
    delete: Delete,

    // DDL
    /// CREATE TABLE statement.
    create_table: CreateTable,
    /// ALTER TABLE statement.
    alter_table: AlterTable,
    /// DROP statement (table, index, view).
    drop: Drop,
    /// CREATE INDEX statement.
    create_index: CreateIndex,
    /// CREATE VIEW statement.
    create_view: CreateView,
    /// DROP VIEW statement.
    drop_view: struct {
        if_exists: bool,
        name: ObjectName,
    },
    /// RENAME TABLE t1 TO t2 [, t3 TO t4 ...] (MySQL standalone statement).
    rename_table: []const RenameTablePair,

    // MySQL SHOW statements
    /// SHOW TABLES [FROM db]
    show_tables: struct { database: ?Ident },
    /// SHOW COLUMNS FROM table
    show_columns: struct { table: ObjectName },
    /// SHOW CREATE TABLE name
    show_create_table: ObjectName,
    /// SHOW DATABASES
    show_databases,
    /// SHOW CREATE VIEW name
    show_create_view: ObjectName,

    // MySQL LOCK/UNLOCK
    /// LOCK TABLES ...
    lock_tables: []const LockTable,
    /// UNLOCK TABLES
    unlock_tables,

    // Transaction control (minimal set)
    /// START TRANSACTION / BEGIN
    start_transaction,
    /// COMMIT
    commit,
    /// ROLLBACK
    rollback,

    // Generic utility
    /// SET variable = value
    set: struct { name: ObjectName, value: Expr },
    /// USE database
    use_db: Ident,
};

/// A single old->new table name pair in a RENAME TABLE statement.
pub const RenameTablePair = struct {
    /// The original table name.
    old_name: ObjectName,
    /// The new table name.
    new_name: ObjectName,
};

/// A single table entry in a LOCK TABLES statement.
pub const LockTable = struct {
    /// The table name.
    table: ObjectName,
    /// READ or WRITE.
    lock_type: enum { read, write, read_local, low_priority_write },
};

test "Ident creation" {
    const id: Ident = .{ .value = "users", .quote_style = null };
    try std.testing.expectEqualStrings("users", id.value);
    try std.testing.expect(id.quote_style == null);
}

test "Value variants" {
    const v1: Value = .{ .number = .{ .raw = "42", .is_long = false } };
    const v2: Value = .{ .single_quoted_string = "hello" };
    const v3: Value = .null;
    const v4: Value = .{ .boolean = true };
    _ = .{ v1, v2, v3, v4 };
}

test "ObjectName from parts" {
    const parts = [_]Ident{
        .{ .value = "schema", .quote_style = null },
        .{ .value = "table", .quote_style = null },
    };
    const name: ObjectName = .{ .parts = &parts };
    try std.testing.expectEqual(@as(usize, 2), name.parts.len);
}
