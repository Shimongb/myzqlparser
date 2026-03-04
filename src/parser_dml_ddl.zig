const std = @import("std");
const ast = @import("ast.zig");
const ast_ddl = @import("ast_ddl.zig");
const ast_dml = @import("ast_dml.zig");
const ast_query = @import("ast_query.zig");

const Ident = ast.Ident;
const ObjectName = ast.ObjectName;
const Expr = ast.Expr;
const DataType = ast.DataType;
const Value = ast.Value;
const Query = ast_query.Query;
const Values = ast_query.Values;
const SetExpr = ast_query.SetExpr;
const TableWithJoins = ast_query.TableWithJoins;
const Statement = ast.Statement;
const Assignment = ast.Assignment;

const Insert = ast_dml.Insert;
const InsertSource = ast_dml.InsertSource;
const MysqlInsertPriority = ast_dml.MysqlInsertPriority;
const Update = ast_dml.Update;
const Delete = ast_dml.Delete;

const CreateTable = ast_ddl.CreateTable;
const CreateIndex = ast_ddl.CreateIndex;
const CreateView = ast_ddl.CreateView;
const AlterTable = ast_ddl.AlterTable;
const AlterTableOperation = ast_ddl.AlterTableOperation;
const AlterColumnOperation = ast_ddl.AlterColumnOperation;
const ColumnDef = ast_ddl.ColumnDef;
const ColumnOption = ast_ddl.ColumnOption;
const ColumnOptionDef = ast_ddl.ColumnOptionDef;
const TableConstraint = ast_ddl.TableConstraint;
const TableOption = ast_ddl.TableOption;
const Drop = ast_ddl.Drop;
const DropObjectType = ast_ddl.DropObjectType;
const DropBehavior = ast_ddl.DropBehavior;
const ReferentialAction = ast_ddl.ReferentialAction;
const IndexColumn = ast_ddl.IndexColumn;
const MySQLColumnPosition = ast_ddl.MySQLColumnPosition;
const ForeignKeyConstraint = ast_ddl.ForeignKeyConstraint;

// Parser is imported from parser.zig.
pub const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const Keyword = @import("keywords.zig").Keyword;
const TokenWithSpan = @import("tokenizer.zig").TokenWithSpan;

// ============================================================================
// INSERT
// ============================================================================

/// Parse an INSERT statement. Called after the INSERT keyword has been consumed.
pub fn parseInsert(p: *Parser, kw_tok: TokenWithSpan) ParseError!Statement {
    // Optional MySQL priority modifier.
    const priority: ?MysqlInsertPriority = if (p.dialect.isMysql() or p.dialect.kind == .generic) blk: {
        if (p.parseKeyword(.LOW_PRIORITY)) break :blk .low_priority;
        if (p.parseKeyword(.DELAYED)) break :blk .delayed;
        if (p.parseKeyword(.HIGH_PRIORITY)) break :blk .high_priority;
        break :blk null;
    } else null;

    // INSERT IGNORE (MySQL/Generic).
    const ignore = (p.dialect.isMysql() or p.dialect.kind == .generic) and p.parseKeyword(.IGNORE);

    // INTO is optional in some dialects.
    const into = p.parseKeyword(.INTO);

    // Table name.
    const table = try p.parseObjectName();

    // Optional table alias.
    const table_alias: ?Ident = if (p.parseKeyword(.AS))
        try p.parseIdent()
    else
        null;

    // Column list.
    const columns: []const Ident = if (p.consumeToken(.LParen)) blk: {
        if (p.consumeToken(.RParen)) break :blk &.{};
        const cols = try p.parseCommaSeparated(Ident, Parser.parseIdentFn);
        try p.expectToken(.RParen);
        break :blk cols;
    } else &.{};

    // Parse source: DEFAULT VALUES, SET assignments, or VALUES/SELECT query.
    const source: InsertSource = if (p.parseKeywords(&.{ .DEFAULT, .VALUES }))
        .default_values
    else if (p.dialect.supportsInsertSet() and p.parseKeyword(.SET))
        .{ .assignments = try p.parseCommaSeparated(Assignment, Parser.parseAssignmentFn) }
    else blk: {
        const query = try p.parseQuery();
        const qptr = try p.allocator.create(Query);
        qptr.* = query;
        break :blk .{ .select = qptr };
    };

    // ON DUPLICATE KEY UPDATE (MySQL).
    const on_dup: ?[]const Assignment = if (p.parseKeyword(.ON)) blk: {
        try p.expectKeyword(.DUPLICATE);
        try p.expectKeyword(.KEY);
        try p.expectKeyword(.UPDATE);
        break :blk try p.parseCommaSeparated(Assignment, Parser.parseAssignmentFn);
    } else null;

    return .{ .insert = .{
        .token = kw_tok,
        .replace_into = false,
        .ignore = ignore,
        .into = into,
        .table = table,
        .table_alias = table_alias,
        .columns = columns,
        .source = source,
        .on_duplicate_key_update = on_dup,
        .priority = priority,
    } };
}

/// Parse a REPLACE statement (MySQL). Called after the REPLACE keyword has been consumed.
pub fn parseReplace(p: *Parser, kw_tok: TokenWithSpan) ParseError!Statement {
    var stmt = try parseInsert(p, kw_tok);
    switch (stmt) {
        .insert => |*ins| {
            ins.replace_into = true;
        },
        else => {},
    }
    return stmt;
}

// ============================================================================
// UPDATE
// ============================================================================

/// Parse an UPDATE statement. Called after the UPDATE keyword has been consumed.
pub fn parseUpdate(p: *Parser, kw_tok: TokenWithSpan) ParseError!Statement {
    // Table reference(s).
    const table = try p.parseTableWithJoinsList();

    // SET assignments.
    try p.expectKeyword(.SET);
    const assignments = try p.parseCommaSeparated(Assignment, Parser.parseAssignmentFn);

    // Optional FROM (not standard MySQL but supported by Generic).
    const from: ?[]const TableWithJoins = if (p.parseKeyword(.FROM))
        try p.parseTableWithJoinsList()
    else
        null;

    // WHERE clause.
    const selection: ?Expr = if (p.parseKeyword(.WHERE))
        try p.parseExpr()
    else
        null;

    // ORDER BY (MySQL extension).
    const order_by: []const ast.OrderByExpr = if (p.parseKeywords(&.{ .ORDER, .BY }))
        try p.parseCommaSeparated(ast.OrderByExpr, Parser.parseOrderByExprFn)
    else
        &.{};

    // LIMIT (MySQL extension).
    const limit: ?Expr = if (p.parseKeyword(.LIMIT))
        try p.parseExpr()
    else
        null;

    return .{ .update = .{
        .token = kw_tok,
        .table = table,
        .assignments = assignments,
        .from = from,
        .selection = selection,
        .order_by = order_by,
        .limit = limit,
    } };
}

// ============================================================================
// DELETE
// ============================================================================

/// Parse a DELETE statement. Called after the DELETE keyword has been consumed.
pub fn parseDelete(p: *Parser, kw_tok: TokenWithSpan) ParseError!Statement {
    // Multi-table DELETE: DELETE t1, t2 FROM ...
    // Or single-table: DELETE FROM table WHERE ...
    var tables: []const ObjectName = &.{};
    if (!p.parseKeyword(.FROM)) {
        // Multi-table syntax: DELETE t1, t2 FROM ...
        tables = try p.parseCommaSeparated(ObjectName, Parser.parseObjectNameFn);
        try p.expectKeyword(.FROM);
    }

    // FROM table(s).
    const from = try p.parseTableWithJoinsList();

    // USING clause (PostgreSQL/Generic).
    const using: ?[]const TableWithJoins = if (p.parseKeyword(.USING))
        try p.parseTableWithJoinsList()
    else
        null;

    // WHERE clause.
    const selection: ?Expr = if (p.parseKeyword(.WHERE))
        try p.parseExpr()
    else
        null;

    // ORDER BY (MySQL extension).
    const order_by: []const ast.OrderByExpr = if (p.parseKeywords(&.{ .ORDER, .BY }))
        try p.parseCommaSeparated(ast.OrderByExpr, Parser.parseOrderByExprFn)
    else
        &.{};

    // LIMIT (MySQL extension).
    const limit: ?Expr = if (p.parseKeyword(.LIMIT))
        try p.parseExpr()
    else
        null;

    return .{ .delete = .{
        .token = kw_tok,
        .tables = tables,
        .from = from,
        .using = using,
        .selection = selection,
        .order_by = order_by,
        .limit = limit,
    } };
}

