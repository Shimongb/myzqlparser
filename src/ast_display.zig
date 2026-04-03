/// SQL display (pretty-print) for AST types.
///
/// Produces standard SQL text from AST nodes. Call the free functions
/// directly with a `*std.Io.Writer`.
///
/// Design: all formatting is defined centrally here rather than adding
/// `format` methods to each AST struct. This keeps AST files clean
/// data definitions and separates display concerns.
const std = @import("std");
const ast = @import("ast.zig");
const ast_operator = @import("ast_operator.zig");
const ast_types = @import("ast_types.zig");
const ast_query = @import("ast_query.zig");
const ast_dml = @import("ast_dml.zig");
const ast_ddl = @import("ast_ddl.zig");

const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// Ident
// ---------------------------------------------------------------------------

/// Write a SQL identifier, adding quotes if needed.
pub fn writeIdent(w: *Writer, ident: ast.Ident) Writer.Error!void {
    if (ident.quote_style) |q| {
        const close: u8 = if (q == '[') ']' else q;
        try w.writeByte(q);
        for (ident.value) |c| {
            if (c == close) try w.writeByte(close);
            try w.writeByte(c);
        }
        try w.writeByte(close);
    } else {
        try w.writeAll(ident.value);
    }
}

/// Write a dot-separated ObjectName.
pub fn writeObjectName(w: *Writer, name: ast.ObjectName) Writer.Error!void {
    for (name.parts, 0..) |part, i| {
        if (i > 0) try w.writeByte('.');
        try writeIdent(w, part);
    }
}

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------

pub fn writeValue(w: *Writer, v: ast.Value) Writer.Error!void {
    switch (v) {
        .number => |n| {
            try w.writeAll(n.raw);
            if (n.is_long) try w.writeByte('L');
        },
        .single_quoted_string => |s| {
            try w.writeByte('\'');
            for (s) |c| {
                if (c == '\'') try w.writeByte('\'');
                try w.writeByte(c);
            }
            try w.writeByte('\'');
        },
        .double_quoted_string => |s| {
            try w.writeByte('"');
            try w.writeAll(s);
            try w.writeByte('"');
        },
        .hex_string => |s| try w.print("X'{s}'", .{s}),
        .national_string => |s| try w.print("N'{s}'", .{s}),
        .boolean => |b| try w.writeAll(if (b) "TRUE" else "FALSE"),
        .null => try w.writeAll("NULL"),
        .placeholder => |p| try w.writeAll(p),
    }
}

// ---------------------------------------------------------------------------
// BinaryOp / UnaryOp
// ---------------------------------------------------------------------------

pub fn writeBinaryOp(w: *Writer, op: ast_operator.BinaryOp) Writer.Error!void {
    try w.writeAll(op.toSql());
}

pub fn writeUnaryOp(w: *Writer, op: ast_operator.UnaryOp) Writer.Error!void {
    try w.writeAll(op.toSql());
}

// ---------------------------------------------------------------------------
// DataType
// ---------------------------------------------------------------------------

