const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");
const keywords_mod = @import("keywords.zig");
const dialect_mod = @import("dialect.zig");
const ast = @import("ast.zig");
const ast_operator = @import("ast_operator.zig");
const ast_types = @import("ast_types.zig");
const ast_query = @import("ast_query.zig");
const dml_ddl = @import("parser_dml_ddl.zig");

pub const Token = tokenizer_mod.Token;
pub const TokenWithSpan = tokenizer_mod.TokenWithSpan;
pub const Word = tokenizer_mod.Word;
pub const Keyword = keywords_mod.Keyword;
const Location = @import("span.zig").Location;
pub const Dialect = dialect_mod.Dialect;
pub const Ident = ast.Ident;
pub const ObjectName = ast.ObjectName;
pub const Value = ast.Value;
pub const Expr = ast.Expr;
pub const Statement = ast.Statement;
pub const BinaryOp = ast_operator.BinaryOp;
pub const UnaryOp = ast_operator.UnaryOp;
pub const DataType = ast_types.DataType;
pub const ExactNumberInfo = ast_types.ExactNumberInfo;
pub const CharacterLength = ast_types.CharacterLength;
pub const Query = ast_query.Query;
pub const Select = ast_query.Select;
pub const SelectItem = ast_query.SelectItem;
pub const SetExpr = ast_query.SetExpr;
pub const SetOperator = ast_query.SetOperator;
pub const SetQuantifier = ast_query.SetQuantifier;
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
pub const LimitClause = ast_query.LimitClause;
pub const TableAlias = ast_query.TableAlias;
pub const Distinct = ast_query.Distinct;

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

pub const ParseError = error{
    OutOfMemory,
    ParseFailed,
    RecursionLimit,
};

// ---------------------------------------------------------------------------
// Operator precedence table (higher = tighter binding)
// ---------------------------------------------------------------------------
const Prec = struct {
    const unknown: u8 = 0;
    const or_: u8 = 5;
    const and_: u8 = 10;
    const unary_not: u8 = 15;
    const is: u8 = 17;
    const like: u8 = 19;
    const between: u8 = 20;
    const eq: u8 = 20;
    const pipe: u8 = 21;
    const caret: u8 = 22;
    const ampersand: u8 = 23;
    const xor: u8 = 24;
    const plus_minus: u8 = 30;
    const mul_div_mod: u8 = 40;
    const double_colon: u8 = 50;
    const period: u8 = 100;
};

// ---------------------------------------------------------------------------
// Parser struct
// ---------------------------------------------------------------------------

/// The maximum recursion depth allowed when parsing expressions.
const MAX_RECURSION_DEPTH: u32 = 50;