// ============================================================================
// CREATE (dispatcher)
// ============================================================================

/// Parse a CREATE statement. Called after the CREATE keyword has been consumed.
pub fn parseCreate(p: *Parser) ParseError!Statement {
    const or_replace = p.parseKeywords(&.{ .OR, .REPLACE });

    // LOCAL / GLOBAL / TEMPORARY modifiers.
    _ = p.parseKeyword(.LOCAL);
    _ = p.parseKeyword(.GLOBAL);
    const temporary = p.parseKeyword(.TEMPORARY) or p.parseKeyword(.TEMP);

    if (p.parseKeyword(.TABLE)) {
        return parseCreateTable(p, or_replace, temporary);
    } else if (p.peekIsKeyword(.VIEW) or p.peekIsKeyword(.MATERIALIZED)) {
        return parseCreateView(p, or_replace);
    } else if (p.parseKeyword(.INDEX)) {
        return parseCreateIndex(p, false);
    } else if (p.parseKeywords(&.{ .UNIQUE, .INDEX })) {
        return parseCreateIndex(p, true);
    } else {
        return p.expected("TABLE, VIEW, or INDEX after CREATE", p.peekToken());
    }
}

// ============================================================================
// CREATE TABLE
// ============================================================================

/// Parse a CREATE TABLE statement.
fn parseCreateTable(p: *Parser, or_replace: bool, temporary: bool) ParseError!Statement {
    const if_not_exists = p.parseKeywords(&.{ .IF, .NOT, .EXISTS });
    const table_name = try p.parseObjectName();

    // LIKE other_table.
    const like: ?ObjectName = if (p.parseKeyword(.LIKE))
        try p.parseObjectName()
    else
        null;

    // Column definitions and constraints: (col1 TYPE opts, CONSTRAINT ...)
    const columns_result = try parseColumns(p);

    // Table options: ENGINE=InnoDB, CHARSET=utf8mb4, etc.
    const table_options = try parseTableOptions(p);

    // ON COMMIT behavior for temp tables.
    const on_commit = parseOnCommit(p);

    // AS SELECT ... (CREATE TABLE AS SELECT).
    const as_select: ?*const Query = if (p.parseKeyword(.AS)) blk: {
        const q = try p.parseQuery();
        const qptr = try p.allocator.create(Query);
        qptr.* = q;
        break :blk qptr;
    } else if (p.dialect.supportsCreateTableSelect() and p.peekIsKeyword(.SELECT)) blk: {
        const q = try p.parseQuery();
        const qptr = try p.allocator.create(Query);
        qptr.* = q;
        break :blk qptr;
    } else null;

    // Table-level COMMENT from options.
    const comment: ?[]const u8 = for (table_options) |opt| {
        switch (opt) {
            .comment => |c| break c,
            else => {},
        }
    } else null;

    return .{ .create_table = .{
        .or_replace = or_replace,
        .temporary = temporary,
        .if_not_exists = if_not_exists,
        .name = table_name,
        .columns = columns_result.columns,
        .constraints = columns_result.constraints,
        .table_options = table_options,
        .on_commit = on_commit,
        .like = like,
        .as_select = as_select,
        .comment = comment,
    } };
}

/// Result of parsing column definitions and table constraints.
const ColumnsResult = struct {
    columns: []const ColumnDef,
    constraints: []const TableConstraint,
};

/// Parse the parenthesized column definition and constraint list.
fn parseColumns(p: *Parser) ParseError!ColumnsResult {
    if (!p.consumeToken(.LParen)) {
        return .{ .columns = &.{}, .constraints = &.{} };
    }
    if (p.consumeToken(.RParen)) {
        return .{ .columns = &.{}, .constraints = &.{} };
    }

    const alloc = p.allocator;
    var columns: std.ArrayList(ColumnDef) = .empty;
    // Pre-size for typical column counts in CREATE TABLE.
    try columns.ensureTotalCapacity(alloc, 8);
    var constraints: std.ArrayList(TableConstraint) = .empty;
    // Pre-size for typical constraint counts.
    try constraints.ensureTotalCapacity(alloc, 4);

    while (true) {
        // Try parsing a table constraint first.
        if (try parseOptionalTableConstraint(p)) |constraint| {
            try constraints.append(alloc, constraint);
        } else {
            // Parse a column definition.
            const col = try parseColumnDef(p);
            try columns.append(alloc, col);
        }

        if (!p.consumeToken(.Comma)) {
            try p.expectToken(.RParen);
            break;
        }
        // Allow trailing comma before RParen.
        if (p.consumeToken(.RParen)) break;
    }

    return .{
        .columns = try columns.toOwnedSlice(alloc),
        .constraints = try constraints.toOwnedSlice(alloc),
    };
}

/// Parse a single column definition: name TYPE [options...].
fn parseColumnDef(p: *Parser) ParseError!ColumnDef {
    const alloc = p.allocator;
    const name = try p.parseIdent();
    const data_type = try p.parseDataType();

    var options: std.ArrayList(ColumnOptionDef) = .empty;
    // Pre-size for typical column option counts (NOT NULL, DEFAULT, etc.).
    try options.ensureTotalCapacity(alloc, 4);
    while (true) {
        if (p.parseKeyword(.CONSTRAINT)) {
            // Named constraint: CONSTRAINT name <option>.
            const constraint_name = try p.parseIdent();
            if (try parseOptionalColumnOption(p)) |option| {
                try options.append(alloc, .{ .name = constraint_name, .option = option });
            } else {
                return p.expected("a column option after CONSTRAINT name", p.peekToken());
            }
        } else if (try parseOptionalColumnOption(p)) |option| {
            try options.append(alloc, .{ .name = null, .option = option });
        } else {
            break;
        }
    }

    return .{
        .name = name,
        .data_type = data_type,
        .options = try options.toOwnedSlice(alloc),
    };
}

/// Try to parse a single column option. Returns null if no option is found.
fn parseOptionalColumnOption(p: *Parser) ParseError!?ColumnOption {
    if (p.parseKeywords(&.{ .CHARACTER, .SET })) {
        return .{ .character_set = try p.parseObjectName() };
    } else if (p.parseKeyword(.COLLATE)) {
        return .{ .collate = try p.parseObjectName() };
    } else if (p.parseKeywords(&.{ .NOT, .NULL })) {
        return .not_null;
    } else if (p.parseKeyword(.COMMENT)) {
        return .{ .comment = try p.parseStringLiteral() };
    } else if (p.parseKeyword(.NULL)) {
        return .null;
    } else if (p.parseKeyword(.DEFAULT)) {
        return .{ .default = try p.parseExpr() };
    } else if (p.parseKeywords(&.{ .PRIMARY, .KEY })) {
        return .primary_key;
    } else if (p.parseKeyword(.UNIQUE)) {
        return .unique;
    } else if (p.parseKeyword(.REFERENCES)) {
        return .{ .foreign_key = try parseForeignKeyReference(p) };
    } else if (p.parseKeyword(.CHECK)) {
        try p.expectToken(.LParen);
        const expr = try p.parseExpr();
        try p.expectToken(.RParen);
        return .{ .check = expr };
    } else if (p.parseKeyword(.AUTO_INCREMENT)) {
        return .auto_increment;
    } else if (p.parseKeywords(&.{ .ON, .UPDATE })) {
        return .{ .on_update = try p.parseExpr() };
    } else if (p.parseKeyword(.INVISIBLE)) {
        return .invisible;
    } else {
        return null;
    }
}

/// Parse REFERENCES table [(cols)] [ON DELETE action] [ON UPDATE action].
fn parseForeignKeyReference(p: *Parser) ParseError!ForeignKeyConstraint {
    const foreign_table = try p.parseObjectName();

    // Optional referenced column list.
    const referred_columns: []const Ident = if (p.consumeToken(.LParen)) blk: {
        if (p.consumeToken(.RParen)) break :blk &.{};
        const cols = try p.parseCommaSeparated(Ident, Parser.parseIdentFn);
        try p.expectToken(.RParen);
        break :blk cols;
    } else &.{};

    var on_delete: ?ReferentialAction = null;
    var on_update: ?ReferentialAction = null;

    // Parse ON DELETE / ON UPDATE in any order.
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        if (on_delete == null and p.parseKeywords(&.{ .ON, .DELETE })) {
            on_delete = try parseReferentialAction(p);
        } else if (on_update == null and p.parseKeywords(&.{ .ON, .UPDATE })) {
            on_update = try parseReferentialAction(p);
        } else {
            break;
        }
    }

    return .{
        .foreign_table = foreign_table,
        .referred_columns = referred_columns,
        .on_delete = on_delete,
        .on_update = on_update,
    };
}