pub fn writeDataType(w: *Writer, dt: ast_types.DataType) Writer.Error!void {
    switch (dt) {
        .char => |len| try writeCharType(w, "CHAR", len),
        .char_varying => |len| try writeCharType(w, "CHARACTER VARYING", len),
        .varchar => |len| try writeCharType(w, "VARCHAR", len),
        .nvarchar => |len| try writeCharType(w, "NVARCHAR", len),
        .char_large_object => |len| {
            try w.writeAll("CHAR LARGE OBJECT");
            if (len) |l| try w.print("({d})", .{l});
        },
        .clob => |len| {
            try w.writeAll("CLOB");
            if (len) |l| try w.print("({d})", .{l});
        },
        .text => try w.writeAll("TEXT"),
        .tiny_text => try w.writeAll("TINYTEXT"),
        .medium_text => try w.writeAll("MEDIUMTEXT"),
        .long_text => try w.writeAll("LONGTEXT"),
        .uuid => try w.writeAll("UUID"),
        .binary => |len| {
            try w.writeAll("BINARY");
            if (len) |l| try w.print("({d})", .{l});
        },
        .varbinary => |len| {
            try w.writeAll("VARBINARY");
            if (len) |l| switch (l) {
                .integer => |n| try w.print("({d})", .{n}),
                .max => try w.writeAll("(MAX)"),
            };
        },
        .blob => |len| {
            try w.writeAll("BLOB");
            if (len) |l| try w.print("({d})", .{l});
        },
        .tiny_blob => try w.writeAll("TINYBLOB"),
        .medium_blob => try w.writeAll("MEDIUMBLOB"),
        .long_blob => try w.writeAll("LONGBLOB"),
        .bytea => try w.writeAll("BYTEA"),
        .numeric => |info| try writeExactNumeric(w, "NUMERIC", info),
        .decimal => |info| try writeExactNumeric(w, "DECIMAL", info),
        .decimal_unsigned => |info| try writeExactNumeric(w, "DECIMAL UNSIGNED", info),
        .dec => |info| try writeExactNumeric(w, "DEC", info),
        .dec_unsigned => |info| try writeExactNumeric(w, "DEC UNSIGNED", info),
        .tiny_int => |d| try writeIntType(w, "TINYINT", d),
        .tiny_int_unsigned => |d| try writeIntType(w, "TINYINT UNSIGNED", d),
        .small_int => |d| try writeIntType(w, "SMALLINT", d),
        .small_int_unsigned => |d| try writeIntType(w, "SMALLINT UNSIGNED", d),
        .medium_int => |d| try writeIntType(w, "MEDIUMINT", d),
        .medium_int_unsigned => |d| try writeIntType(w, "MEDIUMINT UNSIGNED", d),
        .int => |d| try writeIntType(w, "INT", d),
        .int_unsigned => |d| try writeIntType(w, "INT UNSIGNED", d),
        .integer => |d| try writeIntType(w, "INTEGER", d),
        .integer_unsigned => |d| try writeIntType(w, "INTEGER UNSIGNED", d),
        .big_int => |d| try writeIntType(w, "BIGINT", d),
        .big_int_unsigned => |d| try writeIntType(w, "BIGINT UNSIGNED", d),
        .signed => try w.writeAll("SIGNED"),
        .signed_integer => try w.writeAll("SIGNED INTEGER"),
        .unsigned => try w.writeAll("UNSIGNED"),
        .unsigned_integer => try w.writeAll("UNSIGNED INTEGER"),
        .float => |info| try writeExactNumeric(w, "FLOAT", info),
        .float_unsigned => |info| try writeExactNumeric(w, "FLOAT UNSIGNED", info),
        .real => try w.writeAll("REAL"),
        .real_unsigned => try w.writeAll("REAL UNSIGNED"),
        .double => |info| try writeExactNumeric(w, "DOUBLE", info),
        .double_unsigned => |info| try writeExactNumeric(w, "DOUBLE UNSIGNED", info),
        .double_precision => try w.writeAll("DOUBLE PRECISION"),
        .double_precision_unsigned => try w.writeAll("DOUBLE PRECISION UNSIGNED"),
        .bool => try w.writeAll("BOOL"),
        .boolean => try w.writeAll("BOOLEAN"),
        .date => try w.writeAll("DATE"),
        .datetime => |fsp| {
            try w.writeAll("DATETIME");
            if (fsp) |p| try w.print("({d})", .{p});
        },
        .timestamp => |info| {
            try w.writeAll("TIMESTAMP");
            if (info.precision) |p| try w.print("({d})", .{p});
            switch (info.tz) {
                .none => {},
                .with_time_zone => try w.writeAll(" WITH TIME ZONE"),
                .without_time_zone => try w.writeAll(" WITHOUT TIME ZONE"),
            }
        },
        .time => |info| {
            try w.writeAll("TIME");
            if (info.precision) |p| try w.print("({d})", .{p});
            switch (info.tz) {
                .none => {},
                .with_time_zone => try w.writeAll(" WITH TIME ZONE"),
                .without_time_zone => try w.writeAll(" WITHOUT TIME ZONE"),
            }
        },
        .json => try w.writeAll("JSON"),
        .bit => |len| {
            try w.writeAll("BIT");
            if (len) |l| try w.print("({d})", .{l});
        },
        .bit_varying => |len| {
            try w.writeAll("BIT VARYING");
            if (len) |l| try w.print("({d})", .{l});
        },
        .@"enum" => |variants| {
            try w.writeAll("ENUM(");
            for (variants, 0..) |v, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("'{s}'", .{v});
            }
            try w.writeByte(')');
        },
        .set => |members| {
            try w.writeAll("SET(");
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("'{s}'", .{m});
            }
            try w.writeByte(')');
        },
        .custom => |c| {
            try w.writeAll(c.name);
            if (c.modifiers.len > 0) {
                try w.writeByte('(');
                for (c.modifiers, 0..) |m, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(m);
                }
                try w.writeByte(')');
            }
        },
        .array => |elem| {
            if (elem) |e| {
                try writeDataType(w, e.*);
                try w.writeAll(" ARRAY");
            } else {
                try w.writeAll("ARRAY");
            }
        },
        .unspecified => {},
    }
}

fn writeCharType(w: *Writer, name: []const u8, len: ?ast_types.CharacterLength) Writer.Error!void {
    try w.writeAll(name);
    if (len) |l| switch (l) {
        .integer => |info| try w.print("({d})", .{info.length}),
        .max => try w.writeAll("(MAX)"),
    };
}

fn writeExactNumeric(w: *Writer, name: []const u8, info: ast_types.ExactNumberInfo) Writer.Error!void {
    try w.writeAll(name);
    switch (info) {
        .none => {},
        .precision => |p| try w.print("({d})", .{p}),
        .precision_and_scale => |ps| try w.print("({d}, {d})", .{ ps.precision, ps.scale }),
    }
}

