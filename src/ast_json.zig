/// JSON serialization for AST types.
///
///   - Tagged union variants: written as `{"VariantName": <payload>}` objects.
///   - `Ident`: written as `{"value": "...", "quote_style": null|"x", "span": {...}}`.
///   - `Value::Number`: written as `["raw_str", is_long_bool]`.
///   - `Value::SingleQuotedString` etc: written as `"content"` (just the string).
///   - `Value::null`: written as JSON `null`.
///   - `Value::boolean`: written as JSON `true`/`false`.
///   - `BinaryOp`, `UnaryOp`: written as their Zig tag name string ("Plus", "Gt", ...).
///   - `ObjectName`: written as a JSON array of Ident objects.
///   - `Span`/`Location`: written as nested objects with `line`/`column` fields.
///   - Optional `?T`: written as `null` or the value.
///   - Slices `[]const T`: written as JSON arrays.
///
/// Design: all serialization is defined centrally here rather than adding
/// `jsonStringify` methods to each AST struct. This keeps AST files clean and
/// avoids coupling data definitions to a specific output format.
const std = @import("std");
const ast = @import("ast.zig");
const ast_operator = @import("ast_operator.zig");
const ast_types = @import("ast_types.zig");
const ast_query = @import("ast_query.zig");
const ast_ddl = @import("ast_ddl.zig");
const ast_dml = @import("ast_dml.zig");
const span_mod = @import("span.zig");

const Jw = std.json.Stringify;

// ---------------------------------------------------------------------------
// Location / Span
// ---------------------------------------------------------------------------

pub fn writeLocation(jw: *Jw, loc: span_mod.Location) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("line");
    try jw.write(loc.line);
    try jw.objectField("column");
    try jw.write(loc.column);
    try jw.endObject();
}

pub fn writeSpan(jw: *Jw, sp: span_mod.Span) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("start");
    try writeLocation(jw, sp.start);
    try jw.objectField("end");
    try writeLocation(jw, sp.end);
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// TokenWithSpan token serialization (for select_token etc.)
// ---------------------------------------------------------------------------

const tokenizer_mod = @import("tokenizer.zig");

/// Write a full TokenWithSpan: {"token": {...or string...}, "span": {...}}
/// For Word tokens: token is {"Word": {"value":..., "quote_style":..., "keyword":...}}
/// For punctuation tokens: token is a plain string e.g. "Mul", "RParen"
fn writeTokenWithSpan(jw: *Jw, tok: tokenizer_mod.TokenWithSpan) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("token");
    switch (tok.token) {
        .Word => |w| {
            try jw.beginObject();
            try jw.objectField("Word");
            try jw.beginObject();
            try jw.objectField("value");
            try jw.write(w.value);
            try jw.objectField("quote_style");
            if (w.quote_style) |q| {
                var buf: [1]u8 = .{q};
                try jw.write(buf[0..]);
            } else {
                try jw.write(null);
            }
            try jw.objectField("keyword");
            try jw.write(@tagName(w.keyword));
            try jw.endObject();
            try jw.endObject();
        },
        .Mul => try jw.write("Mul"),
        .RParen => try jw.write("RParen"),
        .LParen => try jw.write("LParen"),
        .EOF => try jw.write("EOF"),
        else => try jw.write("Other"),
    }
    try jw.objectField("span");
    try writeSpan(jw, tok.span);
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Ident
// ---------------------------------------------------------------------------

pub fn writeIdent(jw: *Jw, id: ast.Ident) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("value");
    try jw.write(id.value);
    try jw.objectField("quote_style");
    if (id.quote_style) |q| {
        const s = [_]u8{q};
        try jw.write(&s);
    } else {
        try jw.write(null);
    }
    try jw.objectField("span");
    try writeSpan(jw, id.span);
    try jw.endObject();
}

/// ObjectName is a JSON array of tagged Ident objects.
/// Each identifier is wrapped as {"Identifier": {...}}.
pub fn writeObjectName(jw: *Jw, name: ast.ObjectName) Jw.Error!void {
    try jw.beginArray();
    for (name.parts) |part| {
        try jw.beginObject();
        try jw.objectField("Identifier");
        try writeIdent(jw, part);
        try jw.endObject();
    }
    try jw.endArray();
}

// ---------------------------------------------------------------------------
// Value
// ---------------------------------------------------------------------------

pub fn writeValue(jw: *Jw, v: ast.Value) Jw.Error!void {
    switch (v) {
        .number => |n| {
            try jw.beginObject();
            try jw.objectField("Number");
            try jw.beginArray();
            try jw.write(n.raw);
            try jw.write(n.is_long);
            try jw.endArray();
            try jw.endObject();
        },
        .single_quoted_string => |s| {
            try jw.beginObject();
            try jw.objectField("SingleQuotedString");
            try jw.write(s);
            try jw.endObject();
        },
        .double_quoted_string => |s| {
            try jw.beginObject();
            try jw.objectField("DoubleQuotedString");
            try jw.write(s);
            try jw.endObject();
        },
        .hex_string => |s| {
            try jw.beginObject();
            try jw.objectField("HexString");
            try jw.write(s);
            try jw.endObject();
        },
        .national_string => |s| {
            try jw.beginObject();
            try jw.objectField("NationalString");
            try jw.write(s);
            try jw.endObject();
        },
        .boolean => |b| {
            try jw.beginObject();
            try jw.objectField("Boolean");
            try jw.write(b);
            try jw.endObject();
        },
        .null => {
            try jw.write("Null");
        },
        .placeholder => |p| {
            try jw.beginObject();
            try jw.objectField("Placeholder");
            try jw.write(p);
            try jw.endObject();
        },
    }
}

// ---------------------------------------------------------------------------
// BinaryOp / UnaryOp
// ---------------------------------------------------------------------------

pub fn writeBinaryOp(jw: *Jw, op: ast_operator.BinaryOp) Jw.Error!void {
    try jw.write(@tagName(op));
}

pub fn writeUnaryOp(jw: *Jw, op: ast_operator.UnaryOp) Jw.Error!void {
    try jw.write(@tagName(op));
}

// ---------------------------------------------------------------------------
// DataType
// ---------------------------------------------------------------------------