/// Parse a referential action: CASCADE, SET NULL, SET DEFAULT, RESTRICT, NO ACTION.
fn parseReferentialAction(p: *Parser) ParseError!ReferentialAction {
    if (p.parseKeyword(.CASCADE)) return .cascade;
    if (p.parseKeyword(.RESTRICT)) return .restrict;
    if (p.parseKeywords(&.{ .SET, .NULL })) return .set_null;
    if (p.parseKeywords(&.{ .SET, .DEFAULT })) return .set_default;
    if (p.parseKeywords(&.{ .NO, .ACTION })) return .no_action;
    return p.expected("CASCADE, RESTRICT, SET NULL, SET DEFAULT, or NO ACTION", p.peekToken());
}

/// Try to parse a table-level constraint. Returns null if none found.
fn parseOptionalTableConstraint(p: *Parser) ParseError!?TableConstraint {
    const alloc = p.allocator;

    // Optional CONSTRAINT [name].
    const saved_idx = p.index;
    const name: ?Ident = if (p.parseKeyword(.CONSTRAINT)) blk: {
        // MySQL allows CONSTRAINT without a name if the next word is a constraint keyword.
        if (p.dialect.supportsConstraintKeywordWithoutName() and
            (p.peekIsKeyword(.CHECK) or p.peekIsKeyword(.PRIMARY) or
            p.peekIsKeyword(.UNIQUE) or p.peekIsKeyword(.FOREIGN)))
        {
            break :blk null;
        }
        break :blk try p.parseIdent();
    } else null;

    if (p.parseKeyword(.UNIQUE)) {
        // UNIQUE [KEY|INDEX] [name] (cols)
        _ = p.parseKeyword(.KEY) or p.parseKeyword(.INDEX);
        _ = parseOptionalUnquotedIdent(p);
        const cols = try parseParenthesizedIdentList(p);
        return .{ .unique = .{
            .name = name,
            .columns = cols,
        } };
    } else if (p.parseKeyword(.PRIMARY)) {
        // PRIMARY KEY [name] (cols)
        try p.expectKeyword(.KEY);
        const cols = try parseParenthesizedIdentList(p);
        return .{ .primary_key = .{
            .name = name,
            .columns = cols,
        } };
    } else if (p.parseKeyword(.FOREIGN)) {
        // FOREIGN KEY [name] (cols) REFERENCES table (cols) [ON ...]
        try p.expectKeyword(.KEY);
        // Optional index name (MySQL).
        _ = parseOptionalUnquotedIdent(p);
        const cols = try parseParenthesizedIdentList(p);
        try p.expectKeyword(.REFERENCES);
        const fk_ref = try parseForeignKeyReference(p);
        return .{ .foreign_key = .{
            .name = name,
            .columns = cols,
            .foreign_table = fk_ref.foreign_table,
            .referred_columns = fk_ref.referred_columns,
            .on_delete = fk_ref.on_delete,
            .on_update = fk_ref.on_update,
        } };
    } else if (p.parseKeyword(.CHECK)) {
        // CHECK (expr)
        try p.expectToken(.LParen);
        const expr = try p.parseExpr();
        try p.expectToken(.RParen);
        return .{ .check = .{
            .name = name,
            .expr = expr,
        } };
    } else if (p.parseKeyword(.INDEX) or p.parseKeyword(.KEY)) {
        if (name == null) {
            // INDEX/KEY [name] (cols) -- MySQL
            _ = parseOptionalUnquotedIdent(p);
            const cols = try parseParenthesizedIdentList(p);
            return .{ .index = .{
                .name = null,
                .columns = cols,
            } };
        }
    } else if (p.parseKeyword(.FULLTEXT)) {
        // FULLTEXT [INDEX|KEY] [name] (cols) -- MySQL
        _ = p.parseKeyword(.INDEX) or p.parseKeyword(.KEY);
        _ = parseOptionalUnquotedIdent(p);
        const cols = try parseParenthesizedIdentList(p);
        return .{ .fulltext = .{
            .name = name,
            .columns = cols,
        } };
    } else if (p.parseKeyword(.SPATIAL)) {
        // SPATIAL [INDEX|KEY] [name] (cols) -- MySQL
        _ = p.parseKeyword(.INDEX) or p.parseKeyword(.KEY);
        _ = parseOptionalUnquotedIdent(p);
        const cols = try parseParenthesizedIdentList(p);
        return .{ .spatial = .{
            .name = name,
            .columns = cols,
        } };
    }

    // Not a constraint -- rewind if we consumed CONSTRAINT.
    if (name != null) {
        p.index = saved_idx;
    }
    _ = alloc;
    return null;
}

/// Try to parse an optional identifier (not a keyword). Returns null if the
/// next token is not a plain identifier or if it looks like a keyword that
/// starts a column list or constraint.
fn parseOptionalUnquotedIdent(p: *Parser) ?Ident {
    const tok = p.peekToken();
    switch (tok.token) {
        .Word => |w| {
            // If this word is a keyword that starts a constraint or column list,
            // don't consume it.
            switch (w.keyword) {
                .NoKeyword => {
                    const ident_tok = p.nextToken();
                    return Ident{ .value = w.value, .quote_style = w.quote_style, .span = ident_tok.span };
                },
                else => return null,
            }
        },
        else => return null,
    }
}

/// Parse a parenthesized comma-separated list of identifiers: (col1, col2, ...).
fn parseParenthesizedIdentList(p: *Parser) ParseError![]const Ident {
    try p.expectToken(.LParen);
    const list = try p.parseCommaSeparated(Ident, Parser.parseIdentFn);
    try p.expectToken(.RParen);
    return list;
}

/// Parse MySQL table options after the column list.
fn parseTableOptions(p: *Parser) ParseError![]const TableOption {
    const alloc = p.allocator;
    var opts: std.ArrayList(TableOption) = .empty;

    while (true) {
        // Consume optional comma between options.
        _ = p.consumeToken(.Comma);

        if (p.parseKeyword(.ENGINE)) {
            _ = p.consumeToken(.Eq);
            const val = try p.parseIdentifierString();
            try opts.append(alloc, .{ .engine = val });
        } else if (p.parseKeywords(&.{ .DEFAULT, .CHARSET }) or
            p.parseKeywords(&.{ .CHARACTER, .SET }) or
            p.parseKeyword(.CHARSET))
        {
            _ = p.consumeToken(.Eq);
            const val = try p.parseIdentifierString();
            try opts.append(alloc, .{ .charset = val });
        } else if (p.parseKeyword(.COLLATE)) {
            _ = p.consumeToken(.Eq);
            const val = try p.parseIdentifierString();
            try opts.append(alloc, .{ .collate = val });
        } else if (p.parseKeyword(.COMMENT)) {
            _ = p.consumeToken(.Eq);
            const val = try p.parseStringLiteral();
            try opts.append(alloc, .{ .comment = val });
        } else if (p.parseKeyword(.AUTO_INCREMENT)) {
            _ = p.consumeToken(.Eq);
            const val = try p.parseLiteralUint();
            try opts.append(alloc, .{ .auto_increment = val });
        } else {
            break;
        }
    }

    return opts.toOwnedSlice(alloc);
}

/// Parse optional ON COMMIT behavior for temporary tables.
fn parseOnCommit(p: *Parser) ?ast_ddl.OnCommit {
    if (!p.parseKeywords(&.{ .ON, .COMMIT })) return null;
    if (p.parseKeywords(&.{ .DELETE, .ROWS })) return .delete_rows;
    if (p.parseKeywords(&.{ .PRESERVE, .ROWS })) return .preserve_rows;
    if (p.parseKeyword(.DROP)) return .drop;
    return null;
}

// ============================================================================
// CREATE INDEX
// ============================================================================