fn writeIntType(w: *Writer, name: []const u8, display: ?u64) Writer.Error!void {
    try w.writeAll(name);
    if (display) |d| try w.print("({d})", .{d});
}

// ---------------------------------------------------------------------------
// Expr
// ---------------------------------------------------------------------------

pub fn writeExpr(w: *Writer, expr: ast.Expr) Writer.Error!void {
    switch (expr) {
        .identifier => |id| try writeIdent(w, id),
        .compound_identifier => |parts| {
            for (parts, 0..) |p, i| {
                if (i > 0) try w.writeByte('.');
                try writeIdent(w, p);
            }
        },
        .value => |v| try writeValue(w, v.val),
        .binary_op => |b| {
            try writeExpr(w, b.left.*);
            try w.writeByte(' ');
            try writeBinaryOp(w, b.op);
            try w.writeByte(' ');
            try writeExpr(w, b.right.*);
        },
        .unary_op => |u| {
            try writeUnaryOp(w, u.op);
            try w.writeByte(' ');
            try writeExpr(w, u.expr.*);
        },
        .is_null => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" IS NULL");
        },
        .is_not_null => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" IS NOT NULL");
        },
        .is_true => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" IS TRUE");
        },
        .is_not_true => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" IS NOT TRUE");
        },
        .is_false => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" IS FALSE");
        },
        .is_not_false => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" IS NOT FALSE");
        },
        .is_distinct_from => |d| {
            try writeExpr(w, d.left.*);
            try w.writeAll(" IS DISTINCT FROM ");
            try writeExpr(w, d.right.*);
        },
        .is_not_distinct_from => |d| {
            try writeExpr(w, d.left.*);
            try w.writeAll(" IS NOT DISTINCT FROM ");
            try writeExpr(w, d.right.*);
        },
        .between => |b| {
            try writeExpr(w, b.expr.*);
            if (b.negated) try w.writeAll(" NOT");
            try w.writeAll(" BETWEEN ");
            try writeExpr(w, b.low.*);
            try w.writeAll(" AND ");
            try writeExpr(w, b.high.*);
        },
        .in_list => |il| {
            try writeExpr(w, il.expr.*);
            if (il.negated) try w.writeAll(" NOT");
            try w.writeAll(" IN (");
            for (il.list, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, e);
            }
            try w.writeByte(')');
        },
        .in_subquery => |isq| {
            try writeExpr(w, isq.expr.*);
            if (isq.negated) try w.writeAll(" NOT");
            try w.writeAll(" IN (");
            try writeQuery(w, isq.subquery.*);
            try w.writeByte(')');
        },
        .like => |lk| {
            try writeExpr(w, lk.expr.*);
            if (lk.negated) try w.writeAll(" NOT");
            try w.writeAll(" LIKE ");
            try writeExpr(w, lk.pattern.*);
            if (lk.escape_char) |ec| try w.print(" ESCAPE '{c}'", .{ec});
        },
        .ilike => |lk| {
            try writeExpr(w, lk.expr.*);
            if (lk.negated) try w.writeAll(" NOT");
            try w.writeAll(" ILIKE ");
            try writeExpr(w, lk.pattern.*);
            if (lk.escape_char) |ec| try w.print(" ESCAPE '{c}'", .{ec});
        },
        .rlike => |rl| {
            try writeExpr(w, rl.expr.*);
            if (rl.negated) try w.writeAll(" NOT");
            try w.writeAll(if (rl.regexp) " REGEXP " else " RLIKE ");
            try writeExpr(w, rl.pattern.*);
        },
        .case => |c| {
            try w.writeAll("CASE");
            if (c.operand) |op| {
                try w.writeByte(' ');
                try writeExpr(w, op.*);
            }
            for (c.conditions) |when| {
                try w.writeAll(" WHEN ");
                try writeExpr(w, when.condition);
                try w.writeAll(" THEN ");
                try writeExpr(w, when.result);
            }
            if (c.else_result) |el| {
                try w.writeAll(" ELSE ");
                try writeExpr(w, el.*);
            }
            try w.writeAll(" END");
        },
        .exists => |e| {
            if (e.negated) try w.writeAll("NOT ");
            try w.writeAll("EXISTS (");
            try writeQuery(w, e.subquery.*);
            try w.writeByte(')');
        },
        .subquery => |sq| {
            try w.writeByte('(');
            try writeQuery(w, sq.*);
            try w.writeByte(')');
        },
        .cast => |c| {
            try w.writeAll("CAST(");
            try writeExpr(w, c.expr.*);
            try w.writeAll(" AS ");
            try writeDataType(w, c.data_type);
            try w.writeByte(')');
        },
        .at_time_zone => |atz| {
            try writeExpr(w, atz.timestamp.*);
            try w.writeAll(" AT TIME ZONE ");
            try writeExpr(w, atz.time_zone.*);
        },
        .extract => |ex| {
            try w.print("EXTRACT({s} FROM ", .{@tagName(ex.field)});
            try writeExpr(w, ex.expr.*);
            try w.writeByte(')');
        },
        .convert => |cv| {
            try w.writeAll("CONVERT(");
            try writeExpr(w, cv.expr.*);
            if (cv.data_type) |dt| {
                try w.writeAll(", ");
                try writeDataType(w, dt);
            }
            if (cv.charset) |cs| {
                try w.writeAll(" USING ");
                try writeObjectName(w, cs);
            }
            try w.writeByte(')');
        },
        .substring => |ss| {
            try w.writeAll("SUBSTRING(");
            try writeExpr(w, ss.expr.*);
            if (ss.from) |f| {
                try w.writeAll(" FROM ");
                try writeExpr(w, f.*);
            }
            if (ss.@"for") |fo| {
                try w.writeAll(" FOR ");
                try writeExpr(w, fo.*);
            }
            try w.writeByte(')');
        },
        .trim => |tr| {
            try w.writeAll("TRIM(");
            if (tr.trim_where) |tw| {
                try w.writeAll(switch (tw) {
                    .both => "BOTH",
                    .leading => "LEADING",
                    .trailing => "TRAILING",
                });
                try w.writeByte(' ');
            }
            if (tr.trim_what) |tw| {
                try writeExpr(w, tw.*);
                try w.writeAll(" FROM ");
            }
            try writeExpr(w, tr.expr.*);
            try w.writeByte(')');
        },
        .position => |pos| {
            try w.writeAll("POSITION(");
            try writeExpr(w, pos.expr.*);
            try w.writeAll(" IN ");
            try writeExpr(w, pos.in.*);
            try w.writeByte(')');
        },
        .interval => |iv| {
            try w.writeAll("INTERVAL ");
            try writeExpr(w, iv.value.*);
            if (iv.leading_field) |lf| try w.print(" {s}", .{@tagName(lf)});
            if (iv.last_field) |la| try w.print(" TO {s}", .{@tagName(la)});
        },
        .grouping_sets => |sets| {
            try w.writeAll("GROUPING SETS (");
            try writeExprSetList(w, sets);
            try w.writeByte(')');
        },
        .rollup => |sets| {
            try w.writeAll("ROLLUP(");
            try writeExprSetList(w, sets);
            try w.writeByte(')');
        },
        .cube => |sets| {
            try w.writeAll("CUBE(");
            try writeExprSetList(w, sets);
            try w.writeByte(')');
        },
        .tuple => |exprs| {
            try w.writeByte('(');
            for (exprs, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, e);
            }
            try w.writeByte(')');
        },
        .array => |exprs| {
            try w.writeAll("ARRAY[");
            for (exprs, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, e);
            }
            try w.writeByte(']');
        },
        .wildcard => try w.writeByte('*'),
        .qualified_wildcard => |name| {
            try writeObjectName(w, name);
            try w.writeAll(".*");
        },
        .nested => |e| {
            try w.writeByte('(');
            try writeExpr(w, e.*);
            try w.writeByte(')');
        },
        .function => |f| try writeFunction(w, f),
        .match_against => |ma| {
            try w.writeAll("MATCH (");
            for (ma.columns, 0..) |col, i| {
                if (i > 0) try w.writeAll(", ");
                try writeObjectName(w, col);
            }
            try w.writeAll(") AGAINST (");
            try writeValue(w, ma.match_value);
            if (ma.modifier) |m| {
                try w.writeByte(' ');
                try w.writeAll(m);
            }
            try w.writeByte(')');
        },
        .collate => |c| {
            try writeExpr(w, c.expr.*);
            try w.writeAll(" COLLATE ");
            try writeObjectName(w, c.collation);
        },
    }
}

