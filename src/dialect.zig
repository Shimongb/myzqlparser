const std = @import("std");

/// The two supported SQL dialects.
pub const DialectKind = enum {
    generic,
    mysql,
};

/// Dialect configuration used by the parser to make dialect-specific decisions.
pub const Dialect = struct {
    kind: DialectKind,

    // -----------------------------------------------------------------------
    // Factory helpers
    // -----------------------------------------------------------------------

    pub const generic: Dialect = .{ .kind = .generic };
    pub const mysql: Dialect = .{ .kind = .mysql };

    // -----------------------------------------------------------------------
    // Identifier character rules
    // -----------------------------------------------------------------------

    /// Returns true if ch is a valid first character of an unquoted identifier.
    pub fn isIdentifierStart(self: Dialect, ch: u8) bool {
        return switch (self.kind) {
            .generic => std.ascii.isAlphabetic(ch) or ch == '_' or ch == '#' or ch == '@',
            .mysql => std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$' or ch == '@' or ch > 127,
        };
    }

    /// Returns true if ch is a valid continuation character of an unquoted identifier.
    pub fn isIdentifierPart(self: Dialect, ch: u8) bool {
        return switch (self.kind) {
            .generic => std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '#' or ch == '@' or ch == '$',
            .mysql => self.isIdentifierStart(ch) or std.ascii.isDigit(ch),
        };
    }

    /// Returns the preferred quote character for identifiers produced by this dialect,
    /// or null if the dialect does not enforce a quote style.
    pub fn identifierQuoteStyle(self: Dialect) ?u8 {
        return switch (self.kind) {
            .generic => null,
            .mysql => '`',
        };
    }

    // -----------------------------------------------------------------------
    // String literal rules
    // -----------------------------------------------------------------------

    /// Returns true if the dialect treats backslash as an escape character inside
    /// single-quoted string literals.
    pub fn supportsBackslashEscape(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    // -----------------------------------------------------------------------
    // Aggregation / grouping behavior
    // -----------------------------------------------------------------------

    /// Returns true if the dialect supports FILTER (WHERE ...) on aggregate calls.
    pub fn supportsFilterDuringAggregation(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => false,
        };
    }

    /// Returns true if the dialect supports GROUP BY with arbitrary expressions
    /// such as ROLLUP / CUBE / GROUPING SETS.
    pub fn supportsGroupByExpr(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => false,
        };
    }

    // -----------------------------------------------------------------------
    // LIMIT clause behavior
    // -----------------------------------------------------------------------

    /// Returns true if the dialect supports the MySQL-style `LIMIT offset, count`
    /// syntax in addition to `LIMIT count OFFSET offset`.
    pub fn supportsLimitComma(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => true,
        };
    }

    // -----------------------------------------------------------------------
    // Interval qualifiers
    // -----------------------------------------------------------------------

    /// Returns true if the dialect requires an interval field qualifier
    /// (e.g. `INTERVAL '1' DAY` is valid, but `INTERVAL '1'` is not).
    pub fn requireIntervalQualifier(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    // -----------------------------------------------------------------------
    // MySQL-specific behavior
    // -----------------------------------------------------------------------

    /// Returns true if the dialect supports MySQL SELECT modifiers such as
    /// HIGH_PRIORITY, STRAIGHT_JOIN, SQL_SMALL_RESULT, SQL_BIG_RESULT,
    /// SQL_BUFFER_RESULT, SQL_NO_CACHE, SQL_CALC_FOUND_ROWS.
    pub fn supportsSelectModifiers(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports USE/FORCE/IGNORE INDEX hints
    /// in the FROM clause (MySQL table hints).
    pub fn supportsTableHints(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports the MATCH () AGAINST () syntax.
    pub fn supportsMatchAgainst(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports `INSERT INTO ... SET col = val` syntax.
    pub fn supportsInsertSet(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports CREATE TABLE ... SELECT.
    pub fn supportsCreateTableSelect(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports CONSTRAINT keyword without a name
    /// in table definitions (MySQL extension).
    pub fn supportsConstraintKeywordWithoutName(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports the BINARY <expr> cast syntax.
    pub fn supportsBinaryKwAsCast(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports bitwise shift operators (<< and >>).
    pub fn supportsBitwiseShiftOperators(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports the && operator as boolean AND.
    pub fn supportsDoubleAmpersandOperator(self: Dialect) bool {
        return switch (self.kind) {
            .generic => false,
            .mysql => true,
        };
    }

    /// Returns true if the dialect supports SET NAMES <charset>.
    pub fn supportsSetNames(self: Dialect) bool {
        return switch (self.kind) {
            .generic => true,
            .mysql => true,
        };
    }

    /// Returns true if this is the MySQL dialect.
    pub fn isMysql(self: Dialect) bool {
        return self.kind == .mysql;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Dialect generic identifier rules" {
    const d = Dialect.generic;
    try std.testing.expect(d.isIdentifierStart('a'));
    try std.testing.expect(d.isIdentifierStart('_'));
    try std.testing.expect(d.isIdentifierStart('#'));
    try std.testing.expect(!d.isIdentifierStart('1'));
    try std.testing.expect(d.isIdentifierPart('a'));
    try std.testing.expect(d.isIdentifierPart('0'));
    try std.testing.expect(d.isIdentifierPart('$'));
    try std.testing.expect(!d.isIdentifierPart(' '));
}

test "Dialect mysql identifier rules" {
    const d = Dialect.mysql;
    try std.testing.expect(d.isIdentifierStart('a'));
    try std.testing.expect(d.isIdentifierStart('_'));
    try std.testing.expect(d.isIdentifierStart('$'));
    try std.testing.expect(!d.isIdentifierStart('1'));
    try std.testing.expect(d.isIdentifierPart('a'));
    try std.testing.expect(d.isIdentifierPart('9'));
}

test "Dialect quote style" {
    try std.testing.expectEqual(@as(?u8, null), Dialect.generic.identifierQuoteStyle());
    try std.testing.expectEqual(@as(?u8, '`'), Dialect.mysql.identifierQuoteStyle());
}

test "Dialect backslash escape" {
    try std.testing.expect(!Dialect.generic.supportsBackslashEscape());
    try std.testing.expect(Dialect.mysql.supportsBackslashEscape());
}

test "Dialect limit comma" {
    try std.testing.expect(Dialect.generic.supportsLimitComma());
    try std.testing.expect(Dialect.mysql.supportsLimitComma());
}