/// Parse a CREATE [UNIQUE] INDEX statement.
fn parseCreateIndex(p: *Parser, unique: bool) ParseError!Statement {
    const if_not_exists = p.parseKeywords(&.{ .IF, .NOT, .EXISTS });

    // Index name.
    const index_name: ?ObjectName = if (if_not_exists or !p.peekIsKeyword(.ON))
        try p.parseObjectName()
    else
        null;

    // USING index_type (MySQL, before ON).
    var using: ?[]const u8 = parseOptionalUsing(p);

    try p.expectKeyword(.ON);
    const table_name = try p.parseObjectName();

    // USING index_type (MySQL, after ON).
    if (using == null) {
        using = parseOptionalUsing(p);
    }

    // Index columns: (col1 [ASC|DESC], col2, ...).
    const columns = try parseIndexColumnList(p);

    return .{ .create_index = .{
        .if_not_exists = if_not_exists,
        .name = index_name,
        .unique = unique,
        .fulltext = false,
        .table_name = table_name,
        .columns = columns,
        .using = using,
    } };
}

/// Parse optional USING BTREE|HASH (MySQL).
fn parseOptionalUsing(p: *Parser) ?[]const u8 {
    if (p.parseKeyword(.USING)) {
        const tok = p.nextToken();
        switch (tok.token) {
            .Word => |w| return w.value,
            else => {
                p.prevToken();
                return null;
            },
        }
    }
    return null;
}

/// Parse a parenthesized index column list: (col1 [ASC|DESC], ...).
fn parseIndexColumnList(p: *Parser) ParseError![]const IndexColumn {
    const alloc = p.allocator;
    try p.expectToken(.LParen);
    var cols: std.ArrayList(IndexColumn) = .empty;

    while (true) {
        const col_expr = try p.parseExpr();
        const asc: ?bool = if (p.parseKeyword(.ASC))
            true
        else if (p.parseKeyword(.DESC))
            false
        else
            null;
        try cols.append(alloc, .{ .column = col_expr, .asc = asc });

        if (!p.consumeToken(.Comma)) break;
    }
    try p.expectToken(.RParen);
    return cols.toOwnedSlice(alloc);
}

// ============================================================================
// CREATE VIEW
// ============================================================================

/// Parse a CREATE [OR REPLACE] VIEW statement.
fn parseCreateView(p: *Parser, or_replace: bool) ParseError!Statement {
    _ = p.parseKeyword(.MATERIALIZED); // skip MATERIALIZED for now
    try p.expectKeyword(.VIEW);

    _ = p.parseKeywords(&.{ .IF, .NOT, .EXISTS });

    const name = try p.parseObjectName();

    // Optional column list.
    const columns: []const Ident = if (p.consumeToken(.LParen)) blk: {
        if (p.consumeToken(.RParen)) break :blk &.{};
        const cols = try p.parseCommaSeparated(Ident, Parser.parseIdentFn);
        try p.expectToken(.RParen);
        break :blk cols;
    } else &.{};

    try p.expectKeyword(.AS);
    const query = try p.parseQuery();
    const qptr = try p.allocator.create(Query);
    qptr.* = query;

    // WITH CHECK OPTION.
    const with_check_option = p.parseKeywords(&.{ .WITH, .CHECK, .OPTION });

    return .{ .create_view = .{
        .or_replace = or_replace,
        .name = name,
        .columns = columns,
        .query = qptr,
        .with_check_option = with_check_option,
    } };
}

// ============================================================================
// ALTER TABLE
// ============================================================================

/// Parse an ALTER TABLE statement. Called after ALTER TABLE has been consumed.
pub fn parseAlterTable(p: *Parser) ParseError!Statement {
    const if_exists = p.parseKeywords(&.{ .IF, .EXISTS });
    const table_name = try p.parseObjectName();

    // Parse comma-separated operations.
    const alloc = p.allocator;
    var ops: std.ArrayList(AlterTableOperation) = .empty;
    // Pre-size for typical ALTER TABLE operation counts.
    try ops.ensureTotalCapacity(alloc, 4);
    while (true) {
        const op = try parseAlterTableOperation(p);
        try ops.append(alloc, op);
        if (!p.consumeToken(.Comma)) break;
    }

    const end_tok = p.lastConsumedToken();
    return .{ .alter_table = .{
        .if_exists = if_exists,
        .name = table_name,
        .operations = try ops.toOwnedSlice(alloc),
        .end_token = end_tok,
    } };
}

/// Parse a single ALTER TABLE operation.
fn parseAlterTableOperation(p: *Parser) ParseError!AlterTableOperation {
    if (p.parseKeyword(.ADD)) {
        return parseAlterTableAdd(p);
    } else if (p.parseKeyword(.DROP)) {
        return parseAlterTableDrop(p);
    } else if (p.parseKeyword(.MODIFY)) {
        return parseAlterTableModify(p);
    } else if (p.parseKeyword(.CHANGE)) {
        return parseAlterTableChange(p);
    } else if (p.parseKeyword(.RENAME)) {
        return parseAlterTableRename(p);
    } else if (p.parseKeyword(.ALTER)) {
        return parseAlterTableAlterColumn(p);
    } else {
        return p.expected("ADD, DROP, MODIFY, CHANGE, RENAME, or ALTER after ALTER TABLE name", p.peekToken());
    }
}

/// ALTER TABLE ... ADD [COLUMN | CONSTRAINT].
fn parseAlterTableAdd(p: *Parser) ParseError!AlterTableOperation {
    // Try parsing a table constraint first.
    if (try parseOptionalTableConstraint(p)) |constraint| {
        return .{ .add_constraint = .{
            .constraint = constraint,
            .not_valid = p.parseKeywords(&.{ .NOT, .VALID }),
        } };
    }

    // ADD [COLUMN] [IF NOT EXISTS] column_def [FIRST | AFTER col].
    const column_keyword = p.parseKeyword(.COLUMN);
    const if_not_exists = p.parseKeywords(&.{ .IF, .NOT, .EXISTS });
    const column_def = try parseColumnDef(p);
    const column_position = parseColumnPosition(p);

    return .{ .add_column = .{
        .column_keyword = column_keyword,
        .if_not_exists = if_not_exists,
        .column_def = column_def,
        .column_position = column_position,
    } };
}

/// ALTER TABLE ... DROP [COLUMN | CONSTRAINT | PRIMARY KEY | INDEX].
fn parseAlterTableDrop(p: *Parser) ParseError!AlterTableOperation {
    if (p.parseKeyword(.CONSTRAINT)) {
        const if_exists = p.parseKeywords(&.{ .IF, .EXISTS });
        const name = try p.parseIdent();
        const drop_behavior = parseOptionalDropBehavior(p);
        return .{ .drop_constraint = .{
            .if_exists = if_exists,
            .name = name,
            .drop_behavior = drop_behavior,
        } };
    } else if (p.parseKeywords(&.{ .PRIMARY, .KEY })) {
        return .drop_primary_key;
    } else if (p.parseKeyword(.INDEX)) {
        return .{ .drop_index = try p.parseIdent() };
    } else {
        // DROP [COLUMN] [IF EXISTS] column_name.
        _ = p.parseKeyword(.COLUMN);
        const if_exists = p.parseKeywords(&.{ .IF, .EXISTS });
        const column_name = try p.parseIdent();
        const drop_behavior = parseOptionalDropBehavior(p);
        return .{ .drop_column = .{
            .column_name = column_name,
            .if_exists = if_exists,
            .drop_behavior = drop_behavior,
        } };
    }
}

/// ALTER TABLE ... MODIFY [COLUMN] col type [options] [FIRST | AFTER col].
fn parseAlterTableModify(p: *Parser) ParseError!AlterTableOperation {
    _ = p.parseKeyword(.COLUMN);
    const col_name = try p.parseIdent();
    const data_type = try p.parseDataType();

    const alloc = p.allocator;
    var options: std.ArrayList(ColumnOptionDef) = .empty;
    while (try parseOptionalColumnOption(p)) |option| {
        try options.append(alloc, .{ .name = null, .option = option });
    }

    const column_position = parseColumnPosition(p);

    return .{ .modify_column = .{
        .col_name = col_name,
        .data_type = data_type,
        .options = try options.toOwnedSlice(alloc),
        .column_position = column_position,
    } };
}