fn writeExprSetList(w: *Writer, sets: []const []const ast.Expr) Writer.Error!void {
    for (sets, 0..) |set, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('(');
        for (set, 0..) |e, j| {
            if (j > 0) try w.writeAll(", ");
            try writeExpr(w, e);
        }
        try w.writeByte(')');
    }
}

fn writeFunction(w: *Writer, f: ast.Function) Writer.Error!void {
    try writeObjectName(w, f.name);
    try w.writeByte('(');
    if (f.distinct) try w.writeAll("DISTINCT ");
    for (f.args, 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        switch (arg) {
            .unnamed => |ufa| switch (ufa) {
                .expr => |e| try writeExpr(w, e.*),
                .qualified_wildcard => |on| {
                    try writeObjectName(w, on);
                    try w.writeAll(".*");
                },
                .wildcard => try w.writeByte('*'),
            },
            .named => |na| {
                try writeIdent(w, na.name);
                try w.writeAll(" => ");
                switch (na.arg) {
                    .expr => |e| try writeExpr(w, e.*),
                    .qualified_wildcard => |on| {
                        try writeObjectName(w, on);
                        try w.writeAll(".*");
                    },
                    .wildcard => try w.writeByte('*'),
                }
            },
        }
    }
    try w.writeByte(')');
    if (f.filter) |filt| {
        try w.writeAll(" FILTER (WHERE ");
        try writeExpr(w, filt.*);
        try w.writeByte(')');
    }
    if (f.over) |over| {
        try w.writeAll(" OVER (");
        try writeWindowSpec(w, over);
        try w.writeByte(')');
    }
}

