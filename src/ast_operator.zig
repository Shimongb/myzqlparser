const std = @import("std");

/// Unary SQL operators (prefix or postfix).
pub const UnaryOp = enum {
    /// Unary plus, e.g. `+9`
    Plus,
    /// Unary minus, e.g. `-9`
    Minus,
    /// Logical NOT, e.g. `NOT true`
    Not,
    /// Bitwise NOT, e.g. `~9`
    BitwiseNot,

    /// Returns the SQL token string for this operator.
    pub fn toSql(self: UnaryOp) []const u8 {
        return switch (self) {
            .Plus => "+",
            .Minus => "-",
            .Not => "NOT",
            .BitwiseNot => "~",
        };
    }
};

/// Binary SQL operators.
pub const BinaryOp = enum {
    /// `a + b`
    Plus,
    /// `a - b`
    Minus,
    /// `a * b`
    Multiply,
    /// `a / b`
    Divide,
    /// `a % b`
    Modulo,
    /// `a || b` (string concatenation)
    StringConcat,
    /// `a > b`
    Gt,
    /// `a < b`
    Lt,
    /// `a >= b`
    GtEq,
    /// `a <= b`
    LtEq,
    /// `a <=> b` (MySQL NULL-safe equality)
    Spaceship,
    /// `a = b`
    Eq,
    /// `a <> b` or `a != b`
    NotEq,
    /// `a AND b`
    And,
    /// `a OR b`
    Or,
    /// `a XOR b`
    Xor,
    /// `a | b`
    BitwiseOr,
    /// `a & b`
    BitwiseAnd,
    /// `a ^ b`
    BitwiseXor,
    /// MySQL `DIV` integer division, e.g. `10 DIV 3`
    MyIntegerDivide,
    /// MySQL `:=` assignment operator
    Assignment,
    /// `a << b`
    ShiftLeft,
    /// `a >> b`
    ShiftRight,
    /// `a REGEXP b`
    Regexp,
    /// OVERLAPS, e.g. `(t1.start, t1.end) OVERLAPS (t2.start, t2.end)`
    Overlaps,

    /// Returns the SQL token string for this operator.
    pub fn toSql(self: BinaryOp) []const u8 {
        return switch (self) {
            .Plus => "+",
            .Minus => "-",
            .Multiply => "*",
            .Divide => "/",
            .Modulo => "%",
            .StringConcat => "||",
            .Gt => ">",
            .Lt => "<",
            .GtEq => ">=",
            .LtEq => "<=",
            .Spaceship => "<=>",
            .Eq => "=",
            .NotEq => "<>",
            .And => "AND",
            .Or => "OR",
            .Xor => "XOR",
            .BitwiseOr => "|",
            .BitwiseAnd => "&",
            .BitwiseXor => "^",
            .ShiftLeft => "<<",
            .ShiftRight => ">>",
            .MyIntegerDivide => "DIV",
            .Assignment => ":=",
            .Regexp => "REGEXP",
            .Overlaps => "OVERLAPS",
        };
    }
};

test "UnaryOp.toSql" {
    try std.testing.expectEqualStrings("+", UnaryOp.Plus.toSql());
    try std.testing.expectEqualStrings("NOT", UnaryOp.Not.toSql());
    try std.testing.expectEqualStrings("~", UnaryOp.BitwiseNot.toSql());
}

test "BinaryOp.toSql" {
    try std.testing.expectEqualStrings("AND", BinaryOp.And.toSql());
    try std.testing.expectEqualStrings("DIV", BinaryOp.MyIntegerDivide.toSql());
    try std.testing.expectEqualStrings("<=>", BinaryOp.Spaceship.toSql());
    try std.testing.expectEqualStrings(":=", BinaryOp.Assignment.toSql());
}