/// ALTER TABLE ... CHANGE [COLUMN] old_name new_name type [options] [FIRST | AFTER col].
fn parseAlterTableChange(p: *Parser) ParseError!AlterTableOperation {
    _ = p.parseKeyword(.COLUMN);
    const old_name = try p.parseIdent();
    const new_name = try p.parseIdent();
    const data_type = try p.parseDataType();

    const alloc = p.allocator;
    var options: std.ArrayList(ColumnOptionDef) = .empty;
    while (try parseOptionalColumnOption(p)) |option| {
        try options.append(alloc, .{ .name = null, .option = option });
    }

    const column_position = parseColumnPosition(p);

    return .{ .change_column = .{
        .old_name = old_name,
        .new_name = new_name,
        .data_type = data_type,
        .options = try options.toOwnedSlice(alloc),
        .column_position = column_position,
    } };
}

/// ALTER TABLE ... RENAME [TO name | COLUMN old TO new].
fn parseAlterTableRename(p: *Parser) ParseError!AlterTableOperation {
    if (p.parseKeyword(.TO)) {
        return .{ .rename_table = try p.parseObjectName() };
    } else {
        // RENAME [COLUMN] old TO new.
        _ = p.parseKeyword(.COLUMN);
        const old_column_name = try p.parseIdent();
        try p.expectKeyword(.TO);
        const new_column_name = try p.parseIdent();
        return .{ .rename_column = .{
            .old_column_name = old_column_name,
            .new_column_name = new_column_name,
        } };
    }
}

/// ALTER TABLE ... ALTER [COLUMN] col operation.
fn parseAlterTableAlterColumn(p: *Parser) ParseError!AlterTableOperation {
    _ = p.parseKeyword(.COLUMN);
    const column_name = try p.parseIdent();

    const op: AlterColumnOperation = if (p.parseKeywords(&.{ .SET, .NOT, .NULL }))
        .set_not_null
    else if (p.parseKeywords(&.{ .DROP, .NOT, .NULL }))
        .drop_not_null
    else if (p.parseKeywords(&.{ .SET, .DEFAULT }))
        .{ .set_default = try p.parseExpr() }
    else if (p.parseKeywords(&.{ .DROP, .DEFAULT }))
        .drop_default
    else if (p.parseKeywords(&.{ .SET, .DATA, .TYPE }) or p.parseKeyword(.TYPE))
        .{ .set_data_type = .{ .data_type = try p.parseDataType() } }
    else
        return p.expected("SET NOT NULL, DROP NOT NULL, SET DEFAULT, DROP DEFAULT, or TYPE", p.peekToken());

    return .{ .alter_column = .{
        .column_name = column_name,
        .op = op,
    } };
}

/// Parse optional FIRST | AFTER column_name (MySQL column position).
fn parseColumnPosition(p: *Parser) ?MySQLColumnPosition {
    if (p.parseKeyword(.FIRST)) return .first;
    if (p.parseKeyword(.AFTER)) {
        const tok = p.nextToken();
        switch (tok.token) {
            .Word => |w| return .{ .after = Ident{ .value = w.value, .quote_style = w.quote_style, .span = tok.span } },
            else => {
                p.prevToken();
                return null;
            },
        }
    }
    return null;
}

/// Parse optional CASCADE | RESTRICT.
fn parseOptionalDropBehavior(p: *Parser) ?DropBehavior {
    if (p.parseKeyword(.CASCADE)) return .cascade;
    if (p.parseKeyword(.RESTRICT)) return .restrict;
    return null;
}

// ============================================================================
// DROP
// ============================================================================

/// Parse a DROP statement. Called after the DROP keyword has been consumed.
pub fn parseDrop(p: *Parser) ParseError!Statement {
    // Optional TEMPORARY (MySQL).
    const temporary = (p.dialect.isMysql() or p.dialect.kind == .generic) and
        p.parseKeyword(.TEMPORARY);

    // Object type.
    const object_type: DropObjectType = if (p.parseKeyword(.TABLE))
        .table
    else if (p.parseKeyword(.VIEW))
        .view
    else if (p.parseKeyword(.INDEX))
        .index
    else if (p.parseKeyword(.DATABASE))
        .database
    else
        return p.expected("TABLE, VIEW, INDEX, or DATABASE after DROP", p.peekToken());

    // IF EXISTS.
    const if_exists = p.parseKeywords(&.{ .IF, .EXISTS });

    // Object name(s), comma-separated.
    const names = try p.parseCommaSeparated(ObjectName, Parser.parseObjectNameFn);

    // CASCADE | RESTRICT.
    const drop_behavior = parseOptionalDropBehavior(p);

    // ON table_name (for DROP INDEX ... ON table, MySQL).
    const on_table: ?ObjectName = if (p.parseKeyword(.ON))
        try p.parseObjectName()
    else
        null;

    return .{ .drop = .{
        .object_type = object_type,
        .if_exists = if_exists,
        .names = names,
        .on_table = on_table,
        .drop_behavior = drop_behavior,
        .temporary = temporary,
    } };
}

// ============================================================================
// Tests
// ============================================================================

const tokenizer_mod = @import("tokenizer.zig");
const dialect_mod = @import("dialect.zig");
const Dialect = dialect_mod.Dialect;
const stripWhitespace = @import("parser.zig").stripWhitespace;

/// Helper: parse SQL string into statements using the given dialect.
fn parseStatements(sql: []const u8, dialect: Dialect) ![]const Statement {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(dialect.kind, sql);
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, dialect, tokens);
    return parser.parseStatements();
}

/// Helper: parse a single SQL statement with Generic dialect and return it.
fn parseOneGeneric(sql: []const u8) !struct { stmt: Statement, arena: std.heap.ArenaAllocator } {
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
    return .{ .stmt = stmts[0], .arena = arena };
}

/// Helper: parse a single SQL statement with MySQL dialect and return it.
fn parseOneMysql(sql: []const u8) !struct { stmt: Statement, arena: std.heap.ArenaAllocator } {
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
    return .{ .stmt = stmts[0], .arena = arena };
}

test "parser_dml_ddl module compiles" {
    _ = Parser;
}

// ============================================================================
// INSERT tests
// ============================================================================

test "parse INSERT INTO with VALUES" {
    var result = try parseOneGeneric("INSERT INTO t1 (a, b) VALUES (1, 'foo'), (2, 'bar')");
    defer result.arena.deinit();
    const ins = switch (result.stmt) {
        .insert => |i| i,
        else => return error.TestFailed,
    };
    try std.testing.expect(ins.into);
    try std.testing.expect(!ins.replace_into);
    try std.testing.expect(!ins.ignore);
    try std.testing.expectEqual(@as(usize, 1), ins.table.parts.len);
    try std.testing.expectEqualStrings("t1", ins.table.parts[0].value);
    try std.testing.expectEqual(@as(usize, 2), ins.columns.len);
    try std.testing.expectEqualStrings("a", ins.columns[0].value);
    try std.testing.expectEqualStrings("b", ins.columns[1].value);
    switch (ins.source) {
        .select => |q| {
            switch (q.body.*) {
                .select => |s| {
                    // VALUES becomes a SELECT with Values body -- actually it goes through parseQuery
                    _ = s;
                },
                .values => |v| {
                    try std.testing.expectEqual(@as(usize, 2), v.rows.len);
                },
                else => return error.TestFailed,
            }
        },
        .values => |v| {
            try std.testing.expectEqual(@as(usize, 2), v.rows.len);
        },
        else => return error.TestFailed,
    }
    try std.testing.expect(ins.on_duplicate_key_update == null);
    try std.testing.expect(ins.priority == null);
}

test "parse INSERT INTO SELECT" {
    var result = try parseOneGeneric("INSERT INTO t1 SELECT * FROM t2");
    defer result.arena.deinit();
    const ins = switch (result.stmt) {
        .insert => |i| i,
        else => return error.TestFailed,
    };
    try std.testing.expect(ins.into);
    try std.testing.expectEqualStrings("t1", ins.table.parts[0].value);
    try std.testing.expectEqual(@as(usize, 0), ins.columns.len);
    switch (ins.source) {
        .select => {},
        else => return error.TestFailed,
    }
}

test "parse INSERT IGNORE" {
    var result = try parseOneGeneric("INSERT IGNORE INTO t1 (a) VALUES (1)");
    defer result.arena.deinit();
    const ins = switch (result.stmt) {
        .insert => |i| i,
        else => return error.TestFailed,
    };
    try std.testing.expect(ins.ignore);
    try std.testing.expect(ins.into);
}