pub const Parser = struct {
    /// All tokens (whitespace already stripped by caller).
    tokens: []const TokenWithSpan,
    /// Index of the next token to consume.
    index: usize,
    /// Allocator for AST nodes (typically an arena).
    allocator: std.mem.Allocator,
    /// Dialect configuration.
    dialect: Dialect,
    /// Current recursion depth for expression parsing.
    recursion_depth: u32,
    /// Error detail: human-readable message set when parsing fails.
    error_message: []const u8 = "",
    /// Error detail: source location where the error occurred.
    error_location: Location = Location.empty,

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// Create a parser from already-tokenized, whitespace-stripped input.
    pub fn init(
        allocator: std.mem.Allocator,
        dialect: Dialect,
        tokens: []const TokenWithSpan,
    ) Parser {
        return .{
            .tokens = tokens,
            .index = 0,
            .allocator = allocator,
            .dialect = dialect,
            .recursion_depth = 0,
        };
    }

    // -----------------------------------------------------------------------
    // Top-level entry points
    // -----------------------------------------------------------------------

    /// Parse all statements separated by semicolons.
    pub fn parseStatements(self: *Parser) ParseError![]Statement {
        var stmts: std.ArrayList(Statement) = .empty;
        // Pre-size for a small batch of statements; grows as needed.
        try stmts.ensureTotalCapacity(self.allocator, 4);
        while (true) {
            while (self.consumeToken(.SemiColon)) {}
            if (self.peekTokenIs(.EOF)) break;
            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);
        }
        return stmts.toOwnedSlice(self.allocator);
    }

    /// Parse a single top-level statement.
    pub fn parseStatement(self: *Parser) ParseError!Statement {
        const tok = self.nextToken();
        switch (tok.token) {
            .Word => |w| switch (w.keyword) {
                .SELECT, .VALUES => {
                    self.prevToken();
                    const q = try self.parseQuery();
                    const owned = try self.allocator.create(Query);
                    owned.* = q;
                    return Statement{ .select = owned };
                },
                .WITH => {
                    // Parse the WITH clause, then dispatch based on the next keyword.
                    const with = try self.parseWith(tok);
                    if (self.peekIsKeyword(.DELETE)) {
                        const del_tok = self.nextToken();
                        var stmt = try dml_ddl.parseDelete(self, del_tok);
                        stmt.delete.with = with;
                        return stmt;
                    } else if (self.peekIsKeyword(.UPDATE)) {
                        const upd_tok = self.nextToken();
                        var stmt = try dml_ddl.parseUpdate(self, upd_tok);
                        stmt.update.with = with;
                        return stmt;
                    } else {
                        // SELECT or VALUES — parse as a full query with the CTE attached.
                        const body = try self.parseSetExpr();
                        const body_ptr = try self.allocator.create(SetExpr);
                        body_ptr.* = body;
                        var order_by: ?OrderBy = null;
                        if (self.parseKeywords(&.{ .ORDER, .BY })) {
                            order_by = try self.parseOrderBy();
                        }
                        var limit_clause: ?LimitClause = null;
                        if (self.parseKeyword(.LIMIT)) {
                            limit_clause = try self.parseLimitClause();
                        }
                        const q = Query{
                            .with = with,
                            .body = body_ptr,
                            .order_by = order_by,
                            .limit_clause = limit_clause,
                            .fetch = null,
                            .locks = &.{},
                        };
                        const owned = try self.allocator.create(Query);
                        owned.* = q;
                        return Statement{ .select = owned };
                    }
                },
                .INSERT => return try dml_ddl.parseInsert(self, tok),
                .REPLACE => return try dml_ddl.parseReplace(self, tok),
                .UPDATE => return try dml_ddl.parseUpdate(self, tok),
                .DELETE => return try dml_ddl.parseDelete(self, tok),
                .CREATE => return try dml_ddl.parseCreate(self),
                .ALTER => {
                    try self.expectKeyword(.TABLE);
                    return try dml_ddl.parseAlterTable(self);
                },
                .DROP => return try dml_ddl.parseDrop(self),
                .SHOW => return try self.parseShow(),
                .USE => return try self.parseUse(),
                .START => {
                    _ = self.parseKeyword(.TRANSACTION);
                    return Statement.start_transaction;
                },
                .BEGIN => return Statement.start_transaction,
                .COMMIT => return Statement.commit,
                .ROLLBACK => return Statement.rollback,
                .LOCK => {
                    try self.expectKeyword(.TABLES);
                    return try self.parseLockTables();
                },
                .UNLOCK => {
                    try self.expectKeyword(.TABLES);
                    return Statement.unlock_tables;
                },
                .SET => return try self.parseSet(),
                else => return self.expected("a SQL statement", tok),
            },
            else => return self.expected("a SQL statement", tok),
        }
    }

    // -----------------------------------------------------------------------
    // SHOW statements (MySQL)
    // -----------------------------------------------------------------------

    fn parseShow(self: *Parser) ParseError!Statement {
        if (self.parseKeyword(.TABLES)) {
            var db: ?Ident = null;
            if (self.parseKeyword(.FROM) or self.parseKeyword(.IN)) {
                db = try self.parseIdent();
            }
            return Statement{ .show_tables = .{ .database = db } };
        }
        if (self.parseKeyword(.DATABASES)) {
            return Statement.show_databases;
        }
        if (self.parseKeyword(.COLUMNS)) {
            _ = self.parseKeyword(.FROM);
            const tbl = try self.parseObjectName();
            return Statement{ .show_columns = .{ .table = tbl } };
        }
        if (self.parseKeyword(.CREATE)) {
            if (self.parseKeyword(.TABLE)) {
                const name = try self.parseObjectName();
                return Statement{ .show_create_table = name };
            }
            if (self.parseKeyword(.VIEW)) {
                const name = try self.parseObjectName();
                return Statement{ .show_create_view = name };
            }
            return self.expected("TABLE or VIEW after SHOW CREATE", self.peekToken());
        }
        return self.expected("TABLES, COLUMNS, DATABASES, or CREATE after SHOW", self.peekToken());
    }

    // -----------------------------------------------------------------------
    // USE statement
    // -----------------------------------------------------------------------

    fn parseUse(self: *Parser) ParseError!Statement {
        const ident = try self.parseIdent();
        return Statement{ .use_db = ident };
    }

    // -----------------------------------------------------------------------
    // SET statement
    // -----------------------------------------------------------------------

    fn parseSet(self: *Parser) ParseError!Statement {
        const name = try self.parseObjectName();
        try self.expectToken(.Eq);
        const value = try self.parseExpr();
        return Statement{ .set = .{ .name = name, .value = value } };
    }

    // -----------------------------------------------------------------------
    // LOCK TABLES statement
    // -----------------------------------------------------------------------

    fn parseLockTables(self: *Parser) ParseError!Statement {
        const tables = try self.parseCommaSeparated(ast.LockTable, parseLockTableFn);
        return Statement{ .lock_tables = tables };
    }

    fn parseLockTableFn(self: *Parser) ParseError!ast.LockTable {
        const table = try self.parseObjectName();
        const lock_type = try self.parseLockTableType();
        return ast.LockTable{ .table = table, .lock_type = lock_type };
    }

    fn parseLockTableType(self: *Parser) ParseError!@TypeOf(@as(ast.LockTable, undefined).lock_type) {
        if (self.parseKeyword(.READ)) {
            if (self.parseKeyword(.LOCAL)) return .read_local;
            return .read;
        }
        if (self.parseKeyword(.WRITE)) return .write;
        if (self.parseKeyword(.LOW_PRIORITY)) {
            try self.expectKeyword(.WRITE);
            return .low_priority_write;
        }
        return self.expected("READ, WRITE, or LOW_PRIORITY", self.peekToken());
    }

    // -----------------------------------------------------------------------
    // Query parsing  (WITH / SELECT / UNION / ORDER BY / LIMIT)
    // -----------------------------------------------------------------------

    /// Parse a complete query: [WITH ...] body [ORDER BY] [LIMIT]
    pub fn parseQuery(self: *Parser) ParseError!Query {
        if (self.recursion_depth >= MAX_RECURSION_DEPTH) {
            self.error_message = "Maximum recursion depth exceeded";
            if (self.index > 0 and self.index <= self.tokens.len) {
                self.error_location = self.tokens[self.index - 1].span.start;
            }
            return error.RecursionLimit;
        }
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        var with: ?With = null;
        if (self.peekIsKeyword(.WITH)) {
            const with_tok = self.nextToken();
            with = try self.parseWith(with_tok);
        }

        const body = try self.parseSetExpr();
        const body_ptr = try self.allocator.create(SetExpr);
        body_ptr.* = body;

        var order_by: ?OrderBy = null;
        if (self.parseKeywords(&.{ .ORDER, .BY })) {
            order_by = try self.parseOrderBy();
        }

        var limit_clause: ?LimitClause = null;
        if (self.parseKeyword(.LIMIT)) {
            limit_clause = try self.parseLimitClause();
        }

        return Query{
            .with = with,
            .body = body_ptr,
            .order_by = order_by,
            .limit_clause = limit_clause,
            .fetch = null,
            .locks = &.{},
        };
    }

    // -----------------------------------------------------------------------
    // WITH clause
    // -----------------------------------------------------------------------

    fn parseWith(self: *Parser, with_tok: @import("tokenizer.zig").TokenWithSpan) ParseError!With {
        const recursive = self.parseKeyword(.RECURSIVE);
        const ctes = try self.parseCommaSeparated(Cte, parseCte);
        return With{ .with_token = with_tok, .recursive = recursive, .cte_tables = ctes };
    }

    fn parseCte(self: *Parser) ParseError!Cte {
        const alias_ident = try self.parseIdent();
        var col_names: []const Ident = &.{};
        if (self.consumeToken(.LParen)) {
            col_names = try self.parseCommaSeparated(Ident, parseIdentFn);
            try self.expectToken(.RParen);
        }
        try self.expectKeyword(.AS);
        try self.expectToken(.LParen);
        const query = try self.parseQuery();
        const closing_tok = self.nextToken(); // consume ')'
        const qptr = try self.allocator.create(Query);
        qptr.* = query;
        return Cte{
            .alias = TableAlias{ .name = alias_ident, .columns = col_names },
            .query = qptr,
            .materialized = null,
            .closing_paren_token = closing_tok,
        };
    }

    // -----------------------------------------------------------------------
    // Set expressions (UNION / INTERSECT / EXCEPT)
    // -----------------------------------------------------------------------

    fn parseSetExpr(self: *Parser) ParseError!SetExpr {
        var left = try self.parseSetExprBase();

        while (true) {
            var op: ?SetOperator = null;
            var quantifier: SetQuantifier = .none;

            if (self.parseKeyword(.UNION)) {
                if (self.parseKeyword(.ALL)) {
                    quantifier = .all;
                } else if (self.parseKeyword(.DISTINCT)) {
                    quantifier = .distinct;
                }
                op = .@"union";
            } else if (self.parseKeyword(.INTERSECT)) {
                if (self.parseKeyword(.ALL)) {
                    quantifier = .all;
                }
                op = .intersect;
            } else if (self.parseKeyword(.EXCEPT)) {
                if (self.parseKeyword(.ALL)) {
                    quantifier = .all;
                }
                op = .except;
            } else {
                break;
            }

            const right = try self.parseSetExprBase();
            const lptr = try self.allocator.create(SetExpr);
            lptr.* = left;
            const rptr = try self.allocator.create(SetExpr);
            rptr.* = right;
            left = SetExpr{ .set_operation = .{
                .op = op.?,
                .quantifier = quantifier,
                .left = lptr,
                .right = rptr,
            } };
        }

        return left;
    }

    fn parseSetExprBase(self: *Parser) ParseError!SetExpr {
        // VALUES
        if (self.parseKeyword(.VALUES)) {
            const values = try self.parseValues();
            return SetExpr{ .values = values };
        }
        // Parenthesized subquery
        if (self.peekTokenIs(.LParen)) {
            // Peek inside for SELECT/WITH/VALUES
            const saved = self.index;
            _ = self.nextToken(); // consume LParen
            if (self.peekIsKeyword(.SELECT) or self.peekIsKeyword(.WITH) or self.peekIsKeyword(.VALUES)) {
                const q = try self.parseQuery();
                try self.expectToken(.RParen);
                const qptr = try self.allocator.create(Query);
                qptr.* = q;
                return SetExpr{ .query = qptr };
            }
            // Not a subquery - restore and fall through to SELECT
            self.index = saved;
        }
        // SELECT
        const select_tok = self.nextToken();
        const select_kw = switch (select_tok.token) {
            .Word => |w| w,
            else => return self.expected("SELECT", select_tok),
        };
        if (select_kw.keyword != .SELECT) return self.expected("SELECT", select_tok);
        const select = try self.parseSelectBody(select_tok);
        return SetExpr{ .select = select };
    }

    // -----------------------------------------------------------------------
    // VALUES
    // -----------------------------------------------------------------------

    fn parseValues(self: *Parser) ParseError!Values {
        var rows: std.ArrayList([]const Expr) = .empty;
        const first_row = try self.parseValueRow();
        try rows.append(self.allocator, first_row);
        while (self.consumeToken(.Comma)) {
            const row = try self.parseValueRow();
            try rows.append(self.allocator, row);
        }
        return Values{ .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn parseValueRow(self: *Parser) ParseError![]const Expr {
        try self.expectToken(.LParen);
        const exprs = try self.parseCommaSeparated(Expr, parseExprFn);
        try self.expectToken(.RParen);
        return exprs;
    }

    // -----------------------------------------------------------------------
    // SELECT body
    // -----------------------------------------------------------------------

    fn parseSelectBody(self: *Parser, select_tok: TokenWithSpan) ParseError!*Select {
        const distinct = self.parseSelectDistinct();

        const projection = try self.parseCommaSeparated(SelectItem, parseSelectItem);

        var from: []const TableWithJoins = &.{};
        if (self.parseKeyword(.FROM)) {
            from = try self.parseTableWithJoinsList();
        }

        var selection: ?Expr = null;
        if (self.parseKeyword(.WHERE)) {
            selection = try self.parseExpr();
        }

        var group_by: GroupByExpr = GroupByExpr{ .expressions = &.{} };
        if (self.parseKeywords(&.{ .GROUP, .BY })) {
            group_by = try self.parseGroupBy();
        }

        var having: ?Expr = null;
        if (self.parseKeyword(.HAVING)) {
            having = try self.parseExpr();
        }

        const select = try self.allocator.create(Select);
        select.* = Select{
            .select_token = select_tok,
            .distinct = distinct,
            .select_modifiers = null,
            .projection = projection,
            .from = from,
            .selection = selection,
            .group_by = group_by,
            .having = having,
            .named_window = &.{},
        };
        return select;
    }

    fn parseSelectDistinct(self: *Parser) ?Distinct {
        if (self.parseKeyword(.DISTINCT)) {
            return Distinct.distinct;
        }
        _ = self.parseKeyword(.ALL);
        return null;
    }

    // -----------------------------------------------------------------------
    // SELECT items
    // -----------------------------------------------------------------------

    fn parseSelectItem(self: *Parser) ParseError!SelectItem {
        // Wildcard: *
        if (self.peekTokenIs(.Mul)) {
            const mul_tok = self.nextToken();
            return SelectItem{ .wildcard = mul_tok.span };
        }

        const expr = try self.parseExpr();

        switch (expr) {
            .qualified_wildcard => |name| return SelectItem{ .qualified_wildcard = name },
            .wildcard => |wspan| return SelectItem{ .wildcard = wspan },
            // A bare unquoted reserved keyword is not a valid SELECT item.
            // e.g. "SELECT FROM;" should error, not treat FROM as a column name.
            .identifier => |ident| {
                if (ident.quote_style == null) {
                    const reserved = &[_][]const u8{
                        "FROM",  "WHERE", "GROUP",     "HAVING", "ORDER",
                        "LIMIT", "UNION", "INTERSECT", "EXCEPT",
                    };
                    for (reserved) |kw| {
                        if (std.ascii.eqlIgnoreCase(ident.value, kw)) {
                            return self.expected("an expression in SELECT list", self.peekToken());
                        }
                    }
                }
            },
            else => {},
        }

        const alias: ?Ident = try self.parseOptionalAlias();
        if (alias) |a| {
            return SelectItem{ .expr_with_alias = .{ .expr = expr, .alias = a } };
        }
        return SelectItem{ .unnamed_expr = expr };
    }

    fn parseOptionalAlias(self: *Parser) ParseError!?Ident {
        const explicit = self.parseKeyword(.AS);
        if (explicit) {
            return try self.parseIdent();
        }
        // Implicit alias: unquoted identifier that is not a reserved keyword
        const peek = self.peekToken();
        switch (peek.token) {
            .Word => |w| {
                switch (w.keyword) {
                    .NoKeyword => {
                        const tok = self.nextToken();
                        return Ident{ .value = w.value, .quote_style = w.quote_style, .span = tok.span };
                    },
                    // Reserved - cannot be implicit alias in this position
                    .FROM, .WHERE, .GROUP, .HAVING, .ORDER, .LIMIT, .OFFSET, .UNION, .INTERSECT, .EXCEPT, .ON, .JOIN, .INNER, .LEFT, .RIGHT, .FULL, .CROSS, .NATURAL, .AND, .OR, .NOT, .IS, .IN, .BETWEEN, .LIKE, .ILIKE, .THEN, .WHEN, .ELSE, .END, .AS, .INTO, .SET, .WINDOW, .FETCH, .FOR => {},
                    // Quoted identifiers are always valid
                    else => if (w.quote_style != null) {
                        const tok = self.nextToken();
                        return Ident{ .value = w.value, .quote_style = w.quote_style, .span = tok.span };
                    },
                }
            },
            else => {},
        }
        return null;
    }

    /// Parse an optional table alias, tracking whether AS was explicit.
    fn parseOptionalTableAlias(self: *Parser) ParseError!?TableAlias {
        const explicit = self.parseKeyword(.AS);
        if (explicit) {
            const ident = try self.parseIdent();
            return TableAlias{ .name = ident, .columns = &.{}, .explicit = true };
        }
        // Implicit alias: unquoted identifier that is not a reserved keyword
        const peek = self.peekToken();
        switch (peek.token) {
            .Word => |w| {
                switch (w.keyword) {
                    .NoKeyword => {
                        const tok = self.nextToken();
                        return TableAlias{ .name = Ident{ .value = w.value, .quote_style = w.quote_style, .span = tok.span }, .columns = &.{}, .explicit = false };
                    },
                    .FROM, .WHERE, .GROUP, .HAVING, .ORDER, .LIMIT, .OFFSET, .UNION, .INTERSECT, .EXCEPT, .ON, .JOIN, .INNER, .LEFT, .RIGHT, .FULL, .CROSS, .NATURAL, .AND, .OR, .NOT, .IS, .IN, .BETWEEN, .LIKE, .ILIKE, .THEN, .WHEN, .ELSE, .END, .AS, .INTO, .SET, .WINDOW, .FETCH, .FOR => {},
                    else => if (w.quote_style != null) {
                        const tok = self.nextToken();
                        return TableAlias{ .name = Ident{ .value = w.value, .quote_style = w.quote_style, .span = tok.span }, .columns = &.{}, .explicit = false };
                    },
                }
            },
            else => {},
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // FROM / JOIN
    // -----------------------------------------------------------------------

    pub fn parseTableWithJoinsList(self: *Parser) ParseError![]const TableWithJoins {
        var list: std.ArrayList(TableWithJoins) = .empty;
        const first = try self.parseTableWithJoins();
        try list.append(self.allocator, first);
        while (self.consumeToken(.Comma)) {
            const twj = try self.parseTableWithJoins();
            try list.append(self.allocator, twj);
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn parseTableWithJoins(self: *Parser) ParseError!TableWithJoins {
        const relation = try self.parseTableFactor();
        var joins: std.ArrayList(Join) = .empty;
        while (true) {
            const join = try self.parseJoin() orelse break;
            try joins.append(self.allocator, join);
        }
        return TableWithJoins{
            .relation = relation,
            .joins = try joins.toOwnedSlice(self.allocator),
        };
    }

    fn parseTableFactor(self: *Parser) ParseError!TableFactor {
        // Subquery: (SELECT ...)
        if (self.consumeToken(.LParen)) {
            if (self.peekIsKeyword(.SELECT) or self.peekIsKeyword(.WITH) or self.peekIsKeyword(.VALUES)) {
                const q = try self.parseQuery();
                try self.expectToken(.RParen);
                const alias = try self.parseOptionalTableAlias();
                const qptr = try self.allocator.create(Query);
                qptr.* = q;
                return TableFactor{ .derived = .{
                    .lateral = false,
                    .subquery = qptr,
                    .alias = alias,
                } };
            }
            // Parenthesized join - parse as nested join
            const inner = try self.parseTableWithJoins();
            try self.expectToken(.RParen);
            const alias = try self.parseOptionalTableAlias();
            const twj_ptr = try self.allocator.create(TableWithJoins);
            twj_ptr.* = inner;
            return TableFactor{ .nested_join = .{
                .table_with_joins = twj_ptr,
                .alias = alias,
            } };
        }

        // LATERAL
        if (self.parseKeyword(.LATERAL)) {
            try self.expectToken(.LParen);
            const q = try self.parseQuery();
            try self.expectToken(.RParen);
            const alias = try self.parseOptionalTableAlias();
            const qptr = try self.allocator.create(Query);
            qptr.* = q;
            return TableFactor{ .derived = .{
                .lateral = true,
                .subquery = qptr,
                .alias = alias,
            } };
        }

        // Table name
        const name = try self.parseObjectName();
        const table_alias: ?TableAlias = try self.parseOptionalTableAlias();

        // MySQL index hints: USE/FORCE/IGNORE INDEX (...)
        var index_hints: []const ast_query.TableIndexHint = &.{};
        if (self.dialect.supportsTableHints()) {
            index_hints = try self.parseIndexHints();
        }

        return TableFactor{ .table = .{
            .name = name,
            .alias = table_alias,
            .index_hints = index_hints,
        } };
    }

    fn parseIndexHints(self: *Parser) ParseError![]const ast_query.TableIndexHint {
        var hints: std.ArrayList(ast_query.TableIndexHint) = .empty;
        while (true) {
            const hint_type: ast_query.TableIndexHintType =
                if (self.parseKeyword(.USE)) .use_index else if (self.parseKeyword(.FORCE)) .force_index else if (self.parseKeyword(.IGNORE)) .ignore_index else break;
            // INDEX or KEY
            _ = self.parseKeyword(.INDEX);
            _ = self.parseKeyword(.KEY);
            try self.expectToken(.LParen);
            var index_names: std.ArrayList(Ident) = .empty;
            while (!self.peekTokenIs(.RParen) and !self.peekTokenIs(.EOF)) {
                const idx_name = try self.parseIdent();
                try index_names.append(self.allocator, idx_name);
                if (!self.consumeToken(.Comma)) break;
            }
            try self.expectToken(.RParen);
            try hints.append(self.allocator, ast_query.TableIndexHint{
                .hint_type = hint_type,
                .index_names = try index_names.toOwnedSlice(self.allocator),
            });
        }
        return hints.toOwnedSlice(self.allocator);
    }

    fn parseJoin(self: *Parser) ParseError!?Join {
        const saved_idx = self.index;
        const natural = self.parseKeyword(.NATURAL);

        // Determine join type and constraint
        if (self.parseKeyword(.INNER) and self.parseKeyword(.JOIN)) {
            const relation = try self.parseTableFactor();
            const constraint = if (natural) JoinConstraint.natural else try self.parseJoinConstraint();
            return Join{
                .relation = relation,
                .join_operator = if (natural) JoinOperator.natural_inner else JoinOperator{ .inner = constraint },
            };
        }
        if (self.parseKeyword(.JOIN)) {
            const relation = try self.parseTableFactor();
            const constraint = if (natural) JoinConstraint.natural else try self.parseJoinConstraint();
            return Join{
                .relation = relation,
                .join_operator = if (natural) JoinOperator.natural_inner else JoinOperator{ .join = constraint },
            };
        }
        if (self.parseKeyword(.LEFT)) {
            _ = self.parseKeyword(.OUTER);
            if (!self.parseKeyword(.JOIN)) {
                self.index = saved_idx;
                return null;
            }
            const relation = try self.parseTableFactor();
            const constraint = if (natural) JoinConstraint.natural else try self.parseJoinConstraint();
            return Join{
                .relation = relation,
                .join_operator = if (natural) JoinOperator.natural_left else JoinOperator{ .left_outer = constraint },
            };
        }
        if (self.parseKeyword(.RIGHT)) {
            _ = self.parseKeyword(.OUTER);
            if (!self.parseKeyword(.JOIN)) {
                self.index = saved_idx;
                return null;
            }
            const relation = try self.parseTableFactor();
            const constraint = if (natural) JoinConstraint.natural else try self.parseJoinConstraint();
            return Join{
                .relation = relation,
                .join_operator = if (natural) JoinOperator.natural_right else JoinOperator{ .right_outer = constraint },
            };
        }
        if (self.parseKeyword(.FULL)) {
            _ = self.parseKeyword(.OUTER);
            if (!self.parseKeyword(.JOIN)) {
                self.index = saved_idx;
                return null;
            }
            const relation = try self.parseTableFactor();
            const constraint = if (natural) JoinConstraint.natural else try self.parseJoinConstraint();
            return Join{
                .relation = relation,
                .join_operator = if (natural) JoinOperator.natural_full else JoinOperator{ .full_outer = constraint },
            };
        }
        if (self.parseKeyword(.CROSS)) {
            if (!self.parseKeyword(.JOIN)) {
                self.index = saved_idx;
                return null;
            }
            const relation = try self.parseTableFactor();
            return Join{
                .relation = relation,
                .join_operator = JoinOperator.cross_join,
            };
        }

        if (natural) self.index = saved_idx;
        return null;
    }

    fn parseJoinConstraint(self: *Parser) ParseError!JoinConstraint {
        if (self.parseKeyword(.ON)) {
            const expr = try self.parseExpr();
            return JoinConstraint{ .on = expr };
        }
        if (self.parseKeyword(.USING)) {
            try self.expectToken(.LParen);
            const cols = try self.parseCommaSeparated(Ident, parseIdentFn);
            try self.expectToken(.RParen);
            return JoinConstraint{ .using = cols };
        }
        return JoinConstraint.none;
    }

    // -----------------------------------------------------------------------
    // GROUP BY
    // -----------------------------------------------------------------------

    fn parseGroupBy(self: *Parser) ParseError!GroupByExpr {
        if (self.parseKeyword(.ALL)) {
            return GroupByExpr.all;
        }
        const exprs = try self.parseCommaSeparated(Expr, parseExprFn);
        return GroupByExpr{ .expressions = exprs };
    }

    // -----------------------------------------------------------------------
    // ORDER BY
    // -----------------------------------------------------------------------

    fn parseOrderBy(self: *Parser) ParseError!OrderBy {
        const exprs = try self.parseCommaSeparated(ast.OrderByExpr, parseOrderByExprFn);
        return OrderBy{ .exprs = exprs };
    }

    pub fn parseOrderByExprFn(self: *Parser) ParseError!ast.OrderByExpr {
        const expr = try self.parseExpr();
        var asc: ?bool = null;
        if (self.parseKeyword(.ASC)) {
            asc = true;
        } else if (self.parseKeyword(.DESC)) {
            asc = false;
        }
        var nulls_first: ?bool = null;
        if (self.parseKeyword(.NULLS)) {
            if (self.parseKeyword(.FIRST)) {
                nulls_first = true;
            } else if (self.parseKeyword(.LAST)) {
                nulls_first = false;
            }
        }
        return ast.OrderByExpr{ .expr = expr, .asc = asc, .nulls_first = nulls_first };
    }

    // -----------------------------------------------------------------------
    // LIMIT / OFFSET clause
    // -----------------------------------------------------------------------

    fn parseLimitClause(self: *Parser) ParseError!LimitClause {
        // LIMIT ALL
        if (self.peekIsKeyword(.ALL)) {
            _ = self.nextToken();
            var offset: ?Expr = null;
            if (self.parseKeyword(.OFFSET)) {
                offset = try self.parseExpr();
            }
            return LimitClause{ .limit_offset = .{ .limit = null, .offset = offset } };
        }

        const first_expr = try self.parseExpr();

        // MySQL-style LIMIT offset, count
        if (self.consumeToken(.Comma)) {
            const count_expr = try self.parseExpr();
            return LimitClause{ .limit_comma = .{ .offset = first_expr, .limit = count_expr } };
        }

        // Standard: LIMIT count [OFFSET offset]
        var offset: ?Expr = null;
        if (self.parseKeyword(.OFFSET)) {
            offset = try self.parseExpr();
        }
        return LimitClause{ .limit_offset = .{ .limit = first_expr, .offset = offset } };
    }

    // -----------------------------------------------------------------------
    // Expression parsing (Pratt / precedence climbing)
    // -----------------------------------------------------------------------

    /// Top-level expression entry point.
    pub fn parseExpr(self: *Parser) ParseError!Expr {
        return self.parseSubexpr(Prec.unknown);
    }

    fn parseSubexpr(self: *Parser, min_prec: u8) ParseError!Expr {
        if (self.recursion_depth >= MAX_RECURSION_DEPTH) {
            self.error_message = "Maximum recursion depth exceeded";
            if (self.index > 0 and self.index <= self.tokens.len) {
                self.error_location = self.tokens[self.index - 1].span.start;
            }
            return error.RecursionLimit;
        }
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        var expr = try self.parsePrefix();

        while (true) {
            const next_prec = self.getNextPrecedence();
            if (min_prec >= next_prec) break;
            if (self.peekTokenIs(.Period)) break;
            expr = try self.parseInfix(expr, next_prec);
        }

        return expr;
    }

    fn parsePrefix(self: *Parser) ParseError!Expr {
        const tok = self.nextToken();
        switch (tok.token) {
            .Number => |n| return Expr{ .value = .{ .val = Value{ .number = .{ .raw = n.value, .is_long = n.long } }, .span = tok.span } },
            .SingleQuotedString => |s| return Expr{ .value = .{ .val = Value{ .single_quoted_string = s }, .span = tok.span } },
            .DoubleQuotedString => |s| return Expr{ .value = .{ .val = Value{ .double_quoted_string = s }, .span = tok.span } },
            .HexStringLiteral => |s| return Expr{ .value = .{ .val = Value{ .hex_string = s }, .span = tok.span } },
            .NationalStringLiteral => |s| return Expr{ .value = .{ .val = Value{ .national_string = s }, .span = tok.span } },
            .Placeholder => |s| return Expr{ .value = .{ .val = Value{ .placeholder = s }, .span = tok.span } },

            .Minus => {
                const operand = try self.parseSubexpr(Prec.mul_div_mod);
                const ptr = try self.allocator.create(Expr);
                ptr.* = operand;
                return Expr{ .unary_op = .{ .op = .Minus, .expr = ptr } };
            },
            .Plus => {
                const operand = try self.parseSubexpr(Prec.mul_div_mod);
                const ptr = try self.allocator.create(Expr);
                ptr.* = operand;
                return Expr{ .unary_op = .{ .op = .Plus, .expr = ptr } };
            },
            .Tilde => {
                const operand = try self.parseSubexpr(Prec.plus_minus);
                const ptr = try self.allocator.create(Expr);
                ptr.* = operand;
                return Expr{ .unary_op = .{ .op = .BitwiseNot, .expr = ptr } };
            },

            .LParen => {
                if (self.peekIsKeyword(.SELECT) or self.peekIsKeyword(.WITH) or self.peekIsKeyword(.VALUES)) {
                    const q = try self.parseQuery();
                    try self.expectToken(.RParen);
                    const qptr = try self.allocator.create(ast.Query);
                    qptr.* = q;
                    return Expr{ .subquery = qptr };
                }
                const first = try self.parseExpr();
                if (self.consumeToken(.Comma)) {
                    // Tuple: (expr, expr, ...)
                    var elems: std.ArrayList(Expr) = .empty;
                    try elems.append(self.allocator, first);
                    try elems.append(self.allocator, try self.parseExpr());
                    while (self.consumeToken(.Comma)) {
                        try elems.append(self.allocator, try self.parseExpr());
                    }
                    try self.expectToken(.RParen);
                    return Expr{ .tuple = try elems.toOwnedSlice(self.allocator) };
                }
                try self.expectToken(.RParen);
                const ptr = try self.allocator.create(Expr);
                ptr.* = first;
                return Expr{ .nested = ptr };
            },

            .Mul => return Expr{ .wildcard = tok.span },

            .Word => |w| return try self.parsePrefixWord(w, tok.span),

            else => return self.expected("an expression", tok),
        }
    }

    fn parsePrefixWord(self: *Parser, w: Word, span: @import("span.zig").Span) ParseError!Expr {
        switch (w.keyword) {
            .TRUE => return Expr{ .value = .{ .val = Value{ .boolean = true }, .span = span } },
            .FALSE => return Expr{ .value = .{ .val = Value{ .boolean = false }, .span = span } },
            .NULL => return Expr{ .value = .{ .val = Value.null, .span = span } },

            .NOT => {
                const operand = try self.parseSubexpr(Prec.unary_not);
                const ptr = try self.allocator.create(Expr);
                ptr.* = operand;
                return Expr{ .unary_op = .{ .op = .Not, .expr = ptr } };
            },

            .EXISTS => {
                try self.expectToken(.LParen);
                const q = try self.parseQuery();
                try self.expectToken(.RParen);
                const qptr = try self.allocator.create(Query);
                qptr.* = q;
                return Expr{ .exists = .{ .subquery = qptr, .negated = false } };
            },

            .CASE => return try self.parseCaseExpr(),
            .CAST => return try self.parseCastExpr(),
            .SUBSTR, .SUBSTRING => return try self.parseSubstringExpr(),
            .TRIM => return try self.parseTrimExpr(),
            .POSITION => return try self.parsePositionExpr(),
            .EXTRACT => return try self.parseExtractExpr(),
            .INTERVAL => return try self.parseIntervalExpr(),
            .CONVERT => return try self.parseConvertExpr(),
            .MATCH => return try self.parseMatchAgainstExpr(),

            else => return try self.parseIdentOrFunction(w, span),
        }
    }

    // -----------------------------------------------------------------------
    // Identifier or function call
    // -----------------------------------------------------------------------

    fn parseIdentOrFunction(self: *Parser, first_word: Word, first_span: @import("span.zig").Span) ParseError!Expr {
        const first_ident = Ident{ .value = first_word.value, .quote_style = first_word.quote_style, .span = first_span };

        var parts: std.ArrayList(Ident) = .empty;
        try parts.append(self.allocator, first_ident);

        while (self.consumeToken(.Period)) {
            const next = self.peekToken();
            switch (next.token) {
                .Mul => {
                    _ = self.nextToken();
                    const name_parts = try parts.toOwnedSlice(self.allocator);
                    return Expr{ .qualified_wildcard = ObjectName{ .parts = name_parts } };
                },
                .Word => |nw| {
                    const next_tok = self.nextToken();
                    try parts.append(self.allocator, Ident{ .value = nw.value, .quote_style = nw.quote_style, .span = next_tok.span });
                },
                else => return self.expected("identifier after .", self.peekToken()),
            }
        }

        const name_parts = try parts.toOwnedSlice(self.allocator);

        // Function call
        if (self.peekTokenIs(.LParen)) {
            _ = self.nextToken(); // consume LParen
            const func = try self.parseFunctionArgs(ObjectName{ .parts = name_parts });
            return Expr{ .function = func };
        }

        if (name_parts.len == 1) {
            return Expr{ .identifier = name_parts[0] };
        }
        return Expr{ .compound_identifier = name_parts };
    }

    // -----------------------------------------------------------------------
    // Function argument parsing
    // -----------------------------------------------------------------------

    fn parseFunctionArgs(self: *Parser, name: ObjectName) ParseError!ast.Function {
        var distinct = false;
        var args: std.ArrayList(ast.FunctionArg) = .empty;
        // Pre-size for typical function argument counts.
        try args.ensureTotalCapacity(self.allocator, 4);

        if (self.consumeToken(.Mul)) {
            try self.expectToken(.RParen);
            const star_ptr = try self.allocator.create(Expr);
            star_ptr.* = Expr{ .wildcard = .empty };
            try args.append(self.allocator, ast.FunctionArg{ .unnamed = .{ .expr = star_ptr } });
        } else {
            if (!self.peekTokenIs(.RParen)) {
                distinct = self.parseKeyword(.DISTINCT);
                const first_arg = try self.parseFunctionArg();
                try args.append(self.allocator, first_arg);
                while (self.consumeToken(.Comma)) {
                    const arg = try self.parseFunctionArg();
                    try args.append(self.allocator, arg);
                }
            }
            try self.expectToken(.RParen);
        }

        // OVER clause
        var over: ?ast.WindowSpec = null;
        if (self.parseKeyword(.OVER)) {
            over = try self.parseWindowSpec();
        }

        return ast.Function{
            .name = name,
            .args = try args.toOwnedSlice(self.allocator),
            .filter = null,
            .over = over,
            .within_group = &.{},
            .distinct = distinct,
        };
    }

    fn parseFunctionArg(self: *Parser) ParseError!ast.FunctionArg {
        // Named arg: name => expr  or  name := expr
        const tok = self.peekToken();
        if (tok.token == .Word) {
            const w = switch (tok.token) {
                .Word => |ww| ww,
                else => unreachable,
            };
            if (self.index + 1 < self.tokens.len) {
                const next_tok = self.tokens[self.index + 1];
                switch (next_tok.token) {
                    .RArrow, .Assignment => {
                        const name_tok = self.nextToken(); // consume name (tok.span available)
                        _ = self.nextToken(); // consume => or :=
                        const val_expr = try self.parseExpr();
                        const vptr = try self.allocator.create(Expr);
                        vptr.* = val_expr;
                        return ast.FunctionArg{ .named = .{
                            .name = Ident{ .value = w.value, .quote_style = w.quote_style, .span = name_tok.span },
                            .arg = .{ .expr = vptr },
                        } };
                    },
                    else => {},
                }
            }
        }
        const expr = try self.parseExpr();
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return ast.FunctionArg{ .unnamed = .{ .expr = ptr } };
    }

    // -----------------------------------------------------------------------
    // Window spec  OVER (...)
    // -----------------------------------------------------------------------

    fn parseWindowSpec(self: *Parser) ParseError!ast.WindowSpec {
        // Named window reference: OVER window_name
        if (self.peekToken().token == .Word) {
            const w = switch (self.peekToken().token) {
                .Word => |ww| ww,
                else => unreachable,
            };
            if (w.keyword == .NoKeyword) {
                const wname_tok = self.nextToken();
                return ast.WindowSpec{
                    .window_name = Ident{ .value = w.value, .quote_style = w.quote_style, .span = wname_tok.span },
                    .partition_by = &.{},
                    .order_by = &.{},
                    .window_frame = null,
                };
            }
        }

        try self.expectToken(.LParen);

        var partition_by: []const Expr = &.{};
        if (self.parseKeywords(&.{ .PARTITION, .BY })) {
            partition_by = try self.parseCommaSeparated(Expr, parseExprFn);
        }

        var order_by_exprs: []const ast.OrderByExpr = &.{};
        if (self.parseKeywords(&.{ .ORDER, .BY })) {
            order_by_exprs = try self.parseCommaSeparated(ast.OrderByExpr, parseOrderByExprFn);
        }

        const window_frame = try self.parseWindowFrame();

        try self.expectToken(.RParen);

        return ast.WindowSpec{
            .window_name = null,
            .partition_by = partition_by,
            .order_by = order_by_exprs,
            .window_frame = window_frame,
        };
    }

    fn parseWindowFrame(self: *Parser) ParseError!?ast.WindowFrame {
        const units: ast.WindowFrameUnits = blk: {
            if (self.parseKeyword(.ROWS)) break :blk .rows;
            if (self.parseKeyword(.RANGE)) break :blk .range;
            if (self.parseKeyword(.GROUPS)) break :blk .groups;
            return null;
        };
        if (self.parseKeyword(.BETWEEN)) {
            const start = try self.parseWindowFrameBound();
            try self.expectKeyword(.AND);
            const end = try self.parseWindowFrameBound();
            return ast.WindowFrame{ .units = units, .start_bound = start, .end_bound = end };
        }
        const start = try self.parseWindowFrameBound();
        return ast.WindowFrame{ .units = units, .start_bound = start, .end_bound = null };
    }

    fn parseWindowFrameBound(self: *Parser) ParseError!ast.WindowFrameBound {
        if (self.parseKeyword(.CURRENT)) {
            try self.expectKeyword(.ROW);
            return .current_row;
        }
        if (self.parseKeyword(.UNBOUNDED)) {
            if (self.parseKeyword(.PRECEDING)) return .unbounded_preceding;
            if (self.parseKeyword(.FOLLOWING)) return .unbounded_following;
            return .unbounded_preceding;
        }
        const expr = try self.parseExpr();
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        if (self.parseKeyword(.PRECEDING)) return ast.WindowFrameBound{ .preceding = ptr };
        if (self.parseKeyword(.FOLLOWING)) return ast.WindowFrameBound{ .following = ptr };
        return ast.WindowFrameBound{ .preceding = ptr };
    }

    // -----------------------------------------------------------------------
    // CASE expression
    // -----------------------------------------------------------------------

    fn parseCaseExpr(self: *Parser) ParseError!Expr {
        var operand: ?*const Expr = null;
        if (!self.peekIsKeyword(.WHEN)) {
            const op_expr = try self.parseExpr();
            const ptr = try self.allocator.create(Expr);
            ptr.* = op_expr;
            operand = ptr;
        }

        var whens: std.ArrayList(ast.CaseWhen) = .empty;
        while (self.parseKeyword(.WHEN)) {
            const cond = try self.parseExpr();
            try self.expectKeyword(.THEN);
            const result = try self.parseExpr();
            try whens.append(self.allocator, ast.CaseWhen{ .condition = cond, .result = result });
        }

        var else_result: ?*const Expr = null;
        if (self.parseKeyword(.ELSE)) {
            const er = try self.parseExpr();
            const ptr = try self.allocator.create(Expr);
            ptr.* = er;
            else_result = ptr;
        }
        try self.expectKeyword(.END);

        return Expr{ .case = .{
            .operand = operand,
            .conditions = try whens.toOwnedSlice(self.allocator),
            .else_result = else_result,
        } };
    }

    // -----------------------------------------------------------------------
    // CAST expression
    // -----------------------------------------------------------------------

    fn parseCastExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        const inner = try self.parseExpr();
        try self.expectKeyword(.AS);
        const dt = try self.parseDataType();
        try self.expectToken(.RParen);
        const ptr = try self.allocator.create(Expr);
        ptr.* = inner;
        return Expr{ .cast = .{ .expr = ptr, .data_type = dt } };
    }

    // -----------------------------------------------------------------------
    // SUBSTRING expression
    // -----------------------------------------------------------------------

    fn parseSubstringExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        const expr = try self.parseExpr();
        const eptr = try self.allocator.create(Expr);
        eptr.* = expr;
        var from: ?*const Expr = null;
        var for_: ?*const Expr = null;
        if (self.parseKeyword(.FROM) or self.consumeToken(.Comma)) {
            const fe = try self.parseExpr();
            const fptr = try self.allocator.create(Expr);
            fptr.* = fe;
            from = fptr;
        }
        if (self.parseKeyword(.FOR) or self.consumeToken(.Comma)) {
            const le = try self.parseExpr();
            const lptr = try self.allocator.create(Expr);
            lptr.* = le;
            for_ = lptr;
        }
        try self.expectToken(.RParen);
        return Expr{ .substring = .{ .expr = eptr, .from = from, .@"for" = for_ } };
    }

    // -----------------------------------------------------------------------
    // TRIM expression
    // -----------------------------------------------------------------------

    fn parseTrimExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        var trim_where: ?ast.TrimWhereField = null;
        if (self.parseKeyword(.BOTH)) {
            trim_where = .both;
        } else if (self.parseKeyword(.LEADING)) {
            trim_where = .leading;
        } else if (self.parseKeyword(.TRAILING)) {
            trim_where = .trailing;
        }
        var trim_what: ?*const Expr = null;
        if (trim_where != null or !self.peekIsKeyword(.FROM)) {
            if (!self.peekIsKeyword(.FROM) and !self.peekTokenIs(.RParen)) {
                const tw = try self.parseExpr();
                const twptr = try self.allocator.create(Expr);
                twptr.* = tw;
                trim_what = twptr;
            }
        }
        _ = self.parseKeyword(.FROM);
        const expr = try self.parseExpr();
        const eptr = try self.allocator.create(Expr);
        eptr.* = expr;
        try self.expectToken(.RParen);
        return Expr{ .trim = .{ .expr = eptr, .trim_where = trim_where, .trim_what = trim_what } };
    }

    // -----------------------------------------------------------------------
    // POSITION expression
    // -----------------------------------------------------------------------

    fn parsePositionExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        const sub = try self.parseExpr();
        try self.expectKeyword(.IN);
        const str = try self.parseExpr();
        try self.expectToken(.RParen);
        const sub_ptr = try self.allocator.create(Expr);
        sub_ptr.* = sub;
        const str_ptr = try self.allocator.create(Expr);
        str_ptr.* = str;
        return Expr{ .position = .{ .expr = sub_ptr, .in = str_ptr } };
    }

    // -----------------------------------------------------------------------
    // EXTRACT expression
    // -----------------------------------------------------------------------

    fn parseExtractExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        const field = try self.parseDateTimeField();
        _ = self.parseKeyword(.FROM);
        _ = self.consumeToken(.Comma);
        const expr = try self.parseExpr();
        try self.expectToken(.RParen);
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return Expr{ .extract = .{ .field = field, .expr = ptr } };
    }

    fn parseDateTimeField(self: *Parser) ParseError!ast.DateTimeField {
        const tok = self.nextToken();
        switch (tok.token) {
            .Word => |w| return switch (w.keyword) {
                .YEAR => .year,
                .MONTH => .month,
                .WEEK => .week,
                .DAY => .day,
                .HOUR => .hour,
                .MINUTE => .minute,
                .SECOND => .second,
                .MICROSECOND => .microsecond,
                .MILLISECOND => .millisecond,
                .QUARTER => .quarter,
                .EPOCH => .epoch,
                else => .custom,
            },
            else => return self.expected("a date/time field", tok),
        }
    }

    // -----------------------------------------------------------------------
    // INTERVAL expression
    // -----------------------------------------------------------------------

    fn parseIntervalExpr(self: *Parser) ParseError!Expr {
        const val = try self.parseExpr();
        const vptr = try self.allocator.create(Expr);
        vptr.* = val;
        var leading: ?ast.DateTimeField = null;
        var last: ?ast.DateTimeField = null;

        const dtf_from_keyword = struct {
            fn f(kw: Keyword) ?ast.DateTimeField {
                return switch (kw) {
                    .YEAR => .year,
                    .MONTH => .month,
                    .WEEK => .week,
                    .DAY => .day,
                    .HOUR => .hour,
                    .MINUTE => .minute,
                    .SECOND => .second,
                    .MICROSECOND => .microsecond,
                    .MILLISECOND => .millisecond,
                    .QUARTER => .quarter,
                    else => null,
                };
            }
        }.f;

        const tok = self.peekToken();
        if (tok.token == .Word) {
            const w = switch (tok.token) {
                .Word => |ww| ww,
                else => unreachable,
            };
            if (dtf_from_keyword(w.keyword)) |field| {
                _ = self.nextToken();
                leading = field;
                if (self.parseKeyword(.TO)) {
                    const tok2 = self.nextToken();
                    if (tok2.token == .Word) {
                        const w2 = switch (tok2.token) {
                            .Word => |ww| ww,
                            else => unreachable,
                        };
                        last = dtf_from_keyword(w2.keyword);
                    }
                }
            }
        }
        return Expr{ .interval = .{ .value = vptr, .leading_field = leading, .last_field = last } };
    }

    // -----------------------------------------------------------------------
    // CONVERT expression
    // -----------------------------------------------------------------------

    fn parseConvertExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        const expr = try self.parseExpr();
        const eptr = try self.allocator.create(Expr);
        eptr.* = expr;
        var data_type: ?DataType = null;
        var charset: ?ObjectName = null;
        if (self.parseKeyword(.USING)) {
            charset = try self.parseObjectName();
        } else if (self.consumeToken(.Comma)) {
            data_type = try self.parseDataType();
        }
        try self.expectToken(.RParen);
        return Expr{ .convert = .{ .expr = eptr, .data_type = data_type, .charset = charset } };
    }

    // -----------------------------------------------------------------------
    // MATCH ... AGAINST (MySQL)
    // -----------------------------------------------------------------------

    fn parseMatchAgainstExpr(self: *Parser) ParseError!Expr {
        try self.expectToken(.LParen);
        var cols: std.ArrayList(ObjectName) = .empty;
        const first_col = try self.parseObjectName();
        try cols.append(self.allocator, first_col);
        while (self.consumeToken(.Comma)) {
            const col = try self.parseObjectName();
            try cols.append(self.allocator, col);
        }
        try self.expectToken(.RParen);
        try self.expectKeyword(.AGAINST);
        try self.expectToken(.LParen);
        const match_value = try self.parseValue();
        var modifier: ?[]const u8 = null;
        if (self.parseKeywords(&.{ .IN, .NATURAL, .LANGUAGE, .MODE })) {
            modifier = "IN NATURAL LANGUAGE MODE";
            // WITH QUERY EXPANSION - EXPANSION is not a keyword, skip as word
        } else if (self.parseKeywords(&.{ .IN, .BOOLEAN, .MODE })) {
            modifier = "IN BOOLEAN MODE";
        }
        try self.expectToken(.RParen);
        return Expr{ .match_against = .{
            .columns = try cols.toOwnedSlice(self.allocator),
            .match_value = match_value,
            .modifier = modifier,
        } };
    }

    // -----------------------------------------------------------------------
    // Infix expression parsing
    // -----------------------------------------------------------------------

    fn parseInfix(self: *Parser, left: Expr, prec: u8) ParseError!Expr {
        // MySQL DIV and MOD keywords
        if (self.peekIsKeyword(.DIV)) {
            _ = self.nextToken();
            return try self.makeBinaryOp(left, .MyIntegerDivide, prec);
        }
        if (self.peekIsKeyword(.MOD)) {
            _ = self.nextToken();
            return try self.makeBinaryOp(left, .Modulo, prec);
        }

        const tok = self.nextToken();
        switch (tok.token) {
            .Plus => return try self.makeBinaryOp(left, .Plus, prec),
            .Minus => return try self.makeBinaryOp(left, .Minus, prec),
            .Mul => return try self.makeBinaryOp(left, .Multiply, prec),
            .Div => return try self.makeBinaryOp(left, .Divide, prec),
            .Mod => return try self.makeBinaryOp(left, .Modulo, prec),
            .StringConcat => return try self.makeBinaryOp(left, .StringConcat, prec),
            .Pipe => return try self.makeBinaryOp(left, .BitwiseOr, prec),
            .Caret => return try self.makeBinaryOp(left, .BitwiseXor, prec),
            .Ampersand => return try self.makeBinaryOp(left, .BitwiseAnd, prec),
            .Eq => return try self.makeBinaryOp(left, .Eq, prec),
            .DoubleEq => return try self.makeBinaryOp(left, .Eq, prec),
            .Neq => return try self.makeBinaryOp(left, .NotEq, prec),
            .Lt => return try self.makeBinaryOp(left, .Lt, prec),
            .LtEq => return try self.makeBinaryOp(left, .LtEq, prec),
            .Gt => return try self.makeBinaryOp(left, .Gt, prec),
            .GtEq => return try self.makeBinaryOp(left, .GtEq, prec),
            .Spaceship => return try self.makeBinaryOp(left, .Spaceship, prec),
            .Assignment => return try self.makeBinaryOp(left, .Assignment, prec),
            .ShiftLeft => return try self.makeBinaryOp(left, .ShiftLeft, prec),
            .ShiftRight => return try self.makeBinaryOp(left, .ShiftRight, prec),

            .Word => |w| switch (w.keyword) {
                .AND => return try self.makeBinaryOp(left, .And, prec),
                .OR => return try self.makeBinaryOp(left, .Or, prec),
                .XOR => return try self.makeBinaryOp(left, .Xor, prec),
                .OVERLAPS => return try self.makeBinaryOp(left, .Overlaps, prec),

                .IS => return try self.parseIsExpr(left),

                .NOT => {
                    self.prevToken();
                    const negated = self.parseKeyword(.NOT);
                    if (self.parseKeyword(.IN)) return try self.parseInExpr(left, negated);
                    if (self.parseKeyword(.BETWEEN)) return try self.parseBetweenExpr(left, negated);
                    if (self.parseKeyword(.LIKE)) return try self.parseLikeExpr(left, negated, false);
                    if (self.parseKeyword(.ILIKE)) return try self.parseIlikeExpr(left, negated);
                    if (self.parseKeyword(.REGEXP) or self.parseKeyword(.RLIKE)) return try self.parseRlikeExpr(left, negated, true);
                    return self.expected("IN, BETWEEN, LIKE, or REGEXP after NOT", self.peekToken());
                },
                .IN => return try self.parseInExpr(left, false),
                .BETWEEN => return try self.parseBetweenExpr(left, false),
                .LIKE => return try self.parseLikeExpr(left, false, false),
                .ILIKE => return try self.parseIlikeExpr(left, false),
                .REGEXP, .RLIKE => return try self.parseRlikeExpr(left, false, true),
                .AT => {
                    try self.expectKeyword(.TIME);
                    try self.expectKeyword(.ZONE);
                    const tz = try self.parseSubexpr(prec);
                    const lptr = try self.allocator.create(Expr);
                    lptr.* = left;
                    const tptr = try self.allocator.create(Expr);
                    tptr.* = tz;
                    return Expr{ .at_time_zone = .{ .timestamp = lptr, .time_zone = tptr } };
                },
                .COLLATE => {
                    const collation = try self.parseObjectName();
                    const lptr = try self.allocator.create(Expr);
                    lptr.* = left;
                    return Expr{ .collate = .{ .expr = lptr, .collation = collation } };
                },
                else => return self.expected("an operator or keyword", tok),
            },
            else => return self.expected("an operator", tok),
        }
    }

    fn makeBinaryOp(self: *Parser, left: Expr, op: BinaryOp, prec: u8) ParseError!Expr {
        const right = try self.parseSubexpr(prec);
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        const rptr = try self.allocator.create(Expr);
        rptr.* = right;
        return Expr{ .binary_op = .{ .left = lptr, .op = op, .right = rptr } };
    }

    fn parseIsExpr(self: *Parser, left: Expr) ParseError!Expr {
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        const negated = self.parseKeyword(.NOT);
        if (self.parseKeyword(.NULL)) {
            return if (negated) Expr{ .is_not_null = lptr } else Expr{ .is_null = lptr };
        }
        if (self.parseKeyword(.TRUE)) {
            return if (negated) Expr{ .is_not_true = lptr } else Expr{ .is_true = lptr };
        }
        if (self.parseKeyword(.FALSE)) {
            return if (negated) Expr{ .is_not_false = lptr } else Expr{ .is_false = lptr };
        }
        if (self.parseKeywords(&.{ .DISTINCT, .FROM })) {
            const rhs = try self.parseExpr();
            const rptr = try self.allocator.create(Expr);
            rptr.* = rhs;
            return if (negated)
                Expr{ .is_not_distinct_from = .{ .left = lptr, .right = rptr } }
            else
                Expr{ .is_distinct_from = .{ .left = lptr, .right = rptr } };
        }
        return self.expected("NULL, TRUE, FALSE, or DISTINCT FROM after IS", self.peekToken());
    }

    fn parseInExpr(self: *Parser, left: Expr, negated: bool) ParseError!Expr {
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        try self.expectToken(.LParen);
        if (self.peekIsKeyword(.SELECT) or self.peekIsKeyword(.WITH) or self.peekIsKeyword(.VALUES)) {
            const q = try self.parseQuery();
            try self.expectToken(.RParen);
            const qptr = try self.allocator.create(Query);
            qptr.* = q;
            return Expr{ .in_subquery = .{ .expr = lptr, .subquery = qptr, .negated = negated } };
        }
        const list = try self.parseCommaSeparated(Expr, parseExprFn);
        try self.expectToken(.RParen);
        return Expr{ .in_list = .{ .expr = lptr, .list = list, .negated = negated } };
    }

    fn parseBetweenExpr(self: *Parser, left: Expr, negated: bool) ParseError!Expr {
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        const low = try self.parseSubexpr(Prec.between);
        try self.expectKeyword(.AND);
        const high = try self.parseSubexpr(Prec.between);
        const lowptr = try self.allocator.create(Expr);
        lowptr.* = low;
        const highptr = try self.allocator.create(Expr);
        highptr.* = high;
        return Expr{ .between = .{ .expr = lptr, .negated = negated, .low = lowptr, .high = highptr } };
    }

    fn parseLikeExpr(self: *Parser, left: Expr, negated: bool, _: bool) ParseError!Expr {
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        const pattern = try self.parseSubexpr(Prec.like);
        const pptr = try self.allocator.create(Expr);
        pptr.* = pattern;
        var escape_char: ?u8 = null;
        if (self.parseKeyword(.ESCAPE)) {
            const esc = self.nextToken();
            if (esc.token == .SingleQuotedString) {
                const s = switch (esc.token) {
                    .SingleQuotedString => |ss| ss,
                    else => unreachable,
                };
                if (s.len == 1) escape_char = s[0];
            }
        }
        return Expr{ .like = .{ .negated = negated, .expr = lptr, .pattern = pptr, .escape_char = escape_char } };
    }

    fn parseIlikeExpr(self: *Parser, left: Expr, negated: bool) ParseError!Expr {
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        const pattern = try self.parseSubexpr(Prec.like);
        const pptr = try self.allocator.create(Expr);
        pptr.* = pattern;
        var escape_char: ?u8 = null;
        if (self.parseKeyword(.ESCAPE)) {
            const esc = self.nextToken();
            if (esc.token == .SingleQuotedString) {
                const s = switch (esc.token) {
                    .SingleQuotedString => |ss| ss,
                    else => unreachable,
                };
                if (s.len == 1) escape_char = s[0];
            }
        }
        return Expr{ .ilike = .{ .negated = negated, .expr = lptr, .pattern = pptr, .escape_char = escape_char } };
    }

    fn parseRlikeExpr(self: *Parser, left: Expr, negated: bool, regexp: bool) ParseError!Expr {
        const lptr = try self.allocator.create(Expr);
        lptr.* = left;
        const pattern = try self.parseSubexpr(Prec.like);
        const pptr = try self.allocator.create(Expr);
        pptr.* = pattern;
        return Expr{ .rlike = .{ .negated = negated, .expr = lptr, .pattern = pptr, .regexp = regexp } };
    }

    // -----------------------------------------------------------------------
    // Next precedence computation
    // -----------------------------------------------------------------------

    fn getNextPrecedence(self: *const Parser) u8 {
        const tok = self.peekToken();
        return switch (tok.token) {
            .Word => |w| switch (w.keyword) {
                .OR => Prec.or_,
                .AND => Prec.and_,
                .XOR => Prec.xor,
                .NOT => blk: {
                    if (self.index + 1 < self.tokens.len) {
                        const peek2 = self.tokens[self.index + 1];
                        if (peek2.token == .Word) {
                            const w2 = switch (peek2.token) {
                                .Word => |ww| ww,
                                else => unreachable,
                            };
                            switch (w2.keyword) {
                                .IN, .BETWEEN => break :blk Prec.between,
                                .LIKE, .ILIKE => break :blk Prec.like,
                                .REGEXP, .RLIKE => break :blk Prec.like,
                                .NULL => break :blk Prec.is,
                                else => {},
                            }
                        }
                    }
                    break :blk Prec.unknown;
                },
                .IS => Prec.is,
                .IN, .BETWEEN, .OVERLAPS => Prec.between,
                .LIKE, .ILIKE, .REGEXP, .RLIKE => Prec.like,
                .AT => blk: {
                    if (self.index + 2 < self.tokens.len) {
                        const t1 = self.tokens[self.index + 1];
                        const t2 = self.tokens[self.index + 2];
                        if (t1.token == .Word and t2.token == .Word) {
                            const w1 = switch (t1.token) {
                                .Word => |ww| ww,
                                else => unreachable,
                            };
                            const w2 = switch (t2.token) {
                                .Word => |ww| ww,
                                else => unreachable,
                            };
                            if (w1.keyword == .TIME and w2.keyword == .ZONE) break :blk @as(u8, 41);
                        }
                    }
                    break :blk Prec.unknown;
                },
                .DIV, .MOD => Prec.mul_div_mod,
                .COLLATE => Prec.double_colon,
                else => Prec.unknown,
            },
            .Eq, .DoubleEq, .Neq, .Lt, .LtEq, .Gt, .GtEq, .Spaceship, .Assignment => Prec.eq,
            .Plus, .Minus => Prec.plus_minus,
            .Mul, .Div, .Mod, .StringConcat => Prec.mul_div_mod,
            .Pipe => Prec.pipe,
            .Caret => Prec.caret,
            .Ampersand => Prec.ampersand,
            .ShiftLeft, .ShiftRight => Prec.caret,
            .Period => Prec.period,
            else => Prec.unknown,
        };
    }

    // -----------------------------------------------------------------------
    // Value parsing
    // -----------------------------------------------------------------------

    fn parseValue(self: *Parser) ParseError!Value {
        const tok = self.nextToken();
        switch (tok.token) {
            .Number => |n| return Value{ .number = .{ .raw = n.value, .is_long = n.long } },
            .SingleQuotedString => |s| return Value{ .single_quoted_string = s },
            .DoubleQuotedString => |s| return Value{ .double_quoted_string = s },
            .HexStringLiteral => |s| return Value{ .hex_string = s },
            .NationalStringLiteral => |s| return Value{ .national_string = s },
            .Placeholder => |s| return Value{ .placeholder = s },
            .Word => |w| switch (w.keyword) {
                .TRUE => return Value{ .boolean = true },
                .FALSE => return Value{ .boolean = false },
                .NULL => return Value.null,
                else => return self.expected("a value", tok),
            },
            else => return self.expected("a value", tok),
        }
    }

    // -----------------------------------------------------------------------
    // Data type parsing
    // -----------------------------------------------------------------------

    pub fn parseDataType(self: *Parser) ParseError!DataType {
        const tok = self.nextToken();
        switch (tok.token) {
            .Word => |w| return try self.parseDataTypeWord(w),
            else => return self.expected("a data type", tok),
        }
    }

    fn parseDataTypeWord(self: *Parser, w: Word) ParseError!DataType {
        switch (w.keyword) {
            .INT, .INTEGER => {
                const len = try self.parseOptionalPrecisionU64();
                if (self.parseKeyword(.UNSIGNED)) return DataType{ .int_unsigned = len };
                _ = self.parseKeyword(.SIGNED);
                return DataType{ .int = len };
            },
            .BIGINT => {
                const len = try self.parseOptionalPrecisionU64();
                if (self.parseKeyword(.UNSIGNED)) return DataType{ .big_int_unsigned = len };
                _ = self.parseKeyword(.SIGNED);
                return DataType{ .big_int = len };
            },
            .TINYINT => {
                const len = try self.parseOptionalPrecisionU64();
                if (self.parseKeyword(.UNSIGNED)) return DataType{ .tiny_int_unsigned = len };
                _ = self.parseKeyword(.SIGNED);
                return DataType{ .tiny_int = len };
            },
            .SMALLINT => {
                const len = try self.parseOptionalPrecisionU64();
                _ = self.parseKeyword(.UNSIGNED);
                _ = self.parseKeyword(.SIGNED);
                return DataType{ .small_int = len };
            },
            .MEDIUMINT => {
                const len = try self.parseOptionalPrecisionU64();
                _ = self.parseKeyword(.UNSIGNED);
                return DataType{ .medium_int = len };
            },
            .FLOAT => {
                const info = try self.parseExactNumberInfoFn();
                return DataType{ .float = info };
            },
            .DOUBLE => {
                _ = self.parseKeyword(.PRECISION);
                const info = try self.parseExactNumberInfoFn();
                if (self.parseKeyword(.UNSIGNED)) return DataType{ .double_unsigned = info };
                return DataType{ .double = info };
            },
            .REAL => {
                if (self.parseKeyword(.UNSIGNED)) return DataType.real_unsigned;
                return DataType.real;
            },
            .NUMERIC => {
                const info = try self.parseExactNumberInfoFn();
                return DataType{ .numeric = info };
            },
            .DECIMAL, .DEC => {
                const info = try self.parseExactNumberInfoFn();
                if (self.parseKeyword(.UNSIGNED)) return DataType{ .decimal_unsigned = info };
                return DataType{ .decimal = info };
            },
            .BOOL => return DataType.bool,
            .BOOLEAN => return DataType.boolean,
            .CHAR, .CHARACTER => {
                const len = try self.parseOptionalCharLengthFn();
                return DataType{ .char = len };
            },
            .VARCHAR, .NVARCHAR => {
                const len = try self.parseOptionalCharLengthFn();
                return DataType{ .varchar = len };
            },
            .BINARY => {
                const len = try self.parseOptionalPrecisionU64();
                return DataType{ .binary = len };
            },
            .VARBINARY => {
                const len = try self.parseOptionalPrecisionU64();
                return DataType{ .varbinary = if (len) |l| ast_types.BinaryLength{ .integer = l } else null };
            },
            .TEXT => return DataType.text,
            .TINYTEXT => return DataType.tiny_text,
            .MEDIUMTEXT => return DataType.medium_text,
            .LONGTEXT => return DataType.long_text,
            .BLOB => return DataType{ .blob = null },
            .TINYBLOB => return DataType.tiny_blob,
            .MEDIUMBLOB => return DataType.medium_blob,
            .LONGBLOB => return DataType.long_blob,
            .DATE => return DataType.date,
            .DATETIME => {
                const prec = try self.parseOptionalPrecisionU64();
                return DataType{ .datetime = prec };
            },
            .TIME => return DataType{ .time = .{ .precision = null, .tz = .none } },
            .TIMESTAMP => {
                const prec = try self.parseOptionalPrecisionU64();
                return DataType{ .timestamp = .{ .precision = prec, .tz = .none } };
            },
            .JSON => return DataType.json,
            .BIT => {
                const len = try self.parseOptionalPrecisionU64();
                return DataType{ .bit = len };
            },
            .ENUM => {
                try self.expectToken(.LParen);
                var vals: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const s = try self.parseStringLiteral();
                    try vals.append(self.allocator, s);
                    if (!self.consumeToken(.Comma)) break;
                }
                try self.expectToken(.RParen);
                return DataType{ .@"enum" = try vals.toOwnedSlice(self.allocator) };
            },
            .SET => {
                try self.expectToken(.LParen);
                var vals: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const s = try self.parseStringLiteral();
                    try vals.append(self.allocator, s);
                    if (!self.consumeToken(.Comma)) break;
                }
                try self.expectToken(.RParen);
                return DataType{ .set = try vals.toOwnedSlice(self.allocator) };
            },
            else => {
                const name = w.value;
                var mods: std.ArrayList([]const u8) = .empty;
                if (self.consumeToken(.LParen)) {
                    while (!self.peekTokenIs(.RParen) and !self.peekTokenIs(.EOF)) {
                        const mod_tok = self.nextToken();
                        switch (mod_tok.token) {
                            .Number => |n| try mods.append(self.allocator, n.value),
                            .Word => |mw| try mods.append(self.allocator, mw.value),
                            .SingleQuotedString => |s| try mods.append(self.allocator, s),
                            else => {},
                        }
                        if (!self.consumeToken(.Comma)) break;
                    }
                    try self.expectToken(.RParen);
                }
                return DataType{ .custom = .{
                    .name = name,
                    .modifiers = try mods.toOwnedSlice(self.allocator),
                } };
            },
        }
    }

    fn parseOptionalPrecisionU64(self: *Parser) ParseError!?u64 {
        if (!self.consumeToken(.LParen)) return null;
        const tok = self.nextToken();
        const val: ?u64 = switch (tok.token) {
            .Number => |n| std.fmt.parseInt(u64, n.value, 10) catch null,
            else => null,
        };
        try self.expectToken(.RParen);
        return val;
    }

    fn parseExactNumberInfoFn(self: *Parser) ParseError!ExactNumberInfo {
        if (!self.consumeToken(.LParen)) return ExactNumberInfo.none;
        const tok = self.nextToken();
        const precision: u64 = switch (tok.token) {
            .Number => |n| std.fmt.parseInt(u64, n.value, 10) catch 0,
            else => 0,
        };
        if (self.consumeToken(.Comma)) {
            const tok2 = self.nextToken();
            const scale: i64 = switch (tok2.token) {
                .Number => |n| std.fmt.parseInt(i64, n.value, 10) catch 0,
                else => 0,
            };
            try self.expectToken(.RParen);
            return ExactNumberInfo{ .precision_and_scale = .{ .precision = precision, .scale = scale } };
        }
        try self.expectToken(.RParen);
        return ExactNumberInfo{ .precision = precision };
    }

    fn parseOptionalCharLengthFn(self: *Parser) ParseError!?CharacterLength {
        if (!self.consumeToken(.LParen)) return null;
        // Handle VARCHAR(MAX) for T-SQL
        if (self.peekIsKeyword(.MAX)) {
            _ = self.nextToken();
            try self.expectToken(.RParen);
            return CharacterLength.max;
        }
        const tok = self.nextToken();
        const len: u64 = switch (tok.token) {
            .Number => |n| std.fmt.parseInt(u64, n.value, 10) catch 0,
            else => 0,
        };
        var unit: ?ast_types.CharLengthUnits = null;
        // CHARACTERS and OCTETS are not in the keyword enum; match as plain words.
        {
            const saved = self.index;
            const maybe = self.nextToken();
            switch (maybe.token) {
                .Word => |ww| {
                    if (std.mem.eql(u8, ww.value, "CHARACTERS") or std.mem.eql(u8, ww.value, "CHARS")) {
                        unit = .characters;
                    } else if (std.mem.eql(u8, ww.value, "OCTETS")) {
                        unit = .octets;
                    } else {
                        self.index = saved;
                    }
                },
                else => self.index = saved,
            }
        }
        try self.expectToken(.RParen);
        return CharacterLength{ .integer = .{ .length = len, .unit = unit } };
    }

    pub fn parseStringLiteral(self: *Parser) ParseError![]const u8 {
        const tok = self.nextToken();
        switch (tok.token) {
            .SingleQuotedString => |s| return s,
            .DoubleQuotedString => |s| return s,
            .Word => |ww| return ww.value,
            else => return self.expected("a string literal", tok),
        }
    }

    // -----------------------------------------------------------------------
    // Object name / identifier helpers
    // -----------------------------------------------------------------------

    pub fn parseObjectName(self: *Parser) ParseError!ObjectName {
        var parts: std.ArrayList(Ident) = .empty;
        const first = try self.parseIdent();
        try parts.append(self.allocator, first);
        while (self.consumeToken(.Period)) {
            const next = try self.parseIdent();
            try parts.append(self.allocator, next);
        }
        return ObjectName{ .parts = try parts.toOwnedSlice(self.allocator) };
    }

    pub fn parseIdent(self: *Parser) ParseError!Ident {
        const tok = self.nextToken();
        switch (tok.token) {
            .Word => |w| return Ident{ .value = w.value, .quote_style = w.quote_style, .span = tok.span },
            else => return self.expected("an identifier", tok),
        }
    }

    // -----------------------------------------------------------------------
    // Token navigation helpers
    // -----------------------------------------------------------------------

    pub fn nextToken(self: *Parser) TokenWithSpan {
        while (self.index < self.tokens.len) {
            const tok = self.tokens[self.index];
            self.index += 1;
            switch (tok.token) {
                .Whitespace => continue,
                else => return tok,
            }
        }
        return TokenWithSpan.wrap(Token.EOF);
    }

    pub fn prevToken(self: *Parser) void {
        if (self.index > 0) self.index -= 1;
    }

    /// Return the last non-whitespace token that was consumed (i.e. before index).
    pub fn lastConsumedToken(self: *const Parser) TokenWithSpan {
        var i = self.index;
        while (i > 0) {
            i -= 1;
            switch (self.tokens[i].token) {
                .Whitespace => continue,
                else => return self.tokens[i],
            }
        }
        return TokenWithSpan.wrap(Token.EOF);
    }

    pub fn peekToken(self: *const Parser) TokenWithSpan {
        var i = self.index;
        while (i < self.tokens.len) {
            const tok = self.tokens[i];
            i += 1;
            switch (tok.token) {
                .Whitespace => continue,
                else => return tok,
            }
        }
        return TokenWithSpan.wrap(Token.EOF);
    }

    fn peekWord(self: *const Parser) Word {
        const tok = self.peekToken();
        return switch (tok.token) {
            .Word => |w| w,
            else => Word{ .value = "", .quote_style = null, .keyword = .NoKeyword },
        };
    }

    pub fn peekTokenIs(self: *const Parser, comptime tag: std.meta.Tag(Token)) bool {
        const tok = self.peekToken();
        return std.meta.activeTag(tok.token) == tag;
    }

    pub fn peekIsKeyword(self: *const Parser, kw: Keyword) bool {
        const tok = self.peekToken();
        switch (tok.token) {
            .Word => |w| return w.keyword == kw,
            else => return false,
        }
    }

    pub fn consumeToken(self: *Parser, comptime tag: std.meta.Tag(Token)) bool {
        const saved = self.index;
        const tok = self.nextToken();
        if (std.meta.activeTag(tok.token) == tag) return true;
        self.index = saved;
        return false;
    }

    pub fn parseKeyword(self: *Parser, kw: Keyword) bool {
        const saved = self.index;
        const tok = self.nextToken();
        switch (tok.token) {
            .Word => |w| if (w.keyword == kw) return true,
            else => {},
        }
        self.index = saved;
        return false;
    }

    pub fn parseKeywords(self: *Parser, kws: []const Keyword) bool {
        const saved = self.index;
        for (kws) |kw| {
            if (!self.parseKeyword(kw)) {
                self.index = saved;
                return false;
            }
        }
        return true;
    }

    pub fn expectToken(self: *Parser, comptime tag: std.meta.Tag(Token)) ParseError!void {
        const tok = self.nextToken();
        if (std.meta.activeTag(tok.token) == tag) return;
        return self.expected(tokenTagToStr(tag), tok);
    }

    /// Map token tag to a user-readable string for error messages.
    fn tokenTagToStr(comptime tag: std.meta.Tag(Token)) []const u8 {
        return switch (tag) {
            .LParen => "(",
            .RParen => ")",
            .LBracket => "[",
            .RBracket => "]",
            .LBrace => "{",
            .RBrace => "}",
            .Comma => ",",
            .SemiColon => ";",
            .Period => ".",
            .Colon => ":",
            .Eq => "=",
            .Neq => "!=",
            .Lt => "<",
            .Gt => ">",
            .LtEq => "<=",
            .GtEq => ">=",
            .Plus => "+",
            .Minus => "-",
            .Mul => "*",
            .Div => "/",
            .Mod => "%",
            .Ampersand => "&",
            .Pipe => "|",
            .Caret => "^",
            .EOF => "end of input",
            else => @tagName(tag),
        };
    }

    pub fn expectKeyword(self: *Parser, kw: Keyword) ParseError!void {
        if (!self.parseKeyword(kw)) {
            return self.expected(kw.toString(), self.peekToken());
        }
    }

    // -----------------------------------------------------------------------
    // Error reporting helpers
    // -----------------------------------------------------------------------

    /// Return a human-readable description of a token for error messages.
    fn describeToken(token: Token) []const u8 {
        return switch (token) {
            .EOF => "EOF",
            .Word => |w| if (w.keyword != .NoKeyword) w.keyword.toString() else w.value,
            .Number => |n| n.value,
            .SingleQuotedString => |s| s,
            .DoubleQuotedString => |s| s,
            .HexStringLiteral => "hex string",
            .NationalStringLiteral => "national string",
            .SingleQuotedByteStringLiteral => "byte string",
            .Comma => ",",
            .Whitespace => "whitespace",
            .DoubleEq => "==",
            .Eq => "=",
            .Neq => "!=",
            .Lt => "<",
            .Gt => ">",
            .LtEq => "<=",
            .GtEq => ">=",
            .Spaceship => "<=>",
            .Plus => "+",
            .Minus => "-",
            .Mul => "*",
            .Div => "/",
            .Mod => "%",
            .StringConcat => "||",
            .LParen => "(",
            .RParen => ")",
            .Period => ".",
            .Colon => ":",
            .DoubleColon => "::",
            .Assignment => ":=",
            .SemiColon => ";",
            .Backslash => "\\",
            .LBracket => "[",
            .RBracket => "]",
            .Ampersand => "&",
            .Pipe => "|",
            .Caret => "^",
            .LBrace => "{",
            .RBrace => "}",
            .RArrow => "=>",
            .Sharp => "#",
            .Tilde => "~",
            .ExclamationMark => "!",
            .AtSign => "@",
            .ShiftLeft => "<<",
            .ShiftRight => ">>",
            .Placeholder => |p| p,
            .Char => "character",
        };
    }

    /// Set error detail to "Expected: {what}, found: {token}" and return ParseFailed.
    pub fn expected(self: *Parser, what: []const u8, found: TokenWithSpan) ParseError {
        self.error_location = found.span.start;
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(self.allocator, "Expected: ") catch return error.OutOfMemory;
        buf.appendSlice(self.allocator, what) catch return error.OutOfMemory;
        buf.appendSlice(self.allocator, ", found: ") catch return error.OutOfMemory;
        buf.appendSlice(self.allocator, describeToken(found.token)) catch return error.OutOfMemory;
        self.error_message = buf.items;
        return error.ParseFailed;
    }

    /// Set a plain error message and return ParseFailed. Location is taken from
    /// the most recently consumed token.
    fn fail(self: *Parser, msg: []const u8) ParseError {
        self.error_message = msg;
        if (self.index > 0 and self.index <= self.tokens.len) {
            self.error_location = self.tokens[self.index - 1].span.start;
        }
        return error.ParseFailed;
    }

    // -----------------------------------------------------------------------
    // Generic comma-separated list parser
    // -----------------------------------------------------------------------

    pub fn parseCommaSeparated(
        self: *Parser,
        comptime T: type,
        comptime parseFn: fn (*Parser) ParseError!T,
    ) ParseError![]const T {
        var items: std.ArrayList(T) = .empty;
        // Pre-size for typical comma-separated list lengths.
        try items.ensureTotalCapacity(self.allocator, 8);
        const first = try parseFn(self);
        try items.append(self.allocator, first);
        while (self.consumeToken(.Comma)) {
            const item = try parseFn(self);
            try items.append(self.allocator, item);
        }
        return items.toOwnedSlice(self.allocator);
    }

    // -----------------------------------------------------------------------
    // Static fn adapters (pub so parser_dml_ddl.zig can reference them)
    // -----------------------------------------------------------------------

    pub fn parseExprFn(self: *Parser) ParseError!Expr {
        return self.parseExpr();
    }
    pub fn parseIdentFn(self: *Parser) ParseError!Ident {
        return self.parseIdent();
    }
    pub fn parseObjectNameFn(self: *Parser) ParseError!ObjectName {
        return self.parseObjectName();
    }
    pub fn parseAssignmentFn(self: *Parser) ParseError!ast.Assignment {
        // Parse: target_col = value  or  (col1, col2) = (val1, val2)
        var parts: std.ArrayList(Ident) = .empty;
        const first = try self.parseIdent();
        try parts.append(self.allocator, first);
        while (self.consumeToken(.Period)) {
            const next = try self.parseIdent();
            try parts.append(self.allocator, next);
        }
        try self.expectToken(.Eq);
        const value = try self.parseExpr();
        return ast.Assignment{
            .target = try parts.toOwnedSlice(self.allocator),
            .value = value,
        };
    }

    /// Parse a number literal and return it as u64.
    pub fn parseLiteralUint(self: *Parser) ParseError!u64 {
        const tok = self.nextToken();
        switch (tok.token) {
            .Number => |n| return std.fmt.parseInt(u64, n.value, 10) catch return self.fail("Expected integer, got invalid number"),
            else => return self.expected("a number", tok),
        }
    }

    /// Parse an identifier and return its string value (for table options, USING, etc.).
    pub fn parseIdentifierString(self: *Parser) ParseError![]const u8 {
        const tok = self.nextToken();
        switch (tok.token) {
            .Word => |w| return w.value,
            .SingleQuotedString => |s| return s,
            .Number => |n| return n.value,
            else => return self.expected("an identifier or string", tok),
        }
    }
};