pub fn writeDataType(jw: *Jw, dt: ast_types.DataType) Jw.Error!void {
    switch (dt) {
        .text => {
            try jw.write("Text");
            return;
        },
        else => {},
    }
    try jw.beginObject();
    switch (dt) {
        .char => |len| {
            try jw.objectField("Char");
            try writeOptCharLen(jw, len);
        },
        .char_varying => |len| {
            try jw.objectField("CharVarying");
            try writeOptCharLen(jw, len);
        },
        .varchar => |len| {
            try jw.objectField("Varchar");
            try writeOptCharLen(jw, len);
        },
        .nvarchar => |len| {
            try jw.objectField("Nvarchar");
            try writeOptCharLen(jw, len);
        },
        .char_large_object => |len| {
            try jw.objectField("CharLargeObject");
            try jw.write(len);
        },
        .clob => |len| {
            try jw.objectField("Clob");
            try jw.write(len);
        },
        .text => unreachable,
        .tiny_text => {
            try jw.objectField("TinyText");
            try jw.write(null);
        },
        .medium_text => {
            try jw.objectField("MediumText");
            try jw.write(null);
        },
        .long_text => {
            try jw.objectField("LongText");
            try jw.write(null);
        },
        .uuid => {
            try jw.objectField("Uuid");
            try jw.write(null);
        },
        .binary => |len| {
            try jw.objectField("Binary");
            try jw.write(len);
        },
        .varbinary => |len| {
            try jw.objectField("Varbinary");
            try writeOptBinaryLen(jw, len);
        },
        .blob => |len| {
            try jw.objectField("Blob");
            try jw.write(len);
        },
        .tiny_blob => {
            try jw.objectField("TinyBlob");
            try jw.write(null);
        },
        .medium_blob => {
            try jw.objectField("MediumBlob");
            try jw.write(null);
        },
        .long_blob => {
            try jw.objectField("LongBlob");
            try jw.write(null);
        },
        .bytea => {
            try jw.objectField("Bytea");
            try jw.write(null);
        },
        .numeric => |info| {
            try jw.objectField("Numeric");
            try writeExactNumberInfo(jw, info);
        },
        .decimal => |info| {
            try jw.objectField("Decimal");
            try writeExactNumberInfo(jw, info);
        },
        .decimal_unsigned => |info| {
            try jw.objectField("DecimalUnsigned");
            try writeExactNumberInfo(jw, info);
        },
        .dec => |info| {
            try jw.objectField("Dec");
            try writeExactNumberInfo(jw, info);
        },
        .dec_unsigned => |info| {
            try jw.objectField("DecUnsigned");
            try writeExactNumberInfo(jw, info);
        },
        .tiny_int => |d| {
            try jw.objectField("TinyInt");
            try jw.write(d);
        },
        .tiny_int_unsigned => |d| {
            try jw.objectField("TinyIntUnsigned");
            try jw.write(d);
        },
        .small_int => |d| {
            try jw.objectField("SmallInt");
            try jw.write(d);
        },
        .small_int_unsigned => |d| {
            try jw.objectField("SmallIntUnsigned");
            try jw.write(d);
        },
        .medium_int => |d| {
            try jw.objectField("MediumInt");
            try jw.write(d);
        },
        .medium_int_unsigned => |d| {
            try jw.objectField("MediumIntUnsigned");
            try jw.write(d);
        },
        .int => |d| {
            try jw.objectField("Int");
            try jw.write(d);
        },
        .int_unsigned => |d| {
            try jw.objectField("IntUnsigned");
            try jw.write(d);
        },
        .integer => |d| {
            try jw.objectField("Integer");
            try jw.write(d);
        },
        .integer_unsigned => |d| {
            try jw.objectField("IntegerUnsigned");
            try jw.write(d);
        },
        .big_int => |d| {
            try jw.objectField("BigInt");
            try jw.write(d);
        },
        .big_int_unsigned => |d| {
            try jw.objectField("BigIntUnsigned");
            try jw.write(d);
        },
        .signed => {
            try jw.objectField("Signed");
            try jw.write(null);
        },
        .signed_integer => {
            try jw.objectField("SignedInteger");
            try jw.write(null);
        },
        .unsigned => {
            try jw.objectField("Unsigned");
            try jw.write(null);
        },
        .unsigned_integer => {
            try jw.objectField("UnsignedInteger");
            try jw.write(null);
        },
        .float => |info| {
            try jw.objectField("Float");
            try writeExactNumberInfo(jw, info);
        },
        .float_unsigned => |info| {
            try jw.objectField("FloatUnsigned");
            try writeExactNumberInfo(jw, info);
        },
        .real => {
            try jw.objectField("Real");
            try jw.write(null);
        },
        .real_unsigned => {
            try jw.objectField("RealUnsigned");
            try jw.write(null);
        },
        .double => |info| {
            try jw.objectField("Double");
            try writeExactNumberInfo(jw, info);
        },
        .double_unsigned => |info| {
            try jw.objectField("DoubleUnsigned");
            try writeExactNumberInfo(jw, info);
        },
        .double_precision => {
            try jw.objectField("DoublePrecision");
            try jw.write(null);
        },
        .double_precision_unsigned => {
            try jw.objectField("DoublePrecisionUnsigned");
            try jw.write(null);
        },
        .bool => {
            try jw.objectField("Bool");
            try jw.write(null);
        },
        .boolean => {
            try jw.objectField("Boolean");
            try jw.write(null);
        },
        .date => {
            try jw.objectField("Date");
            try jw.write(null);
        },
        .time => |info| {
            try jw.objectField("Time");
            try jw.beginObject();
            try jw.objectField("precision");
            try jw.write(info.precision);
            try jw.objectField("tz");
            try jw.write(@tagName(info.tz));
            try jw.endObject();
        },
        .datetime => |fsp| {
            try jw.objectField("Datetime");
            try jw.write(fsp);
        },
        .timestamp => |info| {
            try jw.objectField("Timestamp");
            // Timestamp as a 2-element array: [precision, "TzType"]
            try jw.beginArray();
            try jw.write(info.precision);
            try jw.write(switch (info.tz) {
                .none => "None",
                .with_time_zone => "WithTimeZone",
                .without_time_zone => "WithoutTimeZone",
            });
            try jw.endArray();
        },
        .json => {
            try jw.objectField("Json");
            try jw.write(null);
        },
        .bit => |len| {
            try jw.objectField("Bit");
            try jw.write(len);
        },
        .bit_varying => |len| {
            try jw.objectField("BitVarying");
            try jw.write(len);
        },
        .@"enum" => |variants| {
            try jw.objectField("Enum");
            // Emits: [[{Name: "v1"}, {Name: "v2"}, ...], null]
            try jw.beginArray();
            try jw.beginArray();
            for (variants) |v| {
                try jw.beginObject();
                try jw.objectField("Name");
                try jw.write(v);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.write(null);
            try jw.endArray();
        },
        .set => |members| {
            try jw.objectField("Set");
            try jw.beginArray();
            for (members) |m| try jw.write(m);
            try jw.endArray();
        },
        .custom => |c| {
            try jw.objectField("Custom");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(c.name);
            try jw.objectField("modifiers");
            try jw.beginArray();
            for (c.modifiers) |m| try jw.write(m);
            try jw.endArray();
            try jw.endObject();
        },
        .array => |elem| {
            try jw.objectField("Array");
            if (elem) |e| {
                try writeDataType(jw, e.*);
            } else {
                try jw.write(null);
            }
        },
        .unspecified => {
            try jw.objectField("Unspecified");
            try jw.write(null);
        },
    }
    try jw.endObject();
}

fn writeOptCharLen(jw: *Jw, len: ?ast_types.CharacterLength) Jw.Error!void {
    if (len) |l| {
        switch (l) {
            .integer => |info| {
                try jw.beginObject();
                try jw.objectField("IntegerLength");
                try jw.beginObject();
                try jw.objectField("length");
                try jw.write(info.length);
                try jw.objectField("unit");
                try jw.write(null);
                try jw.endObject();
                try jw.endObject();
            },
            .max => try jw.write("MAX"),
        }
    } else {
        try jw.write(null);
    }
}

fn writeOptBinaryLen(jw: *Jw, len: ?ast_types.BinaryLength) Jw.Error!void {
    if (len) |l| {
        switch (l) {
            .integer => |n| try jw.write(n),
            .max => try jw.write("MAX"),
        }
    } else {
        try jw.write(null);
    }
}

fn writeExactNumberInfo(jw: *Jw, info: ast_types.ExactNumberInfo) Jw.Error!void {
    switch (info) {
        .none => try jw.write(null),
        .precision => |p| try jw.write(p),
        .precision_and_scale => |ps| {
            try jw.beginArray();
            try jw.write(ps.precision);
            try jw.write(ps.scale);
            try jw.endArray();
        },
    }
}

// ---------------------------------------------------------------------------
// Expr
// ---------------------------------------------------------------------------

pub fn writeExpr(jw: *Jw, expr: ast.Expr) Jw.Error!void {
    try jw.beginObject();
    switch (expr) {
        .identifier => |id| {
            try jw.objectField("Identifier");
            try writeIdent(jw, id);
        },
        .compound_identifier => |parts| {
            try jw.objectField("CompoundIdentifier");
            try jw.beginArray();
            for (parts) |p| try writeIdent(jw, p);
            try jw.endArray();
        },
        .value => |v| {
            try jw.objectField("Value");
            try jw.beginObject();
            try jw.objectField("value");
            try writeValue(jw, v.val);
            try jw.objectField("span");
            try writeSpan(jw, v.span);
            try jw.endObject();
        },
        .binary_op => |b| {
            try jw.objectField("BinaryOp");
            try jw.beginObject();
            try jw.objectField("left");
            try writeExpr(jw, b.left.*);
            try jw.objectField("op");
            try writeBinaryOp(jw, b.op);
            try jw.objectField("right");
            try writeExpr(jw, b.right.*);
            try jw.endObject();
        },
        .unary_op => |u| {
            try jw.objectField("UnaryOp");
            try jw.beginObject();
            try jw.objectField("op");
            try writeUnaryOp(jw, u.op);
            try jw.objectField("expr");
            try writeExpr(jw, u.expr.*);
            try jw.endObject();
        },
        .is_null => |e| {
            try jw.objectField("IsNull");
            try writeExpr(jw, e.*);
        },
        .is_not_null => |e| {
            try jw.objectField("IsNotNull");
            try writeExpr(jw, e.*);
        },
        .is_true => |e| {
            try jw.objectField("IsTrue");
            try writeExpr(jw, e.*);
        },
        .is_not_true => |e| {
            try jw.objectField("IsNotTrue");
            try writeExpr(jw, e.*);
        },
        .is_false => |e| {
            try jw.objectField("IsFalse");
            try writeExpr(jw, e.*);
        },
        .is_not_false => |e| {
            try jw.objectField("IsNotFalse");
            try writeExpr(jw, e.*);
        },
        .is_distinct_from => |d| {
            try jw.objectField("IsDistinctFrom");
            try jw.beginObject();
            try jw.objectField("left");
            try writeExpr(jw, d.left.*);
            try jw.objectField("right");
            try writeExpr(jw, d.right.*);
            try jw.endObject();
        },
        .is_not_distinct_from => |d| {
            try jw.objectField("IsNotDistinctFrom");
            try jw.beginObject();
            try jw.objectField("left");
            try writeExpr(jw, d.left.*);
            try jw.objectField("right");
            try writeExpr(jw, d.right.*);
            try jw.endObject();
        },
        .between => |b| {
            try jw.objectField("Between");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, b.expr.*);
            try jw.objectField("negated");
            try jw.write(b.negated);
            try jw.objectField("low");
            try writeExpr(jw, b.low.*);
            try jw.objectField("high");
            try writeExpr(jw, b.high.*);
            try jw.endObject();
        },
        .in_list => |il| {
            try jw.objectField("InList");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, il.expr.*);
            try jw.objectField("list");
            try jw.beginArray();
            for (il.list) |e| try writeExpr(jw, e);
            try jw.endArray();
            try jw.objectField("negated");
            try jw.write(il.negated);
            try jw.endObject();
        },
        .in_subquery => |isq| {
            try jw.objectField("InSubquery");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, isq.expr.*);
            try jw.objectField("subquery");
            try writeQuery(jw, isq.subquery.*);
            try jw.objectField("negated");
            try jw.write(isq.negated);
            try jw.endObject();
        },
        .like => |lk| {
            try jw.objectField("Like");
            try jw.beginObject();
            try jw.objectField("negated");
            try jw.write(lk.negated);
            try jw.objectField("any");
            try jw.write(false);
            try jw.objectField("expr");
            try writeExpr(jw, lk.expr.*);
            try jw.objectField("pattern");
            try writeExpr(jw, lk.pattern.*);
            try jw.objectField("escape_char");
            if (lk.escape_char) |ec| {
                const s = [_]u8{ec};
                try jw.write(&s);
            } else {
                try jw.write(null);
            }
            try jw.endObject();
        },
        .ilike => |lk| {
            try jw.objectField("ILike");
            try jw.beginObject();
            try jw.objectField("negated");
            try jw.write(lk.negated);
            try jw.objectField("any");
            try jw.write(false);
            try jw.objectField("expr");
            try writeExpr(jw, lk.expr.*);
            try jw.objectField("pattern");
            try writeExpr(jw, lk.pattern.*);
            try jw.objectField("escape_char");
            if (lk.escape_char) |ec| {
                const s = [_]u8{ec};
                try jw.write(&s);
            } else {
                try jw.write(null);
            }
            try jw.endObject();
        },
        .rlike => |rl| {
            try jw.objectField("RLike");
            try jw.beginObject();
            try jw.objectField("negated");
            try jw.write(rl.negated);
            try jw.objectField("regexp");
            try jw.write(rl.regexp);
            try jw.objectField("expr");
            try writeExpr(jw, rl.expr.*);
            try jw.objectField("pattern");
            try writeExpr(jw, rl.pattern.*);
            try jw.endObject();
        },
        .case => |c| {
            try jw.objectField("Case");
            try jw.beginObject();
            try jw.objectField("operand");
            if (c.operand) |op| try writeExpr(jw, op.*) else try jw.write(null);
            try jw.objectField("conditions");
            try jw.beginArray();
            for (c.conditions) |when| {
                try jw.beginObject();
                try jw.objectField("condition");
                try writeExpr(jw, when.condition);
                try jw.objectField("result");
                try writeExpr(jw, when.result);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.objectField("else_result");
            if (c.else_result) |el| try writeExpr(jw, el.*) else try jw.write(null);
            try jw.endObject();
        },
        .exists => |e| {
            try jw.objectField("Exists");
            try jw.beginObject();
            try jw.objectField("subquery");
            try writeQuery(jw, e.subquery.*);
            try jw.objectField("negated");
            try jw.write(e.negated);
            try jw.endObject();
        },
        .subquery => |sq| {
            try jw.objectField("Subquery");
            try writeQuery(jw, sq.*);
        },
        .cast => |c| {
            try jw.objectField("Cast");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, c.expr.*);
            try jw.objectField("data_type");
            try writeDataType(jw, c.data_type);
            try jw.endObject();
        },
        .at_time_zone => |atz| {
            try jw.objectField("AtTimeZone");
            try jw.beginObject();
            try jw.objectField("timestamp");
            try writeExpr(jw, atz.timestamp.*);
            try jw.objectField("time_zone");
            try writeExpr(jw, atz.time_zone.*);
            try jw.endObject();
        },
        .extract => |ex| {
            try jw.objectField("Extract");
            try jw.beginObject();
            try jw.objectField("field");
            try jw.write(@tagName(ex.field));
            try jw.objectField("expr");
            try writeExpr(jw, ex.expr.*);
            try jw.endObject();
        },
        .convert => |cv| {
            try jw.objectField("Convert");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, cv.expr.*);
            try jw.objectField("data_type");
            if (cv.data_type) |dt| try writeDataType(jw, dt) else try jw.write(null);
            try jw.objectField("charset");
            if (cv.charset) |cs| try writeObjectName(jw, cs) else try jw.write(null);
            try jw.endObject();
        },
        .substring => |ss| {
            try jw.objectField("Substring");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, ss.expr.*);
            try jw.objectField("from");
            if (ss.from) |f| try writeExpr(jw, f.*) else try jw.write(null);
            try jw.objectField("for");
            if (ss.@"for") |fo| try writeExpr(jw, fo.*) else try jw.write(null);
            try jw.endObject();
        },
        .trim => |tr| {
            try jw.objectField("Trim");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, tr.expr.*);
            try jw.objectField("trim_where");
            if (tr.trim_where) |tw| try jw.write(@tagName(tw)) else try jw.write(null);
            try jw.objectField("trim_what");
            if (tr.trim_what) |tw| try writeExpr(jw, tw.*) else try jw.write(null);
            try jw.endObject();
        },
        .position => |pos| {
            try jw.objectField("Position");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, pos.expr.*);
            try jw.objectField("in");
            try writeExpr(jw, pos.in.*);
            try jw.endObject();
        },
        .interval => |iv| {
            try jw.objectField("Interval");
            try jw.beginObject();
            try jw.objectField("value");
            try writeExpr(jw, iv.value.*);
            try jw.objectField("leading_field");
            if (iv.leading_field) |lf| try jw.write(@tagName(lf)) else try jw.write(null);
            try jw.objectField("last_field");
            if (iv.last_field) |la| try jw.write(@tagName(la)) else try jw.write(null);
            try jw.endObject();
        },
        .grouping_sets => |sets| {
            try jw.objectField("GroupingSets");
            try writeExprSetArray(jw, sets);
        },
        .rollup => |sets| {
            try jw.objectField("Rollup");
            try writeExprSetArray(jw, sets);
        },
        .cube => |sets| {
            try jw.objectField("Cube");
            try writeExprSetArray(jw, sets);
        },
        .tuple => |exprs| {
            try jw.objectField("Tuple");
            try jw.beginArray();
            for (exprs) |e| try writeExpr(jw, e);
            try jw.endArray();
        },
        .array => |exprs| {
            try jw.objectField("Array");
            try jw.beginArray();
            for (exprs) |e| try writeExpr(jw, e);
            try jw.endArray();
        },
        .wildcard => |wspan| {
            try jw.objectField("Wildcard");
            try jw.beginObject();
            try jw.objectField("wildcard_token");
            try jw.beginObject();
            try jw.objectField("token");
            try jw.write("Mul");
            try jw.objectField("span");
            try writeSpan(jw, wspan);
            try jw.endObject();
            try jw.objectField("opt_ilike");
            try jw.write(null);
            try jw.objectField("opt_exclude");
            try jw.write(null);
            try jw.objectField("opt_except");
            try jw.write(null);
            try jw.objectField("opt_replace");
            try jw.write(null);
            try jw.objectField("opt_rename");
            try jw.write(null);
            try jw.endObject();
        },
        .qualified_wildcard => |name| {
            try jw.objectField("QualifiedWildcard");
            try writeObjectName(jw, name);
        },
        .nested => |e| {
            try jw.objectField("Nested");
            try writeExpr(jw, e.*);
        },
        .function => |f| {
            try jw.objectField("Function");
            try writeFunction(jw, f);
        },
        .match_against => |ma| {
            try jw.objectField("MatchAgainst");
            try jw.beginObject();
            try jw.objectField("columns");
            try jw.beginArray();
            for (ma.columns) |col| try writeObjectName(jw, col);
            try jw.endArray();
            try jw.objectField("match_value");
            try writeValue(jw, ma.match_value);
            try jw.objectField("modifier");
            try jw.write(ma.modifier);
            try jw.endObject();
        },
        .collate => |c| {
            try jw.objectField("Collate");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, c.expr.*);
            try jw.objectField("collation");
            try writeObjectName(jw, c.collation);
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeExprSetArray(jw: *Jw, sets: []const []const ast.Expr) Jw.Error!void {
    try jw.beginArray();
    for (sets) |set| {
        try jw.beginArray();
        for (set) |e| try writeExpr(jw, e);
        try jw.endArray();
    }
    try jw.endArray();
}