test "parse INSERT with ON DUPLICATE KEY UPDATE" {
    var result = try parseOneMysql("INSERT INTO t1 (a, b) VALUES (1, 2) ON DUPLICATE KEY UPDATE b = VALUES(b)");
    defer result.arena.deinit();
    const ins = switch (result.stmt) {
        .insert => |i| i,
        else => return error.TestFailed,
    };
    try std.testing.expect(ins.on_duplicate_key_update != null);
    try std.testing.expectEqual(@as(usize, 1), ins.on_duplicate_key_update.?.len);
    try std.testing.expectEqualStrings("b", ins.on_duplicate_key_update.?[0].target[0].value);
}

test "parse REPLACE INTO" {
    var result = try parseOneMysql("REPLACE INTO t1 (a, b) VALUES (1, 2)");
    defer result.arena.deinit();
    const ins = switch (result.stmt) {
        .insert => |i| i,
        else => return error.TestFailed,
    };
    try std.testing.expect(ins.replace_into);
    try std.testing.expect(ins.into);
    try std.testing.expectEqualStrings("t1", ins.table.parts[0].value);
}

test "parse INSERT LOW_PRIORITY" {
    var result = try parseOneMysql("INSERT LOW_PRIORITY INTO t1 (a) VALUES (1)");
    defer result.arena.deinit();
    const ins = switch (result.stmt) {
        .insert => |i| i,
        else => return error.TestFailed,
    };
    try std.testing.expect(ins.priority != null);
    try std.testing.expect(ins.priority.? == .low_priority);
}

// ============================================================================
// UPDATE tests
// ============================================================================

test "parse UPDATE with WHERE" {
    var result = try parseOneGeneric("UPDATE t1 SET a = 1, b = 'changed' WHERE id = 10");
    defer result.arena.deinit();
    const upd = switch (result.stmt) {
        .update => |u| u,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 1), upd.table.len);
    try std.testing.expectEqual(@as(usize, 2), upd.assignments.len);
    try std.testing.expectEqualStrings("a", upd.assignments[0].target[0].value);
    try std.testing.expectEqualStrings("b", upd.assignments[1].target[0].value);
    try std.testing.expect(upd.selection != null);
}

test "parse UPDATE without WHERE" {
    var result = try parseOneGeneric("UPDATE t1 SET a = 1");
    defer result.arena.deinit();
    const upd = switch (result.stmt) {
        .update => |u| u,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 1), upd.assignments.len);
    try std.testing.expect(upd.selection == null);
}

// ============================================================================
// DELETE tests
// ============================================================================

test "parse DELETE with WHERE" {
    var result = try parseOneGeneric("DELETE FROM t1 WHERE id = 10");
    defer result.arena.deinit();
    const del = switch (result.stmt) {
        .delete => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 1), del.from.len);
    try std.testing.expect(del.selection != null);
    try std.testing.expectEqual(@as(usize, 0), del.tables.len);
}

test "parse DELETE without WHERE" {
    var result = try parseOneGeneric("DELETE FROM t1");
    defer result.arena.deinit();
    const del = switch (result.stmt) {
        .delete => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 1), del.from.len);
    try std.testing.expect(del.selection == null);
}

// ============================================================================
// CREATE TABLE tests
// ============================================================================

test "parse CREATE TABLE with columns" {
    var result = try parseOneGeneric(
        "CREATE TABLE users (id INT NOT NULL PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) UNIQUE)",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(!ct.or_replace);
    try std.testing.expect(!ct.temporary);
    try std.testing.expect(!ct.if_not_exists);
    try std.testing.expectEqualStrings("users", ct.name.parts[0].value);
    try std.testing.expectEqual(@as(usize, 3), ct.columns.len);
    // First column: id INT NOT NULL PRIMARY KEY
    try std.testing.expectEqualStrings("id", ct.columns[0].name.value);
    // Second column: name VARCHAR(255) NOT NULL
    try std.testing.expectEqualStrings("name", ct.columns[1].name.value);
    // Third column: email VARCHAR(255) UNIQUE
    try std.testing.expectEqualStrings("email", ct.columns[2].name.value);
}

test "parse CREATE TABLE IF NOT EXISTS" {
    var result = try parseOneGeneric(
        "CREATE TABLE IF NOT EXISTS t1 (id INT)",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(ct.if_not_exists);
    try std.testing.expectEqualStrings("t1", ct.name.parts[0].value);
    try std.testing.expectEqual(@as(usize, 1), ct.columns.len);
}

test "parse CREATE TABLE with table constraints" {
    var result = try parseOneGeneric(
        "CREATE TABLE t1 (id INT, name VARCHAR(100), PRIMARY KEY (id), UNIQUE (name))",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 2), ct.columns.len);
    try std.testing.expectEqual(@as(usize, 2), ct.constraints.len);
    switch (ct.constraints[0]) {
        .primary_key => |pk| {
            try std.testing.expectEqual(@as(usize, 1), pk.columns.len);
            try std.testing.expectEqualStrings("id", pk.columns[0].value);
        },
        else => return error.TestFailed,
    }
    switch (ct.constraints[1]) {
        .unique => |uq| {
            try std.testing.expectEqual(@as(usize, 1), uq.columns.len);
            try std.testing.expectEqualStrings("name", uq.columns[0].value);
        },
        else => return error.TestFailed,
    }
}

test "parse CREATE TABLE with AUTO_INCREMENT and MySQL options" {
    var result = try parseOneMysql(
        "CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 2), ct.columns.len);
    // Check AUTO_INCREMENT option on first column
    var has_auto_increment = false;
    for (ct.columns[0].options) |opt| {
        if (opt.option == .auto_increment) has_auto_increment = true;
    }
    try std.testing.expect(has_auto_increment);
    // Check table options
    try std.testing.expect(ct.table_options.len >= 2);
    switch (ct.table_options[0]) {
        .engine => |e| try std.testing.expectEqualStrings("InnoDB", e),
        else => return error.TestFailed,
    }
    switch (ct.table_options[1]) {
        .charset => |c| try std.testing.expectEqualStrings("utf8mb4", c),
        else => return error.TestFailed,
    }
}

test "parse CREATE TEMPORARY TABLE" {
    var result = try parseOneGeneric(
        "CREATE TEMPORARY TABLE temp_t (id INT)",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(ct.temporary);
    try std.testing.expectEqualStrings("temp_t", ct.name.parts[0].value);
}

test "parse CREATE TABLE with FOREIGN KEY constraint" {
    var result = try parseOneGeneric(
        "CREATE TABLE orders (id INT, user_id INT, FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE)",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 2), ct.columns.len);
    try std.testing.expectEqual(@as(usize, 1), ct.constraints.len);
    switch (ct.constraints[0]) {
        .foreign_key => |fk| {
            try std.testing.expectEqual(@as(usize, 1), fk.columns.len);
            try std.testing.expectEqualStrings("user_id", fk.columns[0].value);
            try std.testing.expectEqualStrings("users", fk.foreign_table.parts[0].value);
            try std.testing.expectEqual(@as(usize, 1), fk.referred_columns.len);
            try std.testing.expectEqualStrings("id", fk.referred_columns[0].value);
            try std.testing.expect(fk.on_delete != null);
            try std.testing.expect(fk.on_delete.? == .cascade);
        },
        else => return error.TestFailed,
    }
}

test "parse CREATE TABLE with CHECK constraint" {
    var result = try parseOneGeneric(
        "CREATE TABLE t1 (age INT, CHECK (age > 0))",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 1), ct.columns.len);
    try std.testing.expectEqual(@as(usize, 1), ct.constraints.len);
    switch (ct.constraints[0]) {
        .check => {},
        else => return error.TestFailed,
    }
}

test "parse CREATE TABLE with DEFAULT value" {
    var result = try parseOneGeneric(
        "CREATE TABLE t1 (status INT DEFAULT 0, name VARCHAR(50) DEFAULT 'unknown')",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 2), ct.columns.len);
    // First column should have DEFAULT option
    var has_default = false;
    for (ct.columns[0].options) |opt| {
        switch (opt.option) {
            .default => has_default = true,
            else => {},
        }
    }
    try std.testing.expect(has_default);
}