fn writeWindowSpec(w: *Writer, ws: ast.WindowSpec) Writer.Error!void {
    var first = true;
    if (ws.window_name) |wn| {
        try writeIdent(w, wn);
        first = false;
    }
    if (ws.partition_by.len > 0) {
        if (!first) try w.writeByte(' ');
        try w.writeAll("PARTITION BY ");
        for (ws.partition_by, 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            try writeExpr(w, e);
        }
        first = false;
    }
    if (ws.order_by.len > 0) {
        if (!first) try w.writeByte(' ');
        try w.writeAll("ORDER BY ");
        for (ws.order_by, 0..) |ob, i| {
            if (i > 0) try w.writeAll(", ");
            try writeOrderByExpr(w, ob);
        }
        first = false;
    }
    if (ws.window_frame) |wf| {
        if (!first) try w.writeByte(' ');
        try w.writeAll(switch (wf.units) {
            .rows => "ROWS",
            .range => "RANGE",
            .groups => "GROUPS",
        });
        try w.writeAll(" BETWEEN ");
        try writeWindowFrameBound(w, wf.start_bound);
        if (wf.end_bound) |eb| {
            try w.writeAll(" AND ");
            try writeWindowFrameBound(w, eb);
        }
    }
}

fn writeWindowFrameBound(w: *Writer, wb: ast.WindowFrameBound) Writer.Error!void {
    switch (wb) {
        .current_row => try w.writeAll("CURRENT ROW"),
        .unbounded_preceding => try w.writeAll("UNBOUNDED PRECEDING"),
        .unbounded_following => try w.writeAll("UNBOUNDED FOLLOWING"),
        .preceding => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" PRECEDING");
        },
        .following => |e| {
            try writeExpr(w, e.*);
            try w.writeAll(" FOLLOWING");
        },
    }
}

pub fn writeOrderByExpr(w: *Writer, ob: ast.OrderByExpr) Writer.Error!void {
    try writeExpr(w, ob.expr);
    if (ob.asc) |asc| try w.writeAll(if (asc) " ASC" else " DESC");
    if (ob.nulls_first) |nf| try w.writeAll(if (nf) " NULLS FIRST" else " NULLS LAST");
}

// ---------------------------------------------------------------------------
// Query (stub -- full implementation after parser stabilizes)
// ---------------------------------------------------------------------------

fn writeWith(w: *Writer, with: ast_query.With) Writer.Error!void {
    try w.writeAll("WITH ");
    if (with.recursive) try w.writeAll("RECURSIVE ");
    for (with.cte_tables, 0..) |cte, i| {
        if (i > 0) try w.writeAll(", ");
        try writeIdent(w, cte.alias.name);
        try w.writeAll(" AS (");
        try writeQuery(w, cte.query.*);
        try w.writeByte(')');
    }
    try w.writeByte(' ');
}

pub fn writeQuery(w: *Writer, q: ast_query.Query) Writer.Error!void {
    if (q.with) |with| {
        try writeWith(w, with);
    }
    try writeSetExpr(w, q.body.*);
    if (q.order_by) |ob| {
        try w.writeAll(" ORDER BY ");
        for (ob.exprs, 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            try writeOrderByExpr(w, e);
        }
    }
    if (q.limit_clause) |lc| {
        switch (lc) {
            .limit_offset => |lo| {
                if (lo.limit) |l| {
                    try w.writeAll(" LIMIT ");
                    try writeExpr(w, l);
                }
                if (lo.offset) |o| {
                    try w.writeAll(" OFFSET ");
                    try writeExpr(w, o);
                }
            },
            .limit_comma => |lc2| {
                try w.writeAll(" LIMIT ");
                try writeExpr(w, lc2.offset);
                try w.writeAll(", ");
                try writeExpr(w, lc2.limit);
            },
        }
    }
}

fn writeSetExpr(w: *Writer, se: ast_query.SetExpr) Writer.Error!void {
    switch (se) {
        .select => |s| try writeSelect(w, s.*),
        .query => |q| {
            try w.writeByte('(');
            try writeQuery(w, q.*);
            try w.writeByte(')');
        },
        .set_operation => |so| {
            try writeSetExpr(w, so.left.*);
            switch (so.op) {
                .@"union" => try w.writeAll(" UNION"),
                .intersect => try w.writeAll(" INTERSECT"),
                .except => try w.writeAll(" EXCEPT"),
                .minus => try w.writeAll(" MINUS"),
            }
            switch (so.quantifier) {
                .all => try w.writeAll(" ALL"),
                .distinct => try w.writeAll(" DISTINCT"),
                .none => {},
            }
            try w.writeByte(' ');
            try writeSetExpr(w, so.right.*);
        },
        .values => |v| {
            try w.writeAll("VALUES ");
            for (v.rows, 0..) |row, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeByte('(');
                for (row, 0..) |e, j| {
                    if (j > 0) try w.writeAll(", ");
                    try writeExpr(w, e);
                }
                try w.writeByte(')');
            }
        },
    }
}