// ---------------------------------------------------------------------------
// Token stream filter: strip whitespace from a full token list
// ---------------------------------------------------------------------------

/// Filter out whitespace tokens. Returns a new slice owned by `allocator`.
pub fn stripWhitespace(
    allocator: std.mem.Allocator,
    tokens: []const TokenWithSpan,
) error{OutOfMemory}![]TokenWithSpan {
    var buf: std.ArrayList(TokenWithSpan) = .empty;
    // Pre-size to input length: most tokens are non-whitespace so this is a
    // tight upper bound that avoids repeated reallocation during the scan.
    try buf.ensureTotalCapacity(allocator, tokens.len);
    for (tokens) |t| {
        switch (t.token) {
            .Whitespace => continue,
            else => try buf.append(allocator, t),
        }
    }
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse simple SELECT" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "SELECT 1");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    switch (stmts[0]) {
        .select => {},
        else => return error.TestFailed,
    }
}

test "parse SELECT with WHERE" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "SELECT a, b FROM t WHERE a > 1");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    switch (q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 2), s.projection.len);
            try std.testing.expectEqual(@as(usize, 1), s.from.len);
            try std.testing.expect(s.selection != null);
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT with JOIN" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "SELECT a.x, b.y FROM a JOIN b ON a.id = b.id");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    switch (q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.from.len);
            try std.testing.expectEqual(@as(usize, 1), s.from[0].joins.len);
        },
        else => return error.TestFailed,
    }
}