fn writeFunction(jw: *Jw, f: ast.Function) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try writeObjectName(jw, f.name);
    try jw.objectField("args");
    try jw.beginObject();
    try jw.objectField("List");
    try jw.beginObject();
    try jw.objectField("duplicate_treatment");
    try jw.write(null);
    try jw.objectField("args");
    try jw.beginArray();
    for (f.args) |arg| {
        try jw.beginObject();
        switch (arg) {
            .unnamed => |ufa| {
                try jw.objectField("Unnamed");
                switch (ufa) {
                    .expr => |e| switch (e.*) {
                        .wildcard => try jw.write("Wildcard"),
                        else => {
                            // Non-wildcard expr args are wrapped in {"Expr": ...}
                            try jw.beginObject();
                            try jw.objectField("Expr");
                            try writeExpr(jw, e.*);
                            try jw.endObject();
                        },
                    },
                    .qualified_wildcard => |on| {
                        try jw.beginObject();
                        try jw.objectField("QualifiedWildcard");
                        try writeObjectName(jw, on);
                        try jw.endObject();
                    },
                    .wildcard => try jw.write("Wildcard"),
                }
            },
            .named => |na| {
                try jw.objectField("Named");
                try jw.beginObject();
                try jw.objectField("name");
                try writeIdent(jw, na.name);
                try jw.objectField("arg");
                switch (na.arg) {
                    .expr => |e| try writeExpr(jw, e.*),
                    .qualified_wildcard => |on| {
                        try jw.beginObject();
                        try jw.objectField("QualifiedWildcard");
                        try writeObjectName(jw, on);
                        try jw.endObject();
                    },
                    .wildcard => try jw.write("Wildcard"),
                }
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("clauses");
    try jw.beginArray();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("filter");
    if (f.filter) |filt| try writeExpr(jw, filt.*) else try jw.write(null);
    try jw.objectField("over");
    if (f.over) |over| {
        try jw.beginObject();
        try jw.objectField("WindowSpec");
        try writeWindowSpec(jw, over);
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.objectField("within_group");
    try jw.beginArray();
    for (f.within_group) |ob| try writeOrderByExpr(jw, ob);
    try jw.endArray();
    try jw.objectField("null_treatment");
    try jw.write(null);
    try jw.objectField("parameters");
    try jw.write("None");
    try jw.objectField("uses_odbc_syntax");
    try jw.write(false);
    try jw.endObject();
}

fn writeWindowSpec(jw: *Jw, ws: ast.WindowSpec) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("window_name");
    if (ws.window_name) |wn| try writeIdent(jw, wn) else try jw.write(null);
    try jw.objectField("partition_by");
    try jw.beginArray();
    for (ws.partition_by) |e| try writeExpr(jw, e);
    try jw.endArray();
    try jw.objectField("order_by");
    try jw.beginArray();
    for (ws.order_by) |ob| try writeOrderByExpr(jw, ob);
    try jw.endArray();
    try jw.objectField("window_frame");
    if (ws.window_frame) |wf| {
        try jw.beginObject();
        try jw.objectField("units");
        try jw.write(@tagName(wf.units));
        try jw.objectField("start_bound");
        try writeWindowFrameBound(jw, wf.start_bound);
        try jw.objectField("end_bound");
        if (wf.end_bound) |eb| try writeWindowFrameBound(jw, eb) else try jw.write(null);
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.endObject();
}

fn writeWindowFrameBound(jw: *Jw, wb: ast.WindowFrameBound) Jw.Error!void {
    switch (wb) {
        .current_row => try jw.write("CurrentRow"),
        .unbounded_preceding => try jw.write("UnboundedPreceding"),
        .unbounded_following => try jw.write("UnboundedFollowing"),
        .preceding => |e| {
            try jw.beginObject();
            try jw.objectField("Preceding");
            try writeExpr(jw, e.*);
            try jw.endObject();
        },
        .following => |e| {
            try jw.beginObject();
            try jw.objectField("Following");
            try writeExpr(jw, e.*);
            try jw.endObject();
        },
    }
}

pub fn writeOrderByExpr(jw: *Jw, ob: ast.OrderByExpr) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("expr");
    try writeExpr(jw, ob.expr);
    try jw.objectField("options");
    try jw.beginObject();
    try jw.objectField("asc");
    try jw.write(ob.asc);
    try jw.objectField("nulls_first");
    try jw.write(ob.nulls_first);
    try jw.endObject();
    try jw.objectField("with_fill");
    try jw.write(null);
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Query and Statement serialization
// ---------------------------------------------------------------------------

pub fn writeQuery(jw: *Jw, q: ast_query.Query) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("with");
    if (q.with) |w| {
        try jw.beginObject();
        try jw.objectField("with_token");
        try writeTokenWithSpan(jw, w.with_token);
        try jw.objectField("recursive");
        try jw.write(w.recursive);
        try jw.objectField("cte_tables");
        try jw.beginArray();
        for (w.cte_tables) |cte| {
            try jw.beginObject();
            try jw.objectField("alias");
            try writeTableAlias(jw, cte.alias);
            try jw.objectField("query");
            try writeQuery(jw, cte.query.*);
            try jw.objectField("from");
            try jw.write(null);
            try jw.objectField("materialized");
            if (cte.materialized) |m| try jw.write(@tagName(m)) else try jw.write(null);
            try jw.objectField("closing_paren_token");
            if (cte.closing_paren_token) |cpt| try writeTokenWithSpan(jw, cpt) else try jw.write(null);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.objectField("body");
    try writeSetExpr(jw, q.body.*);
    try jw.objectField("order_by");
    if (q.order_by) |ob| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.beginObject();
        try jw.objectField("Expressions");
        try jw.beginArray();
        for (ob.exprs) |e| try writeOrderByExpr(jw, e);
        try jw.endArray();
        try jw.endObject();
        try jw.objectField("interpolate");
        try jw.write(null);
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.objectField("limit_clause");
    if (q.limit_clause) |lc| {
        try jw.beginObject();
        switch (lc) {
            .limit_offset => |lo| {
                try jw.objectField("LimitOffset");
                try jw.beginObject();
                try jw.objectField("limit");
                if (lo.limit) |l| try writeExpr(jw, l) else try jw.write(null);
                try jw.objectField("offset");
                if (lo.offset) |o| try writeExpr(jw, o) else try jw.write(null);
                try jw.objectField("limit_by");
                try jw.beginArray();
                try jw.endArray();
                try jw.endObject();
            },
            .limit_comma => |lc2| {
                try jw.objectField("LimitComma");
                try jw.beginObject();
                try jw.objectField("offset");
                try writeExpr(jw, lc2.offset);
                try jw.objectField("limit");
                try writeExpr(jw, lc2.limit);
                try jw.endObject();
            },
        }
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.objectField("fetch");
    if (q.fetch) |f| {
        try jw.beginObject();
        try jw.objectField("quantity");
        if (f.quantity) |qty| try writeExpr(jw, qty) else try jw.write(null);
        try jw.objectField("percent");
        try jw.write(f.percent);
        try jw.objectField("with_ties");
        try jw.write(f.with_ties);
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.objectField("locks");
    try jw.beginArray();
    for (q.locks) |lck| {
        try jw.beginObject();
        try jw.objectField("lock_type");
        try jw.write(@tagName(lck.lock_type));
        try jw.objectField("of");
        try jw.beginArray();
        for (lck.of) |on| try writeObjectName(jw, on);
        try jw.endArray();
        try jw.objectField("nonblock");
        if (lck.nonblock) |nb| try jw.write(@tagName(nb)) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("for_clause");
    try jw.write(null);
    try jw.objectField("settings");
    try jw.write(null);
    try jw.objectField("format_clause");
    try jw.write(null);
    try jw.objectField("pipe_operators");
    try jw.beginArray();
    try jw.endArray();
    try jw.endObject();
}

fn writeSetExpr(jw: *Jw, se: ast_query.SetExpr) Jw.Error!void {
    try jw.beginObject();
    switch (se) {
        .select => |s| {
            try jw.objectField("Select");
            try writeSelect(jw, s.*);
        },
        .query => |q| {
            try jw.objectField("Query");
            try writeQuery(jw, q.*);
        },
        .set_operation => |so| {
            try jw.objectField("SetOperation");
            try jw.beginObject();
            try jw.objectField("op");
            const op_str: []const u8 = switch (so.op) {
                .@"union" => "Union",
                .intersect => "Intersect",
                .except => "Except",
                .minus => "Minus",
            };
            try jw.write(op_str);
            try jw.objectField("set_quantifier");
            const q_str: []const u8 = switch (so.quantifier) {
                .none => "None",
                .all => "All",
                .distinct => "Distinct",
            };
            try jw.write(q_str);
            try jw.objectField("left");
            try writeSetExpr(jw, so.left.*);
            try jw.objectField("right");
            try writeSetExpr(jw, so.right.*);
            try jw.endObject();
        },
        .values => |v| {
            try jw.objectField("Values");
            try writeValues(jw, v);
        },
    }
    try jw.endObject();
}

fn writeSelect(jw: *Jw, s: ast_query.Select) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("select_token");
    if (s.select_token) |st| {
        try writeTokenWithSpan(jw, st);
    } else {
        try jw.write(null);
    }
    try jw.objectField("optimizer_hint");
    try jw.write(null);
    try jw.objectField("distinct");
    if (s.distinct) |d| {
        switch (d) {
            .distinct => try jw.write("Distinct"),
            .on => |exprs| {
                try jw.beginObject();
                try jw.objectField("On");
                try jw.beginArray();
                for (exprs) |e| try writeExpr(jw, e);
                try jw.endArray();
                try jw.endObject();
            },
        }
    } else {
        try jw.write(null);
    }
    try jw.objectField("select_modifiers");
    try jw.write(null);
    try jw.objectField("top");
    try jw.write(null);
    try jw.objectField("top_before_distinct");
    try jw.write(false);
    try jw.objectField("projection");
    try jw.beginArray();
    for (s.projection) |item| {
        try jw.beginObject();
        switch (item) {
            .unnamed_expr => |e| {
                try jw.objectField("UnnamedExpr");
                try writeExpr(jw, e);
            },
            .expr_with_alias => |ea| {
                try jw.objectField("ExprWithAlias");
                try jw.beginObject();
                try jw.objectField("expr");
                try writeExpr(jw, ea.expr);
                try jw.objectField("alias");
                try writeIdent(jw, ea.alias);
                try jw.endObject();
            },
            .qualified_wildcard => |on| {
                try jw.objectField("QualifiedWildcard");
                try writeObjectName(jw, on);
            },
            .wildcard => |wspan| {
                try jw.objectField("Wildcard");
                try jw.beginObject();
                try jw.objectField("wildcard_token");
                try jw.beginObject();
                try jw.objectField("token");
                try jw.write("Mul");
                try jw.objectField("span");
                try writeSpan(jw, wspan);
                try jw.endObject();
                try jw.objectField("opt_ilike");
                try jw.write(null);
                try jw.objectField("opt_exclude");
                try jw.write(null);
                try jw.objectField("opt_except");
                try jw.write(null);
                try jw.objectField("opt_replace");
                try jw.write(null);
                try jw.objectField("opt_rename");
                try jw.write(null);
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("exclude");
    try jw.write(null);
    try jw.objectField("into");
    try jw.write(null);
    try jw.objectField("from");
    try jw.beginArray();
    for (s.from) |twj| try writeTableWithJoins(jw, twj);
    try jw.endArray();
    try jw.objectField("lateral_views");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("prewhere");
    try jw.write(null);
    try jw.objectField("selection");
    if (s.selection) |sel| try writeExpr(jw, sel) else try jw.write(null);
    try jw.objectField("connect_by");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("group_by");
    try jw.beginObject();
    switch (s.group_by) {
        .all => {
            try jw.objectField("All");
            try jw.write(null);
        },
        .expressions => |exprs| {
            try jw.objectField("Expressions");
            try jw.beginArray();
            try jw.beginArray();
            for (exprs) |e| try writeExpr(jw, e);
            try jw.endArray();
            try jw.beginArray();
            try jw.endArray();
            try jw.endArray();
        },
    }
    try jw.endObject();
    try jw.objectField("cluster_by");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("distribute_by");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("sort_by");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("having");
    if (s.having) |h| try writeExpr(jw, h) else try jw.write(null);
    try jw.objectField("named_window");
    try jw.beginArray();
    for (s.named_window) |nw| {
        try jw.beginObject();
        try jw.objectField("name");
        try writeIdent(jw, nw.name);
        try jw.objectField("spec");
        try writeWindowSpec(jw, nw.spec);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("qualify");
    try jw.write(null);
    try jw.objectField("window_before_qualify");
    try jw.write(false);
    try jw.objectField("value_table_mode");
    try jw.write(null);
    try jw.objectField("flavor");
    try jw.write("Standard");
    try jw.endObject();
}

fn writeTableWithJoins(jw: *Jw, twj: ast_query.TableWithJoins) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("relation");
    try writeTableFactor(jw, twj.relation);
    try jw.objectField("joins");
    try jw.beginArray();
    for (twj.joins) |j| {
        try jw.beginObject();
        try jw.objectField("relation");
        try writeTableFactor(jw, j.relation);
        try jw.objectField("global");
        try jw.write(false);
        try jw.objectField("join_operator");
        try writeJoinOperator(jw, j.join_operator);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeTableFactor(jw: *Jw, tf: ast_query.TableFactor) Jw.Error!void {
    try jw.beginObject();
    switch (tf) {
        .table => |t| {
            try jw.objectField("Table");
            try jw.beginObject();
            try jw.objectField("name");
            try writeObjectName(jw, t.name);
            try jw.objectField("alias");
            if (t.alias) |a| try writeTableAlias(jw, a) else try jw.write(null);
            try jw.objectField("args");
            try jw.write(null);
            try jw.objectField("with_hints");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("version");
            try jw.write(null);
            try jw.objectField("with_ordinality");
            try jw.write(false);
            try jw.objectField("partitions");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("json_path");
            try jw.write(null);
            try jw.objectField("sample");
            try jw.write(null);
            try jw.objectField("index_hints");
            try jw.beginArray();
            for (t.index_hints) |ih| {
                try jw.beginObject();
                try jw.objectField("hint_type");
                try jw.write(switch (ih.hint_type) {
                    .use_index => "Use",
                    .force_index => "Force",
                    .ignore_index => "Ignore",
                });
                try jw.objectField("index_type");
                try jw.write("Index");
                try jw.objectField("for_clause");
                try jw.write(null);
                try jw.objectField("index_names");
                try jw.beginArray();
                for (ih.index_names) |n| try writeIdent(jw, n);
                try jw.endArray();
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
        },
        .derived => |d| {
            try jw.objectField("Derived");
            try jw.beginObject();
            try jw.objectField("lateral");
            try jw.write(d.lateral);
            try jw.objectField("subquery");
            try writeQuery(jw, d.subquery.*);
            try jw.objectField("alias");
            if (d.alias) |a| try writeTableAlias(jw, a) else try jw.write(null);
            try jw.objectField("sample");
            try jw.write(null);
            try jw.endObject();
        },
        .table_function => |tf2| {
            try jw.objectField("TableFunction");
            try jw.beginObject();
            try jw.objectField("expr");
            try writeExpr(jw, tf2.expr);
            try jw.objectField("alias");
            if (tf2.alias) |a| try writeTableAlias(jw, a) else try jw.write(null);
            try jw.endObject();
        },
        .unnest => |u| {
            try jw.objectField("Unnest");
            try jw.beginObject();
            try jw.objectField("array_exprs");
            try jw.beginArray();
            for (u.array_exprs) |e| try writeExpr(jw, e);
            try jw.endArray();
            try jw.objectField("alias");
            if (u.alias) |a| try writeTableAlias(jw, a) else try jw.write(null);
            try jw.objectField("with_offset");
            try jw.write(u.with_offset);
            try jw.objectField("with_offset_alias");
            if (u.with_offset_alias) |a| try writeIdent(jw, a) else try jw.write(null);
            try jw.endObject();
        },
        .nested_join => |nj| {
            try jw.objectField("NestedJoin");
            try jw.beginObject();
            try jw.objectField("table_with_joins");
            try writeTableWithJoins(jw, nj.table_with_joins.*);
            try jw.objectField("alias");
            if (nj.alias) |a| try writeTableAlias(jw, a) else try jw.write(null);
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeTableAlias(jw: *Jw, alias: ast_query.TableAlias) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("explicit");
    try jw.write(alias.explicit);
    try jw.objectField("name");
    try writeIdent(jw, alias.name);
    try jw.objectField("columns");
    try jw.beginArray();
    for (alias.columns) |c| try writeIdent(jw, c);
    try jw.endArray();
    try jw.endObject();
}

fn writeJoinOperator(jw: *Jw, jo: ast_query.JoinOperator) Jw.Error!void {
    try jw.beginObject();
    switch (jo) {
        .join => |jc| {
            try jw.objectField("Join");
            try writeJoinConstraint(jw, jc);
        },
        .inner => |jc| {
            try jw.objectField("Inner");
            try writeJoinConstraint(jw, jc);
        },
        .left_outer => |jc| {
            try jw.objectField("Left");
            try writeJoinConstraint(jw, jc);
        },
        .right_outer => |jc| {
            try jw.objectField("RightOuter");
            try writeJoinConstraint(jw, jc);
        },
        .full_outer => |jc| {
            try jw.objectField("Full");
            try writeJoinConstraint(jw, jc);
        },
        .cross_join => {
            try jw.objectField("CrossJoin");
            try jw.write("None");
        },
        .natural_inner => {
            try jw.objectField("Join");
            try jw.write("Natural");
        },
        .natural_left => {
            try jw.objectField("Left");
            try jw.write("Natural");
        },
        .natural_right => {
            try jw.objectField("RightOuter");
            try jw.write("Natural");
        },
        .natural_full => {
            try jw.objectField("FullOuter");
            try jw.write("Natural");
        },
    }
    try jw.endObject();
}

fn writeJoinConstraint(jw: *Jw, jc: ast_query.JoinConstraint) Jw.Error!void {
    try jw.beginObject();
    switch (jc) {
        .on => |e| {
            try jw.objectField("On");
            try writeExpr(jw, e);
        },
        .using => |cols| {
            try jw.objectField("Using");
            // Wraps each ident in [{"Identifier": ...}]
            try jw.beginArray();
            for (cols) |c| {
                try jw.beginArray();
                try jw.beginObject();
                try jw.objectField("Identifier");
                try writeIdent(jw, c);
                try jw.endObject();
                try jw.endArray();
            }
            try jw.endArray();
        },
        .natural => {
            try jw.objectField("Natural");
            try jw.write(null);
        },
        .none => {
            try jw.objectField("None");
            try jw.write(null);
        },
    }
    try jw.endObject();
}

fn writeValues(jw: *Jw, v: ast_query.Values) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("explicit_row");
    try jw.write(false);
    try jw.objectField("value_keyword");
    try jw.write(false);
    try jw.objectField("rows");
    try jw.beginArray();
    for (v.rows) |row| {
        try jw.beginArray();
        for (row) |e| try writeExpr(jw, e);
        try jw.endArray();
    }
    try jw.endArray();
    try jw.endObject();
}

pub fn writeStatement(jw: *Jw, stmt: ast.Statement) Jw.Error!void {
    // UnlockTables is serialized as a plain string, not an object
    if (stmt == .unlock_tables) {
        try jw.write("UnlockTables");
        return;
    }
    try jw.beginObject();
    switch (stmt) {
        .select => |q| {
            try jw.objectField("Query");
            try writeQuery(jw, q.*);
        },
        .insert => |ins| {
            try jw.objectField("Insert");
            try writeInsert(jw, ins);
        },
        .update => |upd| {
            try jw.objectField("Update");
            try writeUpdate(jw, upd);
        },
        .delete => |del| {
            try jw.objectField("Delete");
            try writeDelete(jw, del);
        },
        .create_table => |ct| {
            try jw.objectField("CreateTable");
            try writeCreateTable(jw, ct);
        },
        .alter_table => |at| {
            try jw.objectField("AlterTable");
            try writeAlterTable(jw, at);
        },
        .drop => |d| {
            try jw.objectField("Drop");
            try writeDrop(jw, d);
        },
        .create_index => |ci| {
            try jw.objectField("CreateIndex");
            try writeCreateIndex(jw, ci);
        },
        .create_view => |cv| {
            try jw.objectField("CreateView");
            try writeCreateView(jw, cv);
        },
        .drop_view => |dv| {
            try jw.objectField("DropView");
            try jw.beginObject();
            try jw.objectField("if_exists");
            try jw.write(dv.if_exists);
            try jw.objectField("name");
            try writeObjectName(jw, dv.name);
            try jw.endObject();
        },
        .rename_table => |pairs| {
            try jw.objectField("RenameTable");
            try jw.beginObject();
            try jw.objectField("operations");
            try jw.beginArray();
            for (pairs) |pair| {
                try jw.beginObject();
                try jw.objectField("old_name");
                try writeObjectName(jw, pair.old_name);
                try jw.objectField("new_name");
                try writeObjectName(jw, pair.new_name);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
        },
        .show_tables => {
            try jw.objectField("ShowTables");
            try jw.beginObject();
            try jw.objectField("terse");
            try jw.write(false);
            try jw.objectField("history");
            try jw.write(false);
            try jw.objectField("extended");
            try jw.write(false);
            try jw.objectField("full");
            try jw.write(false);
            try jw.objectField("external");
            try jw.write(false);
            try jw.objectField("show_options");
            try jw.beginObject();
            try jw.objectField("show_in");
            try jw.write(null);
            try jw.objectField("starts_with");
            try jw.write(null);
            try jw.objectField("limit");
            try jw.write(null);
            try jw.objectField("limit_from");
            try jw.write(null);
            try jw.objectField("filter_position");
            try jw.write(null);
            try jw.endObject();
            try jw.endObject();
        },
        .show_columns => |sc| {
            try jw.objectField("ShowColumns");
            try jw.beginObject();
            try jw.objectField("extended");
            try jw.write(false);
            try jw.objectField("full");
            try jw.write(false);
            try jw.objectField("show_options");
            try jw.beginObject();
            try jw.objectField("show_in");
            try jw.beginObject();
            try jw.objectField("clause");
            try jw.write("FROM");
            try jw.objectField("parent_type");
            try jw.write(null);
            try jw.objectField("parent_name");
            try writeObjectName(jw, sc.table);
            try jw.endObject();
            try jw.objectField("starts_with");
            try jw.write(null);
            try jw.objectField("limit");
            try jw.write(null);
            try jw.objectField("limit_from");
            try jw.write(null);
            try jw.objectField("filter_position");
            try jw.write(null);
            try jw.endObject();
            try jw.endObject();
        },
        .show_create_table => |on| {
            try jw.objectField("ShowCreate");
            try jw.beginObject();
            try jw.objectField("obj_type");
            try jw.write("Table");
            try jw.objectField("obj_name");
            try writeObjectName(jw, on);
            try jw.endObject();
        },
        .show_databases => {
            try jw.objectField("ShowDatabases");
            try jw.beginObject();
            try jw.objectField("terse");
            try jw.write(false);
            try jw.objectField("history");
            try jw.write(false);
            try jw.objectField("show_options");
            try jw.beginObject();
            try jw.objectField("show_in");
            try jw.write(null);
            try jw.objectField("starts_with");
            try jw.write(null);
            try jw.objectField("limit");
            try jw.write(null);
            try jw.objectField("limit_from");
            try jw.write(null);
            try jw.objectField("filter_position");
            try jw.write(null);
            try jw.endObject();
            try jw.endObject();
        },
        .show_create_view => |on| {
            try jw.objectField("ShowCreate");
            try jw.beginObject();
            try jw.objectField("obj_type");
            try jw.write("View");
            try jw.objectField("obj_name");
            try writeObjectName(jw, on);
            try jw.endObject();
        },
        .lock_tables => |tables| {
            try jw.objectField("LockTables");
            try jw.beginObject();
            try jw.objectField("tables");
            try jw.beginArray();
            for (tables) |lt| {
                try jw.beginObject();
                try jw.objectField("table");
                // Fixture expects single Ident (first part), not ObjectName array
                if (lt.table.parts.len > 0) {
                    try writeIdent(jw, lt.table.parts[0]);
                } else {
                    try jw.write(null);
                }
                try jw.objectField("alias");
                try jw.write(null);
                try jw.objectField("lock_type");
                try jw.beginObject();
                switch (lt.lock_type) {
                    .write, .low_priority_write => {
                        try jw.objectField("Write");
                        try jw.beginObject();
                        try jw.objectField("low_priority");
                        try jw.write(lt.lock_type == .low_priority_write);
                        try jw.endObject();
                    },
                    .read, .read_local => {
                        try jw.objectField("Read");
                        try jw.beginObject();
                        try jw.objectField("local");
                        try jw.write(lt.lock_type == .read_local);
                        try jw.endObject();
                    },
                }
                try jw.endObject();
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
        },
        .unlock_tables => unreachable, // handled before switch
        .start_transaction => {
            try jw.objectField("StartTransaction");
            try jw.write(null);
        },
        .commit => {
            try jw.objectField("Commit");
            try jw.write(null);
        },
        .rollback => {
            try jw.objectField("Rollback");
            try jw.write(null);
        },
        .set => |s| {
            try jw.objectField("SetVariable");
            try jw.beginObject();
            try jw.objectField("name");
            try writeObjectName(jw, s.name);
            try jw.objectField("value");
            try writeExpr(jw, s.value);
            try jw.endObject();
        },
        .use_db => |id| {
            try jw.objectField("Use");
            try writeIdent(jw, id);
        },
    }
    try jw.endObject();
}

fn writeInsert(jw: *Jw, ins: ast_dml.Insert) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("insert_token");
    try writeTokenWithSpan(jw, ins.token);
    try jw.objectField("optimizer_hint");
    try jw.write(null);
    try jw.objectField("or");
    try jw.write(null);
    try jw.objectField("ignore");
    try jw.write(ins.ignore);
    try jw.objectField("into");
    try jw.write(ins.into);
    // table: wrapped as {"TableName": [...]}
    try jw.objectField("table");
    try jw.beginObject();
    try jw.objectField("TableName");
    try writeObjectName(jw, ins.table);
    try jw.endObject();
    try jw.objectField("table_alias");
    if (ins.table_alias) |a| try writeIdent(jw, a) else try jw.write(null);
    try jw.objectField("columns");
    try jw.beginArray();
    for (ins.columns) |c| try writeIdent(jw, c);
    try jw.endArray();
    try jw.objectField("overwrite");
    try jw.write(false);
    // source: a Query-shaped object; values become body.Values, select is a full query
    try jw.objectField("source");
    switch (ins.source) {
        .select => |q| try writeQuery(jw, q.*),
        .values => |v| {
            try jw.beginObject();
            try jw.objectField("with");
            try jw.write(null);
            try jw.objectField("body");
            try jw.beginObject();
            try jw.objectField("Values");
            try writeValues(jw, v);
            try jw.endObject();
            try jw.objectField("order_by");
            try jw.write(null);
            try jw.objectField("limit_clause");
            try jw.write(null);
            try jw.objectField("fetch");
            try jw.write(null);
            try jw.objectField("locks");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("for_clause");
            try jw.write(null);
            try jw.objectField("settings");
            try jw.write(null);
            try jw.objectField("format_clause");
            try jw.write(null);
            try jw.objectField("pipe_operators");
            try jw.beginArray();
            try jw.endArray();
            try jw.endObject();
        },
        .assignments, .default_values => try jw.write(null),
    }
    // assignments: separate field for MySQL SET form
    try jw.objectField("assignments");
    try jw.beginArray();
    if (ins.source == .assignments) {
        for (ins.source.assignments) |a| try writeAssignment(jw, a);
    }
    try jw.endArray();
    try jw.objectField("partitioned");
    try jw.write(null);
    try jw.objectField("after_columns");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("has_table_keyword");
    try jw.write(false);
    // on: {"DuplicateKeyUpdate": [...]} wrapper instead of on_duplicate_key_update
    try jw.objectField("on");
    if (ins.on_duplicate_key_update) |odku| {
        try jw.beginObject();
        try jw.objectField("DuplicateKeyUpdate");
        try jw.beginArray();
        for (odku) |a| try writeAssignment(jw, a);
        try jw.endArray();
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.objectField("returning");
    try jw.write(null);
    try jw.objectField("replace_into");
    try jw.write(ins.replace_into);
    try jw.objectField("priority");
    if (ins.priority) |p| try jw.write(@tagName(p)) else try jw.write(null);
    try jw.objectField("insert_alias");
    try jw.write(null);
    try jw.objectField("settings");
    try jw.write(null);
    try jw.objectField("format_clause");
    try jw.write(null);
    try jw.endObject();
}

fn writeAssignment(jw: *Jw, a: ast.Assignment) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("target");
    try jw.beginObject();
    try jw.objectField("ColumnName");
    try jw.beginArray();
    for (a.target) |id| {
        try jw.beginObject();
        try jw.objectField("Identifier");
        try writeIdent(jw, id);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.objectField("value");
    try writeExpr(jw, a.value);
    try jw.endObject();
}

fn writeUpdate(jw: *Jw, upd: ast_dml.Update) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("update_token");
    try writeTokenWithSpan(jw, upd.token);
    try jw.objectField("optimizer_hint");
    try jw.write(null);
    // table: single TableWithJoins
    try jw.objectField("table");
    if (upd.table.len > 0) {
        try writeTableWithJoins(jw, upd.table[0]);
    } else {
        try jw.write(null);
    }
    try jw.objectField("assignments");
    try jw.beginArray();
    for (upd.assignments) |a| try writeAssignment(jw, a);
    try jw.endArray();
    try jw.objectField("from");
    if (upd.from) |from| {
        try jw.beginArray();
        for (from) |twj| try writeTableWithJoins(jw, twj);
        try jw.endArray();
    } else {
        try jw.write(null);
    }
    try jw.objectField("selection");
    if (upd.selection) |sel| try writeExpr(jw, sel) else try jw.write(null);
    try jw.objectField("returning");
    try jw.write(null);
    try jw.objectField("or");
    try jw.write(null);
    try jw.objectField("limit");
    if (upd.limit) |lim| try writeExpr(jw, lim) else try jw.write(null);
    try jw.endObject();
}

fn writeDelete(jw: *Jw, del: ast_dml.Delete) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("delete_token");
    try writeTokenWithSpan(jw, del.token);
    try jw.objectField("optimizer_hint");
    try jw.write(null);
    try jw.objectField("tables");
    try jw.beginArray();
    for (del.tables) |on| try writeObjectName(jw, on);
    try jw.endArray();
    // from: wrapped as {"WithFromKeyword": [...]}
    try jw.objectField("from");
    try jw.beginObject();
    try jw.objectField("WithFromKeyword");
    try jw.beginArray();
    for (del.from) |twj| try writeTableWithJoins(jw, twj);
    try jw.endArray();
    try jw.endObject();
    try jw.objectField("using");
    if (del.using) |using| {
        try jw.beginArray();
        for (using) |twj| try writeTableWithJoins(jw, twj);
        try jw.endArray();
    } else {
        try jw.write(null);
    }
    try jw.objectField("selection");
    if (del.selection) |sel| try writeExpr(jw, sel) else try jw.write(null);
    try jw.objectField("returning");
    try jw.write(null);
    try jw.objectField("order_by");
    try jw.beginArray();
    for (del.order_by) |ob| try writeOrderByExpr(jw, ob);
    try jw.endArray();
    try jw.objectField("limit");
    if (del.limit) |lim| try writeExpr(jw, lim) else try jw.write(null);
    try jw.endObject();
}

fn writeCreateTable(jw: *Jw, ct: ast_ddl.CreateTable) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("or_replace");
    try jw.write(ct.or_replace);
    try jw.objectField("temporary");
    try jw.write(ct.temporary);
    try jw.objectField("external");
    try jw.write(false);
    try jw.objectField("dynamic");
    try jw.write(false);
    try jw.objectField("global");
    try jw.write(null);
    try jw.objectField("if_not_exists");
    try jw.write(ct.if_not_exists);
    try jw.objectField("transient");
    try jw.write(false);
    try jw.objectField("volatile");
    try jw.write(false);
    try jw.objectField("iceberg");
    try jw.write(false);
    try jw.objectField("name");
    try writeObjectName(jw, ct.name);
    try jw.objectField("columns");
    try jw.beginArray();
    for (ct.columns) |col| try writeColumnDef(jw, col);
    try jw.endArray();
    try jw.objectField("constraints");
    try jw.beginArray();
    for (ct.constraints) |tc| try writeTableConstraint(jw, tc);
    try jw.endArray();
    try jw.objectField("hive_distribution");
    try jw.write("NONE");
    try jw.objectField("hive_formats");
    try jw.write(null);
    try jw.objectField("table_options");
    try jw.write("None");
    try jw.objectField("file_format");
    try jw.write(null);
    try jw.objectField("location");
    try jw.write(null);
    try jw.objectField("query");
    if (ct.as_select) |q| try writeQuery(jw, q.*) else try jw.write(null);
    try jw.objectField("without_rowid");
    try jw.write(false);
    try jw.objectField("like");
    if (ct.like) |l| try writeObjectName(jw, l) else try jw.write(null);
    try jw.objectField("clone");
    try jw.write(null);
    try jw.objectField("version");
    try jw.write(null);
    try jw.objectField("comment");
    try jw.write(ct.comment);
    try jw.objectField("on_commit");
    if (ct.on_commit) |oc| try jw.write(@tagName(oc)) else try jw.write(null);
    try jw.objectField("on_cluster");
    try jw.write(null);
    try jw.objectField("primary_key");
    try jw.write(null);
    try jw.objectField("order_by");
    try jw.write(null);
    try jw.objectField("partition_by");
    try jw.write(null);
    try jw.objectField("cluster_by");
    try jw.write(null);
    try jw.objectField("clustered_by");
    try jw.write(null);
    try jw.objectField("inherits");
    try jw.write(null);
    try jw.objectField("partition_of");
    try jw.write(null);
    try jw.objectField("for_values");
    try jw.write(null);
    try jw.objectField("strict");
    try jw.write(false);
    try jw.objectField("copy_grants");
    try jw.write(false);
    try jw.objectField("enable_schema_evolution");
    try jw.write(null);
    try jw.objectField("change_tracking");
    try jw.write(null);
    try jw.objectField("data_retention_time_in_days");
    try jw.write(null);
    try jw.objectField("max_data_extension_time_in_days");
    try jw.write(null);
    try jw.objectField("default_ddl_collation");
    try jw.write(null);
    try jw.objectField("with_aggregation_policy");
    try jw.write(null);
    try jw.objectField("with_row_access_policy");
    try jw.write(null);
    try jw.objectField("with_tags");
    try jw.write(null);
    try jw.objectField("external_volume");
    try jw.write(null);
    try jw.objectField("base_location");
    try jw.write(null);
    try jw.objectField("catalog");
    try jw.write(null);
    try jw.objectField("catalog_sync");
    try jw.write(null);
    try jw.objectField("storage_serialization_policy");
    try jw.write(null);
    try jw.objectField("target_lag");
    try jw.write(null);
    try jw.objectField("warehouse");
    try jw.write(null);
    try jw.objectField("refresh_mode");
    try jw.write(null);
    try jw.objectField("initialize");
    try jw.write(null);
    try jw.objectField("require_user");
    try jw.write(false);
    try jw.endObject();
}

fn writeColumnDef(jw: *Jw, col: ast_ddl.ColumnDef) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try writeIdent(jw, col.name);
    try jw.objectField("data_type");
    try writeDataType(jw, col.data_type);
    try jw.objectField("options");
    try jw.beginArray();
    for (col.options) |opt| {
        try jw.beginObject();
        try jw.objectField("name");
        if (opt.name) |n| try writeIdent(jw, n) else try jw.write(null);
        try jw.objectField("option");
        try writeColumnOption(jw, opt.option);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeColumnOption(jw: *Jw, co: ast_ddl.ColumnOption) Jw.Error!void {
    switch (co) {
        .null => try jw.write("Null"),
        .not_null => try jw.write("NotNull"),
        .default => |e| {
            try jw.beginObject();
            try jw.objectField("Default");
            // CURRENT_TIMESTAMP, CURRENT_DATE, NOW() etc. are parsed as Identifier
            // but should be emitted as zero-arg Function calls.
            const zero_arg_fns = [_][]const u8{
                "CURRENT_TIMESTAMP", "CURRENT_DATE",   "CURRENT_TIME",
                "LOCALTIME",         "LOCALTIMESTAMP", "NOW",
                "SYSDATE",
            };
            const is_zero_arg_fn = switch (e) {
                .identifier => |id| blk: {
                    for (zero_arg_fns) |fn_name| {
                        if (std.ascii.eqlIgnoreCase(id.value, fn_name)) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
            if (is_zero_arg_fn) {
                const id = e.identifier;
                try jw.beginObject();
                try jw.objectField("Function");
                try jw.beginObject();
                try jw.objectField("name");
                try jw.beginArray();
                try jw.beginObject();
                try jw.objectField("Identifier");
                try writeIdent(jw, id);
                try jw.endObject();
                try jw.endArray();
                try jw.objectField("uses_odbc_syntax");
                try jw.write(false);
                try jw.objectField("parameters");
                try jw.write("None");
                try jw.objectField("args");
                try jw.write("None");
                try jw.objectField("filter");
                try jw.write(null);
                try jw.objectField("null_treatment");
                try jw.write(null);
                try jw.objectField("over");
                try jw.write(null);
                try jw.objectField("within_group");
                try jw.beginArray();
                try jw.endArray();
                try jw.endObject();
                try jw.endObject();
            } else {
                try writeExpr(jw, e);
            }
            try jw.endObject();
        },
        .primary_key => {
            try jw.beginObject();
            try jw.objectField("PrimaryKey");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(null);
            try jw.objectField("index_name");
            try jw.write(null);
            try jw.objectField("index_type");
            try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("index_options");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("characteristics");
            try jw.write(null);
            try jw.endObject(); // end inner PrimaryKey object
            try jw.endObject(); // end outer wrapper object
        },
        .unique => {
            try jw.beginObject();
            try jw.objectField("Unique");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(null);
            try jw.objectField("index_name");
            try jw.write(null);
            try jw.objectField("index_type_display");
            try jw.write("None");
            try jw.objectField("index_type");
            try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("index_options");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("characteristics");
            try jw.write(null);
            try jw.objectField("nulls_distinct");
            try jw.write("None");
            try jw.endObject(); // end inner Unique object
            try jw.endObject(); // end outer wrapper object
        },
        .foreign_key => |fk| {
            try jw.beginObject();
            try jw.objectField("ForeignKey");
            try jw.beginObject();
            try jw.objectField("foreign_table");
            try writeObjectName(jw, fk.foreign_table);
            try jw.objectField("referred_columns");
            try jw.beginArray();
            for (fk.referred_columns) |c| try writeIdent(jw, c);
            try jw.endArray();
            try jw.objectField("on_delete");
            if (fk.on_delete) |a| try jw.write(@tagName(a)) else try jw.write(null);
            try jw.objectField("on_update");
            if (fk.on_update) |a| try jw.write(@tagName(a)) else try jw.write(null);
            try jw.endObject();
            try jw.endObject();
        },
        .check => |e| {
            try jw.beginObject();
            try jw.objectField("Check");
            try writeExpr(jw, e);
            try jw.endObject();
        },
        .auto_increment => {
            try jw.beginObject();
            try jw.objectField("DialectSpecific");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("Word");
            try jw.beginObject();
            try jw.objectField("value");
            try jw.write("AUTO_INCREMENT");
            try jw.objectField("quote_style");
            try jw.write(null);
            try jw.objectField("keyword");
            try jw.write("AUTO_INCREMENT");
            try jw.endObject();
            try jw.endObject();
            try jw.endArray();
            try jw.endObject();
        },
        .comment => |s| {
            try jw.beginObject();
            try jw.objectField("Comment");
            try jw.write(s);
            try jw.endObject();
        },
        .character_set => |on| {
            try jw.beginObject();
            try jw.objectField("CharacterSet");
            try writeObjectName(jw, on);
            try jw.endObject();
        },
        .collate => |on| {
            try jw.beginObject();
            try jw.objectField("Collate");
            try writeObjectName(jw, on);
            try jw.endObject();
        },
        .on_update => |e| {
            try jw.beginObject();
            try jw.objectField("OnUpdate");
            try writeExpr(jw, e);
            try jw.endObject();
        },
        .generated => |g| {
            try jw.beginObject();
            try jw.objectField("Generated");
            try jw.beginObject();
            try jw.objectField("generated_as");
            try jw.write(@tagName(g.generated_as));
            try jw.objectField("generation_expr");
            if (g.generation_expr) |e| try writeExpr(jw, e.*) else try jw.write(null);
            try jw.objectField("generation_expr_mode");
            if (g.generation_expr_mode) |m| try jw.write(@tagName(m)) else try jw.write(null);
            try jw.endObject();
            try jw.endObject();
        },
        .invisible => {
            try jw.beginObject();
            try jw.objectField("Invisible");
            try jw.write(null);
            try jw.endObject();
        },
    }
}

/// Write an ident as an index column: {column: {expr: {Identifier: ...}, options: {asc: null, nulls_first: null}, with_fill: null}, operator_class: null}
fn writeIdentAsIndexColumn(jw: *Jw, id: ast.Ident) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("column");
    try jw.beginObject();
    try jw.objectField("expr");
    try writeExpr(jw, .{ .identifier = id });
    try jw.objectField("options");
    try jw.beginObject();
    try jw.objectField("asc");
    try jw.write(null);
    try jw.objectField("nulls_first");
    try jw.write(null);
    try jw.endObject();
    try jw.objectField("with_fill");
    try jw.write(null);
    try jw.endObject();
    try jw.objectField("operator_class");
    try jw.write(null);
    try jw.endObject();
}

fn writeTableConstraint(jw: *Jw, tc: ast_ddl.TableConstraint) Jw.Error!void {
    try jw.beginObject();
    switch (tc) {
        .primary_key => |pk| {
            try jw.objectField("PrimaryKey");
            try jw.beginObject();
            try jw.objectField("name");
            if (pk.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("index_name");
            try jw.write(null);
            try jw.objectField("index_type");
            try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            for (pk.columns) |c| try writeIdentAsIndexColumn(jw, c);
            try jw.endArray();
            try jw.objectField("index_options");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("characteristics");
            try jw.write(null);
            try jw.endObject();
        },
        .unique => |u| {
            try jw.objectField("Unique");
            try jw.beginObject();
            try jw.objectField("name");
            if (u.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("index_name");
            try jw.write(null);
            try jw.objectField("index_type_display");
            try jw.write("None");
            try jw.objectField("index_type");
            try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            for (u.columns) |c| try writeIdentAsIndexColumn(jw, c);
            try jw.endArray();
            try jw.objectField("index_options");
            try jw.beginArray();
            try jw.endArray();
            try jw.objectField("characteristics");
            try jw.write(null);
            try jw.objectField("nulls_distinct");
            try jw.write("None");
            try jw.endObject();
        },
        .foreign_key => |fk| {
            try jw.objectField("ForeignKey");
            try jw.beginObject();
            try jw.objectField("name");
            if (fk.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("index_name");
            try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            for (fk.columns) |c| try writeIdent(jw, c);
            try jw.endArray();
            try jw.objectField("foreign_table");
            try writeObjectName(jw, fk.foreign_table);
            try jw.objectField("referred_columns");
            try jw.beginArray();
            for (fk.referred_columns) |c| try writeIdent(jw, c);
            try jw.endArray();
            try jw.objectField("on_delete");
            if (fk.on_delete) |a| try jw.write(@tagName(a)) else try jw.write(null);
            try jw.objectField("on_update");
            if (fk.on_update) |a| try jw.write(@tagName(a)) else try jw.write(null);
            try jw.objectField("match_kind");
            try jw.write(null);
            try jw.objectField("characteristics");
            try jw.write(null);
            try jw.endObject();
        },
        .check => |c| {
            try jw.objectField("Check");
            try jw.beginObject();
            try jw.objectField("name");
            if (c.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("expr");
            try writeExpr(jw, c.expr);
            try jw.endObject();
        },
        .index => |idx| {
            try jw.objectField("Index");
            try jw.beginObject();
            try jw.objectField("name");
            if (idx.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            for (idx.columns) |c| try writeIdentAsIndexColumn(jw, c);
            try jw.endArray();
            try jw.endObject();
        },
        .fulltext => |ft| {
            try jw.objectField("Fulltext");
            try jw.beginObject();
            try jw.objectField("name");
            if (ft.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            for (ft.columns) |c| try writeIdentAsIndexColumn(jw, c);
            try jw.endArray();
            try jw.endObject();
        },
        .spatial => |sp| {
            try jw.objectField("Spatial");
            try jw.beginObject();
            try jw.objectField("name");
            if (sp.name) |n| try writeIdent(jw, n) else try jw.write(null);
            try jw.objectField("columns");
            try jw.beginArray();
            for (sp.columns) |c| try writeIdentAsIndexColumn(jw, c);
            try jw.endArray();
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeAlterTable(jw: *Jw, at: ast_ddl.AlterTable) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try writeObjectName(jw, at.name);
    try jw.objectField("if_exists");
    try jw.write(at.if_exists);
    try jw.objectField("only");
    try jw.write(false);
    try jw.objectField("operations");
    try jw.beginArray();
    for (at.operations) |op| try writeAlterTableOp(jw, op);
    try jw.endArray();
    try jw.objectField("location");
    try jw.write(null);
    try jw.objectField("on_cluster");
    try jw.write(null);
    try jw.objectField("table_type");
    try jw.write(null);
    try jw.objectField("end_token");
    if (at.end_token) |et| try writeTokenWithSpan(jw, et) else try jw.write(null);
    try jw.endObject();
}

fn writeAlterTableOp(jw: *Jw, op: ast_ddl.AlterTableOperation) Jw.Error!void {
    try jw.beginObject();
    switch (op) {
        .add_column => |ac| {
            try jw.objectField("AddColumn");
            try jw.beginObject();
            try jw.objectField("column_keyword");
            try jw.write(ac.column_keyword);
            try jw.objectField("if_not_exists");
            try jw.write(ac.if_not_exists);
            try jw.objectField("column_def");
            try writeColumnDef(jw, ac.column_def);
            try jw.objectField("column_position");
            if (ac.column_position) |cp| try writeMysqlColumnPosition(jw, cp) else try jw.write(null);
            try jw.endObject();
        },
        .drop_column => |dc| {
            try jw.objectField("DropColumn");
            try jw.beginObject();
            try jw.objectField("has_column_keyword");
            try jw.write(true);
            try jw.objectField("column_names");
            try jw.beginArray();
            try writeIdent(jw, dc.column_name);
            try jw.endArray();
            try jw.objectField("if_exists");
            try jw.write(dc.if_exists);
            try jw.objectField("drop_behavior");
            if (dc.drop_behavior) |db| try jw.write(@tagName(db)) else try jw.write(null);
            try jw.endObject();
        },
        .modify_column => |mc| {
            try jw.objectField("ModifyColumn");
            try jw.beginObject();
            try jw.objectField("col_name");
            try writeIdent(jw, mc.col_name);
            try jw.objectField("data_type");
            try writeDataType(jw, mc.data_type);
            try jw.objectField("options");
            try jw.beginArray();
            for (mc.options) |opt| {
                try jw.beginObject();
                try jw.objectField("name");
                if (opt.name) |n| try writeIdent(jw, n) else try jw.write(null);
                try jw.objectField("option");
                try writeColumnOption(jw, opt.option);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.objectField("column_position");
            if (mc.column_position) |cp| try writeMysqlColumnPosition(jw, cp) else try jw.write(null);
            try jw.endObject();
        },
        .change_column => |cc| {
            try jw.objectField("ChangeColumn");
            try jw.beginObject();
            try jw.objectField("old_name");
            try writeIdent(jw, cc.old_name);
            try jw.objectField("new_name");
            try writeIdent(jw, cc.new_name);
            try jw.objectField("data_type");
            try writeDataType(jw, cc.data_type);
            try jw.objectField("options");
            try jw.beginArray();
            for (cc.options) |opt| {
                try jw.beginObject();
                try jw.objectField("name");
                if (opt.name) |n| try writeIdent(jw, n) else try jw.write(null);
                try jw.objectField("option");
                try writeColumnOption(jw, opt.option);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.objectField("column_position");
            if (cc.column_position) |cp| try writeMysqlColumnPosition(jw, cp) else try jw.write(null);
            try jw.endObject();
        },
        .rename_column => |rc| {
            try jw.objectField("RenameColumn");
            try jw.beginObject();
            try jw.objectField("old_column_name");
            try writeIdent(jw, rc.old_column_name);
            try jw.objectField("new_column_name");
            try writeIdent(jw, rc.new_column_name);
            try jw.endObject();
        },
        .rename_table => |on| {
            try jw.objectField("RenameTable");
            try writeObjectName(jw, on);
        },
        .add_constraint => |ac| {
            try jw.objectField("AddConstraint");
            try jw.beginObject();
            try jw.objectField("constraint");
            try writeTableConstraint(jw, ac.constraint);
            try jw.objectField("not_valid");
            try jw.write(ac.not_valid);
            try jw.endObject();
        },
        .drop_constraint => |dc| {
            try jw.objectField("DropConstraint");
            try jw.beginObject();
            try jw.objectField("if_exists");
            try jw.write(dc.if_exists);
            try jw.objectField("name");
            try writeIdent(jw, dc.name);
            try jw.objectField("drop_behavior");
            if (dc.drop_behavior) |db| try jw.write(@tagName(db)) else try jw.write(null);
            try jw.endObject();
        },
        .drop_primary_key => {
            try jw.objectField("DropPrimaryKey");
            try jw.write(null);
        },
        .drop_index => |id| {
            try jw.objectField("DropIndex");
            try writeIdent(jw, id);
        },
        .alter_column => |ac| {
            try jw.objectField("AlterColumn");
            try jw.beginObject();
            try jw.objectField("column_name");
            try writeIdent(jw, ac.column_name);
            try jw.objectField("op");
            try writeAlterColumnOp(jw, ac.op);
            try jw.endObject();
        },
    }
    try jw.endObject();
}

fn writeMysqlColumnPosition(jw: *Jw, cp: ast_ddl.MySQLColumnPosition) Jw.Error!void {
    try jw.beginObject();
    switch (cp) {
        .first => {
            try jw.objectField("First");
            try jw.write(null);
        },
        .after => |id| {
            try jw.objectField("After");
            try writeIdent(jw, id);
        },
    }
    try jw.endObject();
}

fn writeAlterColumnOp(jw: *Jw, op: ast_ddl.AlterColumnOperation) Jw.Error!void {
    try jw.beginObject();
    switch (op) {
        .set_not_null => {
            try jw.objectField("SetNotNull");
            try jw.write(null);
        },
        .drop_not_null => {
            try jw.objectField("DropNotNull");
            try jw.write(null);
        },
        .set_default => |e| {
            try jw.objectField("SetDefault");
            try writeExpr(jw, e);
        },
        .drop_default => {
            try jw.objectField("DropDefault");
            try jw.write(null);
        },
        .set_data_type => |sdt| {
            try jw.objectField("SetDataType");
            try writeDataType(jw, sdt.data_type);
        },
    }
    try jw.endObject();
}

fn writeDrop(jw: *Jw, d: ast_ddl.Drop) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("object_type");
    try jw.write(switch (d.object_type) {
        .table => "Table",
        .index => "Index",
        .view => "View",
        .database => "Database",
    });
    try jw.objectField("if_exists");
    try jw.write(d.if_exists);
    try jw.objectField("names");
    try jw.beginArray();
    for (d.names) |on| try writeObjectName(jw, on);
    try jw.endArray();
    try jw.objectField("cascade");
    try jw.write(if (d.drop_behavior) |db| db == .cascade else false);
    try jw.objectField("restrict");
    try jw.write(if (d.drop_behavior) |db| db == .restrict else false);
    try jw.objectField("purge");
    try jw.write(false);
    try jw.objectField("temporary");
    try jw.write(d.temporary);
    try jw.objectField("table");
    if (d.on_table) |on| try writeObjectName(jw, on) else try jw.write(null);
    try jw.endObject();
}

fn writeCreateIndex(jw: *Jw, ci: ast_ddl.CreateIndex) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    if (ci.name) |n| try writeObjectName(jw, n) else try jw.write(null);
    try jw.objectField("table_name");
    try writeObjectName(jw, ci.table_name);
    try jw.objectField("using");
    if (ci.using) |u| try jw.write(u) else try jw.write(null);
    try jw.objectField("columns");
    try jw.beginArray();
    for (ci.columns) |col| {
        try jw.beginObject();
        try jw.objectField("column");
        try jw.beginObject();
        try jw.objectField("expr");
        try writeExpr(jw, col.column);
        try jw.objectField("options");
        try jw.beginObject();
        try jw.objectField("asc");
        try jw.write(null);
        try jw.objectField("nulls_first");
        try jw.write(null);
        try jw.endObject();
        try jw.objectField("with_fill");
        try jw.write(null);
        try jw.endObject();
        try jw.objectField("operator_class");
        try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("unique");
    try jw.write(ci.unique);
    try jw.objectField("concurrently");
    try jw.write(false);
    try jw.objectField("if_not_exists");
    try jw.write(ci.if_not_exists);
    try jw.objectField("include");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("nulls_distinct");
    try jw.write(null);
    try jw.objectField("with");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("predicate");
    try jw.write(null);
    try jw.objectField("index_options");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("alter_options");
    try jw.beginArray();
    try jw.endArray();
    try jw.endObject();
}

fn writeCreateView(jw: *Jw, cv: ast_ddl.CreateView) Jw.Error!void {
    try jw.beginObject();
    try jw.objectField("or_alter");
    try jw.write(false);
    try jw.objectField("or_replace");
    try jw.write(cv.or_replace);
    try jw.objectField("materialized");
    try jw.write(false);
    try jw.objectField("secure");
    try jw.write(false);
    try jw.objectField("name");
    try writeObjectName(jw, cv.name);
    try jw.objectField("name_before_not_exists");
    try jw.write(false);
    try jw.objectField("columns");
    try jw.beginArray();
    for (cv.columns) |c| try writeIdent(jw, c);
    try jw.endArray();
    try jw.objectField("query");
    try writeQuery(jw, cv.query.*);
    try jw.objectField("options");
    try jw.write("None");
    try jw.objectField("cluster_by");
    try jw.beginArray();
    try jw.endArray();
    try jw.objectField("comment");
    try jw.write(null);
    try jw.objectField("with_no_schema_binding");
    try jw.write(false);
    try jw.objectField("if_not_exists");
    try jw.write(false);
    try jw.objectField("temporary");
    try jw.write(false);
    try jw.objectField("to");
    try jw.write(null);
    try jw.objectField("params");
    try jw.write(null);
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Helper: serialize any AST node to a heap-allocated JSON string
// ---------------------------------------------------------------------------

/// Serialize a Value to an owned JSON string. Caller must free.
pub fn valueToJson(allocator: std.mem.Allocator, v: ast.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeValue(&jw, v);
    try aw.writer.flush();
    return try aw.toOwnedSlice();
}

/// Serialize an Expr to an owned JSON string. Caller must free.
pub fn exprToJson(allocator: std.mem.Allocator, expr: ast.Expr) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeExpr(&jw, expr);
    try aw.writer.flush();
    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeIdent JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    const id: ast.Ident = .{ .value = "users", .quote_style = null };
    try writeIdent(&jw, id);
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    // Must contain value field
    try std.testing.expect(std.mem.indexOf(u8, s, "\"users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"quote_style\":null") != null);
}

test "writeValue Number JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeValue(&jw, .{ .number = .{ .raw = "42", .is_long = false } });
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"Number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "false") != null);
}

test "writeValue SingleQuotedString JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeValue(&jw, .{ .single_quoted_string = "hello" });
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"SingleQuotedString\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"hello\"") != null);
}

test "writeValue null JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeValue(&jw, .null);
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expectEqualStrings("\"Null\"", s);
}

test "writeBinaryOp JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeBinaryOp(&jw, .Plus);
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expectEqualStrings("\"Plus\"", s);
}

test "writeExpr Identifier JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    const expr: ast.Expr = .{ .identifier = .{ .value = "myCol", .quote_style = null } };
    try writeExpr(&jw, expr);
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"Identifier\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"myCol\"") != null);
}

test "writeExpr BinaryOp JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    const left: ast.Expr = .{ .identifier = .{ .value = "a", .quote_style = null } };
    const right: ast.Expr = .{ .value = .{ .val = .{ .number = .{ .raw = "1", .is_long = false } } } };
    const expr: ast.Expr = .{ .binary_op = .{ .left = &left, .op = .Gt, .right = &right } };
    try writeExpr(&jw, expr);
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"BinaryOp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"Gt\"") != null);
}

test "writeDataType Int JSON" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: Jw = .{ .writer = &aw.writer, .options = .{} };
    try writeDataType(&jw, .{ .int = null });
    try aw.writer.flush();
    const s = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"Int\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "null") != null);
}