fn writeSelect(w: *Writer, s: ast_query.Select) Writer.Error!void {
    try w.writeAll("SELECT ");
    if (s.distinct) |d| {
        switch (d) {
            .distinct => try w.writeAll("DISTINCT "),
            .on => |exprs| {
                try w.writeAll("DISTINCT ON (");
                for (exprs, 0..) |e, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeExpr(w, e);
                }
                try w.writeAll(") ");
            },
        }
    }
    for (s.projection, 0..) |item, i| {
        if (i > 0) try w.writeAll(", ");
        switch (item) {
            .unnamed_expr => |e| try writeExpr(w, e),
            .expr_with_alias => |ea| {
                try writeExpr(w, ea.expr);
                try w.writeAll(" AS ");
                try writeIdent(w, ea.alias);
            },
            .qualified_wildcard => |qw| {
                try writeObjectName(w, qw);
                try w.writeAll(".*");
            },
            .wildcard => try w.writeByte('*'),
        }
    }
    if (s.from.len > 0) {
        try w.writeAll(" FROM ");
        for (s.from, 0..) |twj, i| {
            if (i > 0) try w.writeAll(", ");
            try writeTableWithJoins(w, twj);
        }
    }
    if (s.selection) |sel| {
        try w.writeAll(" WHERE ");
        try writeExpr(w, sel);
    }
    switch (s.group_by) {
        .all => try w.writeAll(" GROUP BY ALL"),
        .expressions => |exprs| if (exprs.len > 0) {
            try w.writeAll(" GROUP BY ");
            for (exprs, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, e);
            }
        },
    }
    if (s.having) |h| {
        try w.writeAll(" HAVING ");
        try writeExpr(w, h);
    }
}

fn writeTableWithJoins(w: *Writer, twj: ast_query.TableWithJoins) Writer.Error!void {
    try writeTableFactor(w, twj.relation);
    for (twj.joins) |j| {
        switch (j.join_operator) {
            .join => try w.writeAll(" JOIN "),
            .inner => try w.writeAll(" INNER JOIN "),
            .left_outer => try w.writeAll(" LEFT JOIN "),
            .right_outer => try w.writeAll(" RIGHT JOIN "),
            .full_outer => try w.writeAll(" FULL JOIN "),
            .cross_join => try w.writeAll(" CROSS JOIN "),
            .natural_inner => try w.writeAll(" NATURAL JOIN "),
            .natural_left => try w.writeAll(" NATURAL LEFT JOIN "),
            .natural_right => try w.writeAll(" NATURAL RIGHT JOIN "),
            .natural_full => try w.writeAll(" NATURAL FULL JOIN "),
        }
        try writeTableFactor(w, j.relation);
        switch (j.join_operator) {
            .join => |c| try writeJoinConstraint(w, c),
            .inner => |c| try writeJoinConstraint(w, c),
            .left_outer => |c| try writeJoinConstraint(w, c),
            .right_outer => |c| try writeJoinConstraint(w, c),
            .full_outer => |c| try writeJoinConstraint(w, c),
            else => {},
        }
    }
}

fn writeTableFactor(w: *Writer, tf: ast_query.TableFactor) Writer.Error!void {
    switch (tf) {
        .table => |t| {
            try writeObjectName(w, t.name);
            if (t.alias) |a| {
                try w.writeAll(" AS ");
                try writeIdent(w, a.name);
            }
        },
        .derived => |d| {
            try w.writeByte('(');
            try writeQuery(w, d.subquery.*);
            try w.writeByte(')');
            if (d.alias) |a| {
                try w.writeAll(" AS ");
                try writeIdent(w, a.name);
            }
        },
        .table_function => |tf2| {
            try writeExpr(w, tf2.expr);
            if (tf2.alias) |a| {
                try w.writeAll(" AS ");
                try writeIdent(w, a.name);
            }
        },
        .unnest => |u| {
            try w.writeAll("UNNEST(");
            for (u.array_exprs, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, e);
            }
            try w.writeByte(')');
            if (u.alias) |a| {
                try w.writeAll(" AS ");
                try writeIdent(w, a.name);
            }
        },
        .nested_join => |nj| {
            try w.writeByte('(');
            try writeTableWithJoins(w, nj.table_with_joins.*);
            try w.writeByte(')');
            if (nj.alias) |a| {
                try w.writeAll(" AS ");
                try writeIdent(w, a.name);
            }
        },
    }
}

fn writeJoinConstraint(w: *Writer, jc: ast_query.JoinConstraint) Writer.Error!void {
    switch (jc) {
        .on => |e| {
            try w.writeAll(" ON ");
            try writeExpr(w, e);
        },
        .using => |cols| {
            try w.writeAll(" USING (");
            for (cols, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try writeIdent(w, c);
            }
            try w.writeByte(')');
        },
        .natural, .none => {},
    }
}