test "parse UNION query" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "SELECT 1 UNION ALL SELECT 2");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    switch (q.body.*) {
        .set_operation => |so| {
            try std.testing.expect(so.op == .@"union");
            try std.testing.expect(so.quantifier == .all);
        },
        else => return error.TestFailed,
    }
}

test "parse expression precedence" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "SELECT 1 + 2 * 3");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    switch (q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            switch (s.projection[0]) {
                .unnamed_expr => |e| switch (e) {
                    .binary_op => |op| {
                        try std.testing.expect(op.op == .Plus);
                        switch (op.right.*) {
                            .binary_op => |inner| try std.testing.expect(inner.op == .Multiply),
                            else => return error.TestFailed,
                        }
                    },
                    else => return error.TestFailed,
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse WITH CTE" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "WITH cte AS (SELECT 1 AS n) SELECT n FROM cte");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    try std.testing.expect(q.with != null);
    try std.testing.expectEqual(@as(usize, 1), q.with.?.cte_tables.len);
}

test "parse LIMIT OFFSET" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "SELECT 1 LIMIT 10 OFFSET 5");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    try std.testing.expect(q.limit_clause != null);
}

test "parse MySQL LIMIT comma syntax" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.MySQL, "SELECT 1 LIMIT 5, 10");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.mysql, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const q = stmts[0].select;
    try std.testing.expect(q.limit_clause != null);
    switch (q.limit_clause.?) {
        .limit_comma => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// Helper: parse one SELECT statement with Generic dialect
// ---------------------------------------------------------------------------

fn parseOneSelect(sql: []const u8) !struct { q: *const Query, arena: std.heap.ArenaAllocator } {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    if (stmts.len != 1) return error.TestFailed;
    switch (stmts[0]) {
        .select => |q| return .{ .q = q, .arena = arena },
        else => {
            arena.deinit();
            return error.TestFailed;
        },
    }
}

fn parseOneSelectMysql(sql: []const u8) !struct { q: *const Query, arena: std.heap.ArenaAllocator } {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.MySQL, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.mysql, tokens);
    const stmts = try parser.parseStatements();
    if (stmts.len != 1) return error.TestFailed;
    switch (stmts[0]) {
        .select => |q| return .{ .q = q, .arena = arena },
        else => {
            arena.deinit();
            return error.TestFailed;
        },
    }
}