// ============================================================================
// CREATE INDEX tests
// ============================================================================

test "parse CREATE INDEX" {
    var result = try parseOneGeneric("CREATE INDEX ix_name ON users (name)");
    defer result.arena.deinit();
    const ci = switch (result.stmt) {
        .create_index => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(!ci.unique);
    try std.testing.expect(!ci.fulltext);
    try std.testing.expect(!ci.if_not_exists);
    try std.testing.expect(ci.name != null);
    try std.testing.expectEqualStrings("ix_name", ci.name.?.parts[0].value);
    try std.testing.expectEqualStrings("users", ci.table_name.parts[0].value);
    try std.testing.expectEqual(@as(usize, 1), ci.columns.len);
}

test "parse CREATE UNIQUE INDEX" {
    var result = try parseOneGeneric("CREATE UNIQUE INDEX ix_email ON users (email)");
    defer result.arena.deinit();
    const ci = switch (result.stmt) {
        .create_index => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(ci.unique);
    try std.testing.expectEqualStrings("ix_email", ci.name.?.parts[0].value);
    try std.testing.expectEqualStrings("users", ci.table_name.parts[0].value);
}

test "parse CREATE INDEX with multiple columns" {
    var result = try parseOneGeneric("CREATE INDEX ix_multi ON t1 (a, b DESC, c ASC)");
    defer result.arena.deinit();
    const ci = switch (result.stmt) {
        .create_index => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 3), ci.columns.len);
    // First column: no sort order
    try std.testing.expect(ci.columns[0].asc == null);
    // Second column: DESC
    try std.testing.expect(ci.columns[1].asc != null);
    try std.testing.expect(ci.columns[1].asc.? == false);
    // Third column: ASC
    try std.testing.expect(ci.columns[2].asc != null);
    try std.testing.expect(ci.columns[2].asc.? == true);
}

// ============================================================================
// CREATE VIEW tests
// ============================================================================

test "parse CREATE VIEW" {
    var result = try parseOneGeneric("CREATE VIEW active_users AS SELECT * FROM users WHERE active = 1");
    defer result.arena.deinit();
    const cv = switch (result.stmt) {
        .create_view => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(!cv.or_replace);
    try std.testing.expectEqualStrings("active_users", cv.name.parts[0].value);
    try std.testing.expectEqual(@as(usize, 0), cv.columns.len);
    try std.testing.expect(!cv.with_check_option);
}

test "parse CREATE OR REPLACE VIEW" {
    var result = try parseOneGeneric("CREATE OR REPLACE VIEW v1 AS SELECT 1");
    defer result.arena.deinit();
    const cv = switch (result.stmt) {
        .create_view => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expect(cv.or_replace);
    try std.testing.expectEqualStrings("v1", cv.name.parts[0].value);
}

test "parse CREATE VIEW with column list" {
    var result = try parseOneGeneric("CREATE VIEW v1 (col1, col2) AS SELECT a, b FROM t1");
    defer result.arena.deinit();
    const cv = switch (result.stmt) {
        .create_view => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 2), cv.columns.len);
    try std.testing.expectEqualStrings("col1", cv.columns[0].value);
    try std.testing.expectEqualStrings("col2", cv.columns[1].value);
}

// ============================================================================
// DROP tests
// ============================================================================

test "parse DROP TABLE" {
    var result = try parseOneGeneric("DROP TABLE t1");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.object_type == .table);
    try std.testing.expect(!drop.if_exists);
    try std.testing.expect(!drop.temporary);
    try std.testing.expectEqual(@as(usize, 1), drop.names.len);
    try std.testing.expectEqualStrings("t1", drop.names[0].parts[0].value);
}

test "parse DROP TABLE IF EXISTS" {
    var result = try parseOneGeneric("DROP TABLE IF EXISTS users");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.object_type == .table);
    try std.testing.expect(drop.if_exists);
    try std.testing.expectEqualStrings("users", drop.names[0].parts[0].value);
}

test "parse DROP TABLE CASCADE" {
    var result = try parseOneGeneric("DROP TABLE t1 CASCADE");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.drop_behavior != null);
    try std.testing.expect(drop.drop_behavior.? == .cascade);
}

test "parse DROP TEMPORARY TABLE" {
    var result = try parseOneMysql("DROP TEMPORARY TABLE temp_t");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.temporary);
    try std.testing.expect(drop.object_type == .table);
}

test "parse DROP INDEX ON table" {
    var result = try parseOneGeneric("DROP INDEX ix_name ON users");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.object_type == .index);
    try std.testing.expectEqualStrings("ix_name", drop.names[0].parts[0].value);
    try std.testing.expect(drop.on_table != null);
    try std.testing.expectEqualStrings("users", drop.on_table.?.parts[0].value);
}

test "parse DROP VIEW" {
    var result = try parseOneGeneric("DROP VIEW v1");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.object_type == .view);
    try std.testing.expectEqualStrings("v1", drop.names[0].parts[0].value);
}

test "parse DROP DATABASE" {
    var result = try parseOneGeneric("DROP DATABASE mydb");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.object_type == .database);
    try std.testing.expectEqualStrings("mydb", drop.names[0].parts[0].value);
}

// ============================================================================
// ALTER TABLE tests
// ============================================================================