/// Write a Statement as SQL text to w.
pub fn writeStatement(w: *Writer, stmt: ast.Statement) Writer.Error!void {
    switch (stmt) {
        .select => |q| try writeQuery(w, q.*),
        .insert => |ins| {
            if (ins.replace_into) {
                try w.writeAll("REPLACE INTO ");
            } else {
                try w.writeAll("INSERT");
                if (ins.ignore) try w.writeAll(" IGNORE");
                if (ins.into) try w.writeAll(" INTO");
                try w.writeByte(' ');
            }
            try writeObjectName(w, ins.table);
            if (ins.columns.len > 0) {
                try w.writeAll(" (");
                for (ins.columns, 0..) |c, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeIdent(w, c);
                }
                try w.writeByte(')');
            }
            switch (ins.source) {
                .values => |v| {
                    try w.writeAll(" VALUES ");
                    for (v.rows, 0..) |row, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeByte('(');
                        for (row, 0..) |e, j| {
                            if (j > 0) try w.writeAll(", ");
                            try writeExpr(w, e);
                        }
                        try w.writeByte(')');
                    }
                },
                .select => |q| {
                    try w.writeByte(' ');
                    try writeQuery(w, q.*);
                },
                .assignments => |asns| {
                    try w.writeAll(" SET ");
                    for (asns, 0..) |a, i| {
                        if (i > 0) try w.writeAll(", ");
                        for (a.target, 0..) |t, ti| {
                            if (ti > 0) try w.writeByte('.');
                            try writeIdent(w, t);
                        }
                        try w.writeAll(" = ");
                        try writeExpr(w, a.value);
                    }
                },
                .default_values => try w.writeAll(" DEFAULT VALUES"),
            }
        },
        .update => |upd| {
            if (upd.with) |with| {
                try writeWith(w, with);
            }
            try w.writeAll("UPDATE ");
            for (upd.table, 0..) |twj, i| {
                if (i > 0) try w.writeAll(", ");
                try writeTableWithJoins(w, twj);
            }
            try w.writeAll(" SET ");
            for (upd.assignments, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                for (a.target, 0..) |t, ti| {
                    if (ti > 0) try w.writeByte('.');
                    try writeIdent(w, t);
                }
                try w.writeAll(" = ");
                try writeExpr(w, a.value);
            }
            if (upd.selection) |sel| {
                try w.writeAll(" WHERE ");
                try writeExpr(w, sel);
            }
        },
        .delete => |del| {
            if (del.with) |with| {
                try writeWith(w, with);
            }
            try w.writeAll("DELETE ");
            if (del.tables.len > 0) {
                for (del.tables, 0..) |tbl, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeObjectName(w, tbl);
                }
                try w.writeAll(" ");
            }
            try w.writeAll("FROM ");
            for (del.from, 0..) |twj, i| {
                if (i > 0) try w.writeAll(", ");
                try writeTableWithJoins(w, twj);
            }
            if (del.selection) |sel| {
                try w.writeAll(" WHERE ");
                try writeExpr(w, sel);
            }
        },
        .create_table => |ct| {
            try w.writeAll("CREATE TABLE ");
            if (ct.if_not_exists) try w.writeAll("IF NOT EXISTS ");
            try writeObjectName(w, ct.name);
            try w.writeAll(" (");
            var first = true;
            for (ct.columns) |col| {
                if (!first) try w.writeAll(", ");
                first = false;
                try writeIdent(w, col.name);
                try w.writeByte(' ');
                try writeDataType(w, col.data_type);
            }
            for (ct.constraints) |_| {
                if (!first) try w.writeAll(", ");
                first = false;
                try w.writeAll("<constraint>");
            }
            try w.writeByte(')');
        },
        .alter_table => |at| {
            try w.writeAll("ALTER TABLE ");
            try writeObjectName(w, at.name);
            try w.writeAll(" <operations>");
        },
        .drop => |d| {
            try w.writeAll("DROP ");
            try w.writeAll(switch (d.object_type) {
                .table => "TABLE",
                .view => "VIEW",
                .index => "INDEX",
                .database => "DATABASE",
            });
            if (d.if_exists) try w.writeAll(" IF EXISTS");
            for (d.names) |n| {
                try w.writeByte(' ');
                try writeObjectName(w, n);
            }
        },
        .create_index => |ci| {
            try w.writeAll("CREATE ");
            if (ci.unique) try w.writeAll("UNIQUE ");
            try w.writeAll("INDEX ");
            if (ci.name) |n| {
                try writeObjectName(w, n);
                try w.writeByte(' ');
            }
            try w.writeAll("ON ");
            try writeObjectName(w, ci.table_name);
        },
        .create_view => |cv| {
            try w.writeAll("CREATE ");
            if (cv.or_replace) try w.writeAll("OR REPLACE ");
            try w.writeAll("VIEW ");
            try writeObjectName(w, cv.name);
            try w.writeAll(" AS ");
            try writeQuery(w, cv.query.*);
        },
        .rename_table => |pairs| {
            try w.writeAll("RENAME TABLE ");
            for (pairs, 0..) |pair, i| {
                if (i > 0) try w.writeAll(", ");
                try writeObjectName(w, pair.old_name);
                try w.writeAll(" TO ");
                try writeObjectName(w, pair.new_name);
            }
        },
        .drop_view => |dv| {
            try w.writeAll("DROP VIEW ");
            if (dv.if_exists) try w.writeAll("IF EXISTS ");
            try writeObjectName(w, dv.name);
        },
        .show_tables => |st| {
            try w.writeAll("SHOW TABLES");
            if (st.database) |db| {
                try w.writeAll(" FROM ");
                try writeIdent(w, db);
            }
        },
        .show_columns => |sc| {
            try w.writeAll("SHOW COLUMNS FROM ");
            try writeObjectName(w, sc.table);
        },
        .show_create_table => |t| {
            try w.writeAll("SHOW CREATE TABLE ");
            try writeObjectName(w, t);
        },
        .show_databases => try w.writeAll("SHOW DATABASES"),
        .show_create_view => |v| {
            try w.writeAll("SHOW CREATE VIEW ");
            try writeObjectName(w, v);
        },
        .lock_tables => try w.writeAll("LOCK TABLES <...>"),
        .unlock_tables => try w.writeAll("UNLOCK TABLES"),
        .start_transaction => try w.writeAll("START TRANSACTION"),
        .commit => try w.writeAll("COMMIT"),
        .rollback => try w.writeAll("ROLLBACK"),
        .set => |s| {
            try w.writeAll("SET ");
            try writeObjectName(w, s.name);
            try w.writeAll(" = ");
            try writeExpr(w, s.value);
        },
        .use_db => |db| {
            try w.writeAll("USE ");
            try writeIdent(w, db);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeIdent unquoted" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const id: ast.Ident = .{ .value = "users", .quote_style = null };
    try writeIdent(&aw.writer, id);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("users", s);
}