// ---------------------------------------------------------------------------
// SELECT predicate tests
// ---------------------------------------------------------------------------

test "parse SELECT WHERE IN list" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE a IN (1, 2, 3)");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .in_list => |il| {
                    try std.testing.expect(!il.negated);
                    try std.testing.expectEqual(@as(usize, 3), il.list.len);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT WHERE BETWEEN" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE a BETWEEN 10 AND 20");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .between => |b| {
                    try std.testing.expect(!b.negated);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT WHERE LIKE" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE name LIKE 'foo%'");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .like => |l| {
                    try std.testing.expect(!l.negated);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT WHERE IS NULL" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE name IS NULL");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .is_null => {},
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT WHERE IS NOT NULL" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE name IS NOT NULL");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .is_not_null => {},
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT DISTINCT" {
    var result = try parseOneSelect("SELECT DISTINCT a FROM t1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.distinct != null);
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT GROUP BY HAVING" {
    var result = try parseOneSelect("SELECT a, COUNT(*) FROM t1 GROUP BY a HAVING COUNT(*) > 1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 2), s.projection.len);
            switch (s.group_by) {
                .expressions => |exprs| try std.testing.expect(exprs.len > 0),
                else => return error.TestFailed,
            }
            try std.testing.expect(s.having != null);
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT with window function" {
    var result = try parseOneSelect("SELECT a, SUM(b) OVER (PARTITION BY c ORDER BY d) FROM t1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 2), s.projection.len);
            // Second projection should contain a function with OVER clause
            switch (s.projection[1]) {
                .unnamed_expr => |e| {
                    switch (e) {
                        .function => |f| {
                            try std.testing.expect(f.over != null);
                            try std.testing.expectEqual(@as(usize, 1), f.over.?.partition_by.len);
                            try std.testing.expectEqual(@as(usize, 1), f.over.?.order_by.len);
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT from derived table (subquery in FROM)" {
    var result = try parseOneSelect("SELECT * FROM (SELECT id, name FROM t1 WHERE active = 1) AS sub");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.from.len);
            switch (s.from[0].relation) {
                .derived => |d| {
                    try std.testing.expect(d.alias != null);
                    try std.testing.expectEqualStrings("sub", d.alias.?.name.value);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT WHERE IN subquery" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE id IN (SELECT id FROM t2)");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .in_subquery => |isq| {
                    try std.testing.expect(!isq.negated);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT WHERE EXISTS" {
    var result = try parseOneSelect("SELECT * FROM t1 WHERE EXISTS (SELECT 1 FROM t2 WHERE t2.fk = t1.id)");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expect(s.selection != null);
            switch (s.selection.?) {
                .exists => |e| {
                    try std.testing.expect(!e.negated);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse scalar subquery in SELECT list" {
    var result = try parseOneSelect("SELECT (SELECT MAX(val) FROM t2) AS max_val FROM t1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            // Should be an aliased expression containing a subquery
            switch (s.projection[0]) {
                .expr_with_alias => |ea| {
                    // The expression should be a subquery or nested containing a subquery
                    switch (ea.expr) {
                        .subquery => {},
                        .nested => |n| switch (n.*) {
                            .subquery => {},
                            else => return error.TestFailed,
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse WITH RECURSIVE CTE" {
    var result = try parseOneSelect(
        "WITH RECURSIVE tree AS (SELECT id, parent_id, name FROM categories WHERE parent_id IS NULL UNION ALL SELECT c.id, c.parent_id, c.name FROM categories c JOIN tree t ON c.parent_id = t.id) SELECT * FROM tree",
    );
    defer result.arena.deinit();
    try std.testing.expect(result.q.with != null);
    try std.testing.expect(result.q.with.?.recursive);
    try std.testing.expectEqual(@as(usize, 1), result.q.with.?.cte_tables.len);
    try std.testing.expectEqualStrings("tree", result.q.with.?.cte_tables[0].alias.name.value);
}

test "parse SELECT with MySQL FORCE INDEX" {
    var result = try parseOneSelectMysql("SELECT * FROM t1 FORCE INDEX (idx1) WHERE a = 1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.from.len);
            switch (s.from[0].relation) {
                .table => |t| {
                    try std.testing.expect(t.index_hints.len > 0);
                    try std.testing.expect(t.index_hints[0].hint_type == .force_index);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT with MySQL USE INDEX" {
    var result = try parseOneSelectMysql("SELECT * FROM t1 USE INDEX (idx1, idx2) WHERE a = 1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            switch (s.from[0].relation) {
                .table => |t| {
                    try std.testing.expect(t.index_hints.len > 0);
                    try std.testing.expect(t.index_hints[0].hint_type == .use_index);
                    try std.testing.expectEqual(@as(usize, 2), t.index_hints[0].index_names.len);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT with MySQL IGNORE INDEX" {
    var result = try parseOneSelectMysql("SELECT * FROM t1 IGNORE INDEX (idx1) WHERE a = 1");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            switch (s.from[0].relation) {
                .table => |t| {
                    try std.testing.expect(t.index_hints.len > 0);
                    try std.testing.expect(t.index_hints[0].hint_type == .ignore_index);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse SELECT with DIV operator" {
    var result = try parseOneSelectMysql("SELECT 10 DIV 3");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            switch (s.projection[0]) {
                .unnamed_expr => |e| switch (e) {
                    .binary_op => |op| {
                        try std.testing.expect(op.op == .MyIntegerDivide);
                    },
                    else => return error.TestFailed,
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse MySQL @variable" {
    var result = try parseOneSelectMysql("SELECT @aurora_server_id AS srv_id");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            switch (s.projection[0]) {
                .expr_with_alias => |ea| {
                    switch (ea.expr) {
                        .value => |v| switch (v.val) {
                            .placeholder => |p| try std.testing.expectEqualStrings("@aurora_server_id", p),
                            else => return error.TestFailed,
                        },
                        else => return error.TestFailed,
                    }
                    try std.testing.expectEqualStrings("srv_id", ea.alias.value);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse MySQL @@system_variable" {
    var result = try parseOneSelectMysql("SELECT @@server_id AS sid");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            switch (s.projection[0]) {
                .expr_with_alias => |ea| {
                    switch (ea.expr) {
                        .value => |v| switch (v.val) {
                            .placeholder => |p| try std.testing.expectEqualStrings("@@server_id", p),
                            else => return error.TestFailed,
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse MySQL @@global.variable" {
    var result = try parseOneSelectMysql("SELECT @@global.server_id AS sid");
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            switch (s.projection[0]) {
                .expr_with_alias => |ea| {
                    switch (ea.expr) {
                        .value => |v| switch (v.val) {
                            .placeholder => |p| try std.testing.expectEqualStrings("@@global.server_id", p),
                            else => return error.TestFailed,
                        },
                        else => return error.TestFailed,
                    }
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse complex query with @variable" {
    // The exact failing query from issues/query_with_variables.md
    const sql = "select t.* from (select b.uuid, b.name, c.domain, u.email as user_email, " ++
        "current_timestamp() as cur_ts, @aurora_server_id as srv_id from booking b " ++
        "join tripactions.company c on b.company_uuid = c.uuid " ++
        "join user u on c.uuid = u.company_uuid " ++
        "where c.uuid = 'foo' and b.type in ('train', 'air')) t limit 50";
    var result = try parseOneSelectMysql(sql);
    defer result.arena.deinit();
    // Just verify it parses without error and has the expected structure
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.projection.len);
            try std.testing.expectEqual(@as(usize, 1), s.from.len);
        },
        else => return error.TestFailed,
    }
    try std.testing.expect(result.q.limit_clause != null);
}

test "parse complex query with @@global.variable and LIMIT comma" {
    const sql = "select t.* from (select b.uuid, @@global.server_id as srv_id " ++
        "from booking b join user u on b.id = u.id) t limit 50, 10";
    var result = try parseOneSelectMysql(sql);
    defer result.arena.deinit();
    switch (result.q.body.*) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.from.len);
        },
        else => return error.TestFailed,
    }
    switch (result.q.limit_clause.?) {
        .limit_comma => {},
        else => return error.TestFailed,
    }
}

// ---------------------------------------------------------------------------
// E2E test helpers
// ---------------------------------------------------------------------------

/// Parse SQL with Generic dialect, return all statements.
fn parseStmts(sql: []const u8) !struct { stmts: []const Statement, arena: std.heap.ArenaAllocator } {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);
    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    return .{ .stmts = stmts, .arena = arena };
}

/// Parse SQL with MySQL dialect, return all statements.
fn parseStmtsMysql(sql: []const u8) !struct { stmts: []const Statement, arena: std.heap.ArenaAllocator } {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.MySQL, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);
    var parser = Parser.init(a, Dialect.mysql, tokens);
    const stmts = try parser.parseStatements();
    return .{ .stmts = stmts, .arena = arena };
}

/// Assert that SQL parses to exactly N statements with Generic dialect.
fn expectParses(sql: []const u8, expected_count: usize) !void {
    var result = try parseStmts(sql);
    defer result.arena.deinit();
    try std.testing.expectEqual(expected_count, result.stmts.len);
}

/// Assert that SQL parses to exactly N statements with MySQL dialect.
fn expectParsesMysql(sql: []const u8, expected_count: usize) !void {
    var result = try parseStmtsMysql(sql);
    defer result.arena.deinit();
    try std.testing.expectEqual(expected_count, result.stmts.len);
}

// ---------------------------------------------------------------------------
// E2E: DML SELECT
// ---------------------------------------------------------------------------

test "e2e: SELECT basics" {
    try expectParses("SELECT 1;", 1);
    try expectParses("SELECT 1 + 2 AS result;", 1);
    try expectParses("SELECT * FROM t1;", 1);
    try expectParses("SELECT a, b, c FROM t1 WHERE a > 10 ORDER BY b DESC LIMIT 5;", 1);
    try expectParses("SELECT * FROM t1 WHERE a IN (1, 2, 3);", 1);
    try expectParses("SELECT * FROM t1 WHERE a BETWEEN 10 AND 20;", 1);
    try expectParses("SELECT * FROM t1 WHERE name LIKE 'foo%';", 1);
    try expectParses("SELECT * FROM t1 WHERE name IS NULL;", 1);
    try expectParses("SELECT * FROM t1 WHERE name IS NOT NULL;", 1);
    try expectParses("SELECT DISTINCT a FROM t1;", 1);
    try expectParses("SELECT a, COUNT(*) FROM t1 GROUP BY a HAVING COUNT(*) > 1;", 1);
    try expectParses("SELECT a, SUM(b) OVER (PARTITION BY c ORDER BY d) FROM t1;", 1);
}

test "e2e: JOINs" {
    try expectParses("SELECT * FROM t1 INNER JOIN t2 ON t1.id = t2.id;", 1);
    try expectParses("SELECT * FROM t1 LEFT JOIN t2 ON t1.id = t2.id;", 1);
    try expectParses("SELECT * FROM t1 RIGHT OUTER JOIN t2 USING (id);", 1);
    try expectParses("SELECT * FROM t1 CROSS JOIN t2;", 1);
    try expectParses("SELECT * FROM t1 NATURAL JOIN t2;", 1);
    try expectParses("SELECT * FROM t1 JOIN t2 ON t1.id = t2.id JOIN t3 ON t2.fk = t3.id;", 1);
}

test "e2e: subqueries and CTEs" {
    try expectParses("SELECT * FROM (SELECT id, name FROM t1 WHERE active = 1) AS sub;", 1);
    try expectParses("SELECT * FROM t1 WHERE id IN (SELECT id FROM t2);", 1);
    try expectParses("SELECT * FROM t1 WHERE EXISTS (SELECT 1 FROM t2 WHERE t2.fk = t1.id);", 1);
    try expectParses("SELECT (SELECT MAX(val) FROM t2) AS max_val FROM t1;", 1);
    try expectParses(
        "WITH cte AS (SELECT id, name FROM t1 WHERE active = 1) SELECT * FROM cte WHERE id > 10;",
        1,
    );
    try expectParses(
        "WITH RECURSIVE tree AS (" ++
            "SELECT id, parent_id, name FROM categories WHERE parent_id IS NULL " ++
            "UNION ALL " ++
            "SELECT c.id, c.parent_id, c.name FROM categories c JOIN tree t ON c.parent_id = t.id" ++
            ") SELECT * FROM tree;",
        1,
    );
}

test "e2e: INSERT, UPDATE, DELETE" {
    try expectParses("INSERT INTO t1 (a, b) VALUES (1, 'foo'), (2, 'bar');", 1);
    try expectParses("INSERT INTO t1 SELECT * FROM t2;", 1);
    try expectParses("UPDATE t1 SET a = 1, b = 'changed' WHERE id = 10;", 1);
    try expectParses("DELETE FROM t1 WHERE id = 10;", 1);
}

test "e2e: DDL" {
    try expectParses(
        "CREATE TABLE users (" ++
            "id INT PRIMARY KEY, " ++
            "name VARCHAR(255) NOT NULL, " ++
            "email VARCHAR(255) UNIQUE, " ++
            "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP" ++
            ");",
        1,
    );
    try expectParses("CREATE INDEX ix_name ON users (name);", 1);
    try expectParses("CREATE UNIQUE INDEX ix_email ON users (email);", 1);
    try expectParses("DROP TABLE IF EXISTS users;", 1);
    try expectParses("DROP INDEX ix_name ON users;", 1);
    try expectParses("ALTER TABLE users ADD COLUMN age INT;", 1);
    try expectParses("ALTER TABLE users DROP COLUMN age;", 1);
    try expectParses("ALTER TABLE users MODIFY COLUMN name VARCHAR(512);", 1);
    try expectParses("CREATE VIEW active_users AS SELECT * FROM users WHERE active = 1;", 1);
    try expectParses("DROP VIEW IF EXISTS active_users;", 1);
}

test "e2e: set operations" {
    try expectParses("SELECT id FROM t1 UNION SELECT id FROM t2;", 1);
    try expectParses("SELECT id FROM t1 UNION ALL SELECT id FROM t2;", 1);
    try expectParses("SELECT id FROM t1 INTERSECT SELECT id FROM t2;", 1);
    try expectParses("SELECT id FROM t1 EXCEPT SELECT id FROM t2;", 1);
}

test "e2e: multi-statement" {
    try expectParses(
        "CREATE TABLE t1 (id INT PRIMARY KEY, val TEXT); " ++
            "INSERT INTO t1 VALUES (1, 'hello'); " ++
            "SELECT * FROM t1; " ++
            "DROP TABLE t1;",
        4,
    );
}

// ---------------------------------------------------------------------------
// E2E: MySQL-specific
// ---------------------------------------------------------------------------

test "e2e: MySQL index hints" {
    try expectParsesMysql("SELECT * FROM t1 FORCE INDEX (ix_foo) WHERE id > 10;", 1);
    try expectParsesMysql("SELECT * FROM t1 USE INDEX (ix_a, ix_b) WHERE a = 1;", 1);
    try expectParsesMysql("SELECT * FROM t1 IGNORE INDEX (ix_foo) WHERE id > 10;", 1);
}

test "e2e: MySQL tuple IN subquery" {
    try expectParsesMysql("SELECT * FROM t1 WHERE (id, val) IN (SELECT id, val FROM t2);", 1);
}

test "e2e: MySQL INSERT variants" {
    try expectParsesMysql("INSERT INTO t1 (a, b) VALUES (1, 2) ON DUPLICATE KEY UPDATE b = VALUES(b);", 1);
    try expectParsesMysql("INSERT IGNORE INTO t1 (a) VALUES (1);", 1);
    try expectParsesMysql("REPLACE INTO t1 (a, b) VALUES (1, 2);", 1);
}

test "e2e: MySQL SHOW statements" {
    try expectParsesMysql("SHOW TABLES;", 1);
    try expectParsesMysql("SHOW COLUMNS FROM t1;", 1);
    try expectParsesMysql("SHOW CREATE TABLE t1;", 1);
    try expectParsesMysql("SHOW DATABASES;", 1);
}

test "e2e: MySQL LOCK/UNLOCK" {
    try expectParsesMysql("LOCK TABLES t1 WRITE, t2 READ;", 1);
    try expectParsesMysql("UNLOCK TABLES;", 1);
}

test "e2e: MySQL DIV and MOD" {
    try expectParsesMysql("SELECT 10 DIV 3;", 1);
    try expectParsesMysql("SELECT 10 MOD 3;", 1);
}

test "e2e: MySQL UNSIGNED, ENUM, SET types" {
    try expectParsesMysql(
        "CREATE TABLE t1 (" ++
            "id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, " ++
            "status ENUM('active', 'inactive', 'pending') DEFAULT 'pending', " ++
            "tags SET('a', 'b', 'c')" ++
            ");",
        1,
    );
}

test "e2e: MySQL variables" {
    try expectParsesMysql("SELECT @aurora_server_id AS srv_id;", 1);
    try expectParsesMysql("SELECT @@server_id AS sid;", 1);
    try expectParsesMysql("SELECT @@global.server_id AS sid;", 1);
    try expectParsesMysql("SELECT @@session.wait_timeout AS wt;", 1);
    try expectParsesMysql("SELECT @@hostname AS h;", 1);
}

test "e2e: MySQL variables in complex query" {
    try expectParsesMysql(
        "select t.* from (select b.uuid, b.name, c.domain, u.email as user_email, " ++
            "current_timestamp() as cur_ts, @aurora_server_id as srv_id " ++
            "from booking b join tripactions.company c on b.company_uuid = c.uuid " ++
            "join user u on c.uuid = u.company_uuid " ++
            "where c.uuid = 'foo' and b.type in ('train', 'air')) t limit 50;",
        1,
    );
    try expectParsesMysql(
        "select t.* from (select b.uuid, @@global.server_id as srv_id " ++
            "from booking b join user u on b.id = u.id " ++
            "where b.type in ('train', 'air')) t limit 50, 10;",
        1,
    );
}

// ---------------------------------------------------------------------------
// E2E: Error cases
// ---------------------------------------------------------------------------

test "e2e: error cases produce ParseFailed" {
    // Malformed SQL should fail to parse.
    const bad_queries = [_][]const u8{
        "SELECT * FROM;",
        "INSERT INTO;",
        "CREATE TABLE;",
        "SELECT * FROM t1 WHERE;",
    };
    for (bad_queries) |sql| {
        var result = parseStmts(sql);
        if (result) |*r| {
            r.arena.deinit();
            return error.TestFailed; // Should not have parsed
        } else |_| {
            // Expected error
        }
    }
}

// ---------------------------------------------------------------------------
// E2E: Edge cases
// ---------------------------------------------------------------------------

test "edge: empty input produces 0 statements" {
    try expectParses("", 0);
}

test "edge: whitespace-only input produces 0 statements" {
    try expectParses("   \n\t  ", 0);
}

test "edge: deeply nested expressions" {
    try expectParses("SELECT (((((1 + 2)))));", 1);
}

test "edge: long identifier" {
    // Build a 255-character identifier at comptime.
    const long_id = "a" ** 255;
    const sql = "SELECT " ++ long_id ++ " FROM t;";
    try expectParses(sql, 1);
}

test "edge: multiple semicolons between statements" {
    // Empty statement between semicolons should be tolerated.
    try expectParses("SELECT 1;; SELECT 2;", 2);
}

test "edge: trailing semicolons" {
    try expectParses("SELECT 1;;;", 1);
}

test "edge: string with SQL-style escape" {
    try expectParses("SELECT 'it''s a test';", 1);
}

test "edge: numeric edge cases" {
    try expectParses("SELECT 0, 123456789012345, 1.23e10, .5;", 1);
}

test "edge: NULL operations" {
    try expectParses("SELECT NULL IS NULL, NULL IS NOT NULL, NULL = NULL;", 1);
}

test "edge: nested subquery depth" {
    try expectParses("SELECT * FROM (SELECT * FROM (SELECT 1) AS a) AS b;", 1);
}

test "edge: CASE expression" {
    try expectParses(
        "SELECT CASE WHEN a > 1 THEN 'yes' WHEN a = 0 THEN 'zero' ELSE 'no' END FROM t;",
        1,
    );
}

test "edge: CAST expression" {
    try expectParses("SELECT CAST(x AS INT), CAST(y AS VARCHAR(255)) FROM t;", 1);
}

test "edge: multiple aliases" {
    // Double-quoted identifier as alias (Generic dialect supports it).
    try expectParses("SELECT a AS x, b y, c AS \"Z\" FROM t1 AS t;", 1);
}

test "edge: recursion limit on deeply nested subqueries" {
    // Build a query with 60 levels of nested subqueries, exceeding MAX_RECURSION_DEPTH (50).
    const allocator = std.testing.allocator;
    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(allocator);
    const depth = 60;
    for (0..depth) |_| try sql_buf.appendSlice(allocator, "SELECT (");
    try sql_buf.appendSlice(allocator, "SELECT 1");
    for (0..depth) |_| try sql_buf.appendSlice(allocator, ")");
    try sql_buf.append(allocator, ';');
    var result = parseStmts(sql_buf.items);
    if (result) |*r| {
        r.arena.deinit();
        return error.TestFailed; // Should have hit recursion limit
    } else |_| {
        // Expected error (RecursionLimit)
    }
}

test "edge: SELECT FROM produces error" {
    var result = parseStmts("SELECT FROM;");
    if (result) |*r| {
        r.arena.deinit();
        return error.TestFailed; // Should not have parsed
    } else |_| {
        // Expected error (ParseFailed)
    }
}

// ---------------------------------------------------------------------------
// Error message quality tests
// ---------------------------------------------------------------------------

/// Parse SQL expecting failure, verify the error message contains the
/// expected substring and the location matches.
fn expectErrorContains(sql: []const u8, expected_substr: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const TokMod = tokenizer_mod.Tokenizer;
    var tok = TokMod.init(.Generic, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);
    var parser = Parser.init(a, Dialect.generic, tokens);
    if (parser.parseStatements()) |_| {
        std.debug.print("\nExpected parse failure for: '{s}'\n", .{sql});
        return error.TestUnexpectedResult;
    } else |_| {
        if (parser.error_message.len == 0) {
            std.debug.print("\nNo error message for: '{s}'\n", .{sql});
            return error.TestExpectedEqual;
        }
        if (std.mem.indexOf(u8, parser.error_message, expected_substr) == null) {
            std.debug.print("\nExpected error to contain: '{s}'\nActual error: '{s}'\nSQL: '{s}'\n", .{ expected_substr, parser.error_message, sql });
            return error.TestExpectedEqual;
        }
    }
}

/// Like expectErrorContains but also checks line and column.
fn expectErrorAt(sql: []const u8, expected_substr: []const u8, expected_line: u64, expected_col: u64) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const TokMod = tokenizer_mod.Tokenizer;
    var tok = TokMod.init(.Generic, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);
    var parser = Parser.init(a, Dialect.generic, tokens);
    if (parser.parseStatements()) |_| {
        std.debug.print("\nExpected parse failure for: '{s}'\n", .{sql});
        return error.TestUnexpectedResult;
    } else |_| {
        if (parser.error_message.len == 0) {
            std.debug.print("\nNo error message for: '{s}'\n", .{sql});
            return error.TestExpectedEqual;
        }
        if (std.mem.indexOf(u8, parser.error_message, expected_substr) == null) {
            std.debug.print("\nExpected error to contain: '{s}'\nActual error: '{s}'\nSQL: '{s}'\n", .{ expected_substr, parser.error_message, sql });
            return error.TestExpectedEqual;
        }
        try std.testing.expectEqual(expected_line, parser.error_location.line);
        try std.testing.expectEqual(expected_col, parser.error_location.column);
    }
}

test "error message: SELECT * FROM; reports identifier expected" {
    try expectErrorContains("SELECT * FROM;", "Expected: an identifier");
}

test "error message: SELECT ,; reports expression expected" {
    try expectErrorContains("SELECT ,;", "Expected: an expression");
}

test "error message: CREATE TABLE; reports identifier expected" {
    try expectErrorContains("CREATE TABLE;", "Expected: an identifier");
}

test "error message: INSERT INTO; reports identifier expected" {
    try expectErrorContains("INSERT INTO;", "Expected: an identifier");
}

test "error message: SELECT * FROM t1 WHERE; reports expression expected" {
    try expectErrorAt("SELECT * FROM t1 WHERE;", "Expected: an expression", 1, 23);
}

test "error message: SELECT FROM; reports expression expected" {
    try expectErrorContains("SELECT FROM;", "Expected: an expression");
}

test "error message: multiline error has correct line number" {
    try expectErrorAt("SELECT *\nFROM t1\nWHERE;", "Expected: an expression", 3, 6);
}

test "error message: unknown statement keyword" {
    try expectErrorContains("FROBNICATE;", "Expected: a SQL statement");
}

test "error message: error includes found token" {
    try expectErrorContains("SELECT * FROM;", "found: ;");
}

test "error message: error includes found semicolon" {
    try expectErrorContains("SELECT FROM;", "found: ;");
}

test "error message: error includes found keyword name" {
    try expectErrorContains("DROP FROM;", "found: FROM");
}