test "parse ALTER TABLE ADD COLUMN" {
    var result = try parseOneGeneric("ALTER TABLE users ADD COLUMN age INT");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    try std.testing.expect(!alt.if_exists);
    try std.testing.expectEqualStrings("users", alt.name.parts[0].value);
    try std.testing.expectEqual(@as(usize, 1), alt.operations.len);
    switch (alt.operations[0]) {
        .add_column => |ac| {
            try std.testing.expect(ac.column_keyword);
            try std.testing.expect(!ac.if_not_exists);
            try std.testing.expectEqualStrings("age", ac.column_def.name.value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE ADD COLUMN without COLUMN keyword" {
    var result = try parseOneGeneric("ALTER TABLE users ADD age INT");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .add_column => |ac| {
            try std.testing.expect(!ac.column_keyword);
            try std.testing.expectEqualStrings("age", ac.column_def.name.value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE DROP COLUMN" {
    var result = try parseOneGeneric("ALTER TABLE users DROP COLUMN age");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .drop_column => |dc| {
            try std.testing.expectEqualStrings("age", dc.column_name.value);
            try std.testing.expect(!dc.if_exists);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE DROP COLUMN IF EXISTS" {
    var result = try parseOneGeneric("ALTER TABLE users DROP COLUMN IF EXISTS age");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .drop_column => |dc| {
            try std.testing.expect(dc.if_exists);
            try std.testing.expectEqualStrings("age", dc.column_name.value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE MODIFY COLUMN" {
    var result = try parseOneMysql("ALTER TABLE users MODIFY COLUMN name VARCHAR(512)");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .modify_column => |mc| {
            try std.testing.expectEqualStrings("name", mc.col_name.value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE CHANGE COLUMN" {
    var result = try parseOneMysql("ALTER TABLE users CHANGE COLUMN old_name new_name VARCHAR(255)");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .change_column => |cc| {
            try std.testing.expectEqualStrings("old_name", cc.old_name.value);
            try std.testing.expectEqualStrings("new_name", cc.new_name.value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE RENAME TO" {
    var result = try parseOneGeneric("ALTER TABLE users RENAME TO customers");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .rename_table => |name| {
            try std.testing.expectEqualStrings("customers", name.parts[0].value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE RENAME COLUMN" {
    var result = try parseOneGeneric("ALTER TABLE users RENAME COLUMN old_col TO new_col");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .rename_column => |rc| {
            try std.testing.expectEqualStrings("old_col", rc.old_column_name.value);
            try std.testing.expectEqualStrings("new_col", rc.new_column_name.value);
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE DROP PRIMARY KEY" {
    var result = try parseOneMysql("ALTER TABLE t1 DROP PRIMARY KEY");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .drop_primary_key => {},
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE ALTER COLUMN SET DEFAULT" {
    var result = try parseOneGeneric("ALTER TABLE t1 ALTER COLUMN age SET DEFAULT 0");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .alter_column => |ac| {
            try std.testing.expectEqualStrings("age", ac.column_name.value);
            switch (ac.op) {
                .set_default => {},
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE ALTER COLUMN DROP DEFAULT" {
    var result = try parseOneGeneric("ALTER TABLE t1 ALTER COLUMN age DROP DEFAULT");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .alter_column => |ac| {
            switch (ac.op) {
                .drop_default => {},
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE ADD COLUMN with MySQL AFTER" {
    var result = try parseOneMysql("ALTER TABLE users ADD COLUMN age INT AFTER name");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .add_column => |ac| {
            try std.testing.expectEqualStrings("age", ac.column_def.name.value);
            try std.testing.expect(ac.column_position != null);
            switch (ac.column_position.?) {
                .after => |ident| try std.testing.expectEqualStrings("name", ident.value),
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse ALTER TABLE ADD COLUMN FIRST" {
    var result = try parseOneMysql("ALTER TABLE users ADD COLUMN age INT FIRST");
    defer result.arena.deinit();
    const alt = switch (result.stmt) {
        .alter_table => |a| a,
        else => return error.TestFailed,
    };
    switch (alt.operations[0]) {
        .add_column => |ac| {
            try std.testing.expect(ac.column_position != null);
            switch (ac.column_position.?) {
                .first => {},
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

// ============================================================================
// CREATE TABLE with complex constraints (from PORTING_INSTRUCTIONS.md)
// ============================================================================

test "parse CREATE TABLE with named FOREIGN KEY constraint" {
    var result = try parseOneGeneric(
        "CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) UNIQUE, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, CONSTRAINT fk_org FOREIGN KEY (org_id) REFERENCES orgs(id))",
    );
    defer result.arena.deinit();
    const ct = switch (result.stmt) {
        .create_table => |c| c,
        else => return error.TestFailed,
    };
    try std.testing.expectEqual(@as(usize, 4), ct.columns.len);
    try std.testing.expectEqualStrings("id", ct.columns[0].name.value);
    try std.testing.expectEqualStrings("name", ct.columns[1].name.value);
    try std.testing.expectEqualStrings("email", ct.columns[2].name.value);
    try std.testing.expectEqualStrings("created_at", ct.columns[3].name.value);
    try std.testing.expectEqual(@as(usize, 1), ct.constraints.len);
    switch (ct.constraints[0]) {
        .foreign_key => |fk| {
            try std.testing.expect(fk.name != null);
            try std.testing.expectEqualStrings("fk_org", fk.name.?.value);
            try std.testing.expectEqualStrings("org_id", fk.columns[0].value);
            try std.testing.expectEqualStrings("orgs", fk.foreign_table.parts[0].value);
        },
        else => return error.TestFailed,
    }
}

test "parse DROP VIEW IF EXISTS" {
    var result = try parseOneGeneric("DROP VIEW IF EXISTS active_users");
    defer result.arena.deinit();
    const drop = switch (result.stmt) {
        .drop => |d| d,
        else => return error.TestFailed,
    };
    try std.testing.expect(drop.object_type == .view);
    try std.testing.expect(drop.if_exists);
    try std.testing.expectEqualStrings("active_users", drop.names[0].parts[0].value);
}

// ============================================================================
// SHOW statements (parsed in parser.zig but tested here for E2E coverage)
// ============================================================================

test "parse SHOW TABLES" {
    var result = try parseOneMysql("SHOW TABLES");
    defer result.arena.deinit();
    switch (result.stmt) {
        .show_tables => |st| {
            try std.testing.expect(st.database == null);
        },
        else => return error.TestFailed,
    }
}

test "parse SHOW TABLES FROM db" {
    var result = try parseOneMysql("SHOW TABLES FROM mydb");
    defer result.arena.deinit();
    switch (result.stmt) {
        .show_tables => |st| {
            try std.testing.expect(st.database != null);
            try std.testing.expectEqualStrings("mydb", st.database.?.value);
        },
        else => return error.TestFailed,
    }
}

test "parse SHOW COLUMNS FROM table" {
    var result = try parseOneMysql("SHOW COLUMNS FROM t1");
    defer result.arena.deinit();
    switch (result.stmt) {
        .show_columns => |sc| {
            try std.testing.expectEqualStrings("t1", sc.table.parts[0].value);
        },
        else => return error.TestFailed,
    }
}

test "parse SHOW CREATE TABLE" {
    var result = try parseOneMysql("SHOW CREATE TABLE t1");
    defer result.arena.deinit();
    switch (result.stmt) {
        .show_create_table => |name| {
            try std.testing.expectEqualStrings("t1", name.parts[0].value);
        },
        else => return error.TestFailed,
    }
}

test "parse SHOW DATABASES" {
    var result = try parseOneMysql("SHOW DATABASES");
    defer result.arena.deinit();
    switch (result.stmt) {
        .show_databases => {},
        else => return error.TestFailed,
    }
}

// ============================================================================
// LOCK / UNLOCK TABLES
// ============================================================================

test "parse LOCK TABLES" {
    var result = try parseOneMysql("LOCK TABLES t1 WRITE, t2 READ");
    defer result.arena.deinit();
    switch (result.stmt) {
        .lock_tables => |tables| {
            try std.testing.expectEqual(@as(usize, 2), tables.len);
            try std.testing.expectEqualStrings("t1", tables[0].table.parts[0].value);
            try std.testing.expect(tables[0].lock_type == .write);
            try std.testing.expectEqualStrings("t2", tables[1].table.parts[0].value);
            try std.testing.expect(tables[1].lock_type == .read);
        },
        else => return error.TestFailed,
    }
}

test "parse UNLOCK TABLES" {
    var result = try parseOneMysql("UNLOCK TABLES");
    defer result.arena.deinit();
    switch (result.stmt) {
        .unlock_tables => {},
        else => return error.TestFailed,
    }
}

// ============================================================================
// Transaction control
// ============================================================================

test "parse START TRANSACTION" {
    var result = try parseOneGeneric("START TRANSACTION");
    defer result.arena.deinit();
    switch (result.stmt) {
        .start_transaction => {},
        else => return error.TestFailed,
    }
}

test "parse BEGIN" {
    var result = try parseOneGeneric("BEGIN");
    defer result.arena.deinit();
    switch (result.stmt) {
        .start_transaction => {},
        else => return error.TestFailed,
    }
}

test "parse COMMIT" {
    var result = try parseOneGeneric("COMMIT");
    defer result.arena.deinit();
    switch (result.stmt) {
        .commit => {},
        else => return error.TestFailed,
    }
}

test "parse ROLLBACK" {
    var result = try parseOneGeneric("ROLLBACK");
    defer result.arena.deinit();
    switch (result.stmt) {
        .rollback => {},
        else => return error.TestFailed,
    }
}

// ============================================================================
// USE / SET
// ============================================================================

test "parse USE database" {
    var result = try parseOneMysql("USE mydb");
    defer result.arena.deinit();
    switch (result.stmt) {
        .use_db => |db| {
            try std.testing.expectEqualStrings("mydb", db.value);
        },
        else => return error.TestFailed,
    }
}

test "parse SET variable" {
    var result = try parseOneMysql("SET autocommit = 1");
    defer result.arena.deinit();
    switch (result.stmt) {
        .set => |s| {
            try std.testing.expectEqualStrings("autocommit", s.name.parts[0].value);
        },
        else => return error.TestFailed,
    }
}

// ============================================================================
// Multi-statement parsing
// ============================================================================

test "parse multiple statements" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tokenizer = tokenizer_mod.Tokenizer;
    var tok = Tokenizer.init(.Generic, "CREATE TABLE t1 (id INT PRIMARY KEY, val TEXT); INSERT INTO t1 VALUES (1, 'hello'); SELECT * FROM t1; DROP TABLE t1");
    const raw_tokens = try tok.tokenizeWithLocation(a);
    const tokens = try stripWhitespace(a, raw_tokens);

    var parser = Parser.init(a, Dialect.generic, tokens);
    const stmts = try parser.parseStatements();
    try std.testing.expectEqual(@as(usize, 4), stmts.len);
    // Statement 1: CREATE TABLE
    switch (stmts[0]) {
        .create_table => {},
        else => return error.TestFailed,
    }
    // Statement 2: INSERT
    switch (stmts[1]) {
        .insert => {},
        else => return error.TestFailed,
    }
    // Statement 3: SELECT
    switch (stmts[2]) {
        .select => {},
        else => return error.TestFailed,
    }
    // Statement 4: DROP TABLE
    switch (stmts[3]) {
        .drop => {},
        else => return error.TestFailed,
    }
}