test "writeIdent backtick quoted" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const id: ast.Ident = .{ .value = "my table", .quote_style = '`' };
    try writeIdent(&aw.writer, id);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("`my table`", s);
}

test "writeObjectName" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const parts = [_]ast.Ident{
        .{ .value = "db", .quote_style = null },
        .{ .value = "schema", .quote_style = null },
        .{ .value = "tbl", .quote_style = null },
    };
    const name: ast.ObjectName = .{ .parts = &parts };
    try writeObjectName(&aw.writer, name);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("db.schema.tbl", s);
}

test "writeValue number" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeValue(&aw.writer, .{ .number = .{ .raw = "42", .is_long = false } });
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("42", s);
}

test "writeValue single quoted string" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeValue(&aw.writer, .{ .single_quoted_string = "hello" });
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("'hello'", s);
}

test "writeValue null and boolean" {
    {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try writeValue(&aw.writer, .null);
        const s = try aw.toOwnedSlice();
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("NULL", s);
    }
    {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try writeValue(&aw.writer, .{ .boolean = true });
        const s = try aw.toOwnedSlice();
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("TRUE", s);
    }
}

test "writeBinaryOp" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeBinaryOp(&aw.writer, .Plus);
    try writeBinaryOp(&aw.writer, .And);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("+AND", s);
}

test "writeUnaryOp" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeUnaryOp(&aw.writer, .Not);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("NOT", s);
}

test "writeDataType int and varchar" {
    {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try writeDataType(&aw.writer, .{ .int = null });
        const s = try aw.toOwnedSlice();
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("INT", s);
    }
    {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try writeDataType(&aw.writer, .{ .varchar = .{ .integer = .{ .length = 255, .unit = null } } });
        const s = try aw.toOwnedSlice();
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("VARCHAR(255)", s);
    }
}

test "writeExpr binary op" {
    const left: ast.Expr = .{ .identifier = .{ .value = "a", .quote_style = null } };
    const right: ast.Expr = .{ .value = .{ .val = .{ .number = .{ .raw = "1", .is_long = false } } } };
    const expr: ast.Expr = .{ .binary_op = .{ .left = &left, .op = .Plus, .right = &right } };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeExpr(&aw.writer, expr);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a + 1", s);
}

test "writeExpr is null" {
    const inner: ast.Expr = .{ .identifier = .{ .value = "x", .quote_style = null } };
    const expr: ast.Expr = .{ .is_null = &inner };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeExpr(&aw.writer, expr);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("x IS NULL", s);
}

test "writeExpr cast" {
    const inner: ast.Expr = .{ .identifier = .{ .value = "v", .quote_style = null } };
    const expr: ast.Expr = .{ .cast = .{ .expr = &inner, .data_type = .{ .int = null } } };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeExpr(&aw.writer, expr);
    const s = try aw.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("CAST(v AS INT)", s);
}
