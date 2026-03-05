const std = @import("std");

/// Optimal vector length in bytes for the current target, or null when SIMD is unavailable.
pub const vector_len: ?comptime_int = std.simd.suggestVectorLength(u8);

/// True when SIMD byte scanning is available on this target.
pub const has_simd: bool = vector_len != null;

/// The native SIMD vector type for byte scanning (void when unavailable).
const Vec = if (vector_len) |len| @Vector(len, u8) else void;

/// Packed bitmask matching the vector width (void when unavailable).
const Mask = if (vector_len) |len| std.meta.Int(.unsigned, len) else void;

// ---------------------------------------------------------------------------
// Public scanning functions
// ---------------------------------------------------------------------------

/// Find the end of an identifier run starting at `pos`.
/// Identifiers consist of [a-zA-Z0-9_]. Returns the index of the first
/// byte that is NOT an identifier character, or `input.len` if the entire
/// tail is identifier characters.
pub fn findIdentifierEnd(input: []const u8, pos: usize) usize {
    if (vector_len) |vl| {
        var i = pos;
        while (i + vl <= input.len) {
            const chunk: *const [vl]u8 = @ptrCast(input[i..][0..vl]);
            const vec: Vec = chunk.*;
            const match = identMask(vec);
            if (match != 0) return i + @ctz(match);
            i += vl;
        }
        // Scalar tail
        return findIdentifierEndScalar(input, i);
    }
    return findIdentifierEndScalar(input, pos);
}

/// Find the end of a digit run starting at `pos`.
/// Returns the index of the first byte that is NOT in [0-9], or `input.len`.
pub fn findNumberEnd(input: []const u8, pos: usize) usize {
    if (vector_len) |vl| {
        var i = pos;
        while (i + vl <= input.len) {
            const chunk: *const [vl]u8 = @ptrCast(input[i..][0..vl]);
            const vec: Vec = chunk.*;
            const not_digit = ~digitMask(vec);
            if (not_digit != 0) return i + @ctz(not_digit);
            i += vl;
        }
        return findNumberEndScalar(input, i);
    }
    return findNumberEndScalar(input, pos);
}

/// Find the position of the closing quote or an escape character within a
/// quoted string.  Scanning starts at `pos` (which should point to the byte
/// after the opening quote). Returns the index of the first `quote` byte or
/// backslash (when `backslash_escape` is true), or `input.len` if neither
/// is found.
pub fn findQuoteEnd(input: []const u8, pos: usize, quote: u8, backslash_escape: bool) usize {
    if (vector_len) |vl| {
        var i = pos;
        while (i + vl <= input.len) {
            const chunk: *const [vl]u8 = @ptrCast(input[i..][0..vl]);
            const vec: Vec = chunk.*;
            const is_quote: Mask = @bitCast(vec == @as(Vec, @splat(quote)));
            const is_escape: Mask = if (backslash_escape)
                @bitCast(vec == @as(Vec, @splat('\\')))
            else
                0;
            const interesting = is_quote | is_escape;
            if (interesting != 0) return i + @ctz(interesting);
            i += vl;
        }
        return findQuoteEndScalar(input, i, quote, backslash_escape);
    }
    return findQuoteEndScalar(input, pos, quote, backslash_escape);
}

/// Find the first non-whitespace character starting at `pos`.
/// Whitespace here means ' ' or '\t' only -- newlines are excluded so
/// the caller can handle line tracking individually.
/// Returns the index of the first non-space/non-tab byte, or `input.len`.
pub fn findNonWhitespace(input: []const u8, pos: usize) usize {
    if (vector_len) |vl| {
        var i = pos;
        while (i + vl <= input.len) {
            const chunk: *const [vl]u8 = @ptrCast(input[i..][0..vl]);
            const vec: Vec = chunk.*;
            const is_space: @Vector(vl, bool) = vec == @as(Vec, @splat(' '));
            const is_tab: @Vector(vl, bool) = vec == @as(Vec, @splat('\t'));
            const is_ws = is_space | is_tab;
            const not_ws: Mask = @bitCast(~is_ws);
            if (not_ws != 0) return i + @ctz(not_ws);
            i += vl;
        }
        return findNonWhitespaceScalar(input, i);
    }
    return findNonWhitespaceScalar(input, pos);
}

// ---------------------------------------------------------------------------
// Scalar fallback implementations
// ---------------------------------------------------------------------------

fn findIdentifierEndScalar(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (!isIdentifierPart(c)) return i;
    }
    return i;
}

fn findNumberEndScalar(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c < '0' or c > '9') return i;
    }
    return i;
}

fn findQuoteEndScalar(input: []const u8, start: usize, quote: u8, backslash_escape: bool) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == quote) return i;
        if (backslash_escape and c == '\\') return i;
    }
    return i;
}

fn findNonWhitespaceScalar(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c != ' ' and c != '\t') return i;
    }
    return i;
}

// ---------------------------------------------------------------------------
// SIMD helper predicates
// ---------------------------------------------------------------------------

/// Returns a bitmask where bit N is set if byte N is NOT an identifier char.
fn identMask(vec: Vec) Mask {
    const vl = vector_len.?;
    const ge_a: @Vector(vl, bool) = vec >= @as(Vec, @splat('a'));
    const le_z: @Vector(vl, bool) = vec <= @as(Vec, @splat('z'));
    const is_az = ge_a & le_z;
    const ge_A: @Vector(vl, bool) = vec >= @as(Vec, @splat('A'));
    const le_Z: @Vector(vl, bool) = vec <= @as(Vec, @splat('Z'));
    const is_AZ = ge_A & le_Z;
    const ge_0: @Vector(vl, bool) = vec >= @as(Vec, @splat('0'));
    const le_9: @Vector(vl, bool) = vec <= @as(Vec, @splat('9'));
    const is_09 = ge_0 & le_9;
    const is_us: @Vector(vl, bool) = vec == @as(Vec, @splat('_'));
    const is_ident = is_az | is_AZ | is_09 | is_us;
    return @bitCast(~is_ident);
}

/// Returns a bitmask where bit N is set if byte N IS a digit [0-9].
fn digitMask(vec: Vec) Mask {
    const vl = vector_len.?;
    const ge_0: @Vector(vl, bool) = vec >= @as(Vec, @splat('0'));
    const le_9: @Vector(vl, bool) = vec <= @as(Vec, @splat('9'));
    const is_digit = ge_0 & le_9;
    return @bitCast(is_digit);
}

fn isIdentifierPart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "findIdentifierEnd: basic" {
    try std.testing.expectEqual(@as(usize, 6), findIdentifierEnd("SELECT FROM", 0));
    try std.testing.expectEqual(@as(usize, 5), findIdentifierEnd("hello world", 0));
    try std.testing.expectEqual(@as(usize, 11), findIdentifierEnd("hello world", 6));
}

test "findIdentifierEnd: underscore and digits" {
    try std.testing.expectEqual(@as(usize, 10), findIdentifierEnd("my_var_123 ", 0));
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("_foo+bar", 0));
}

test "findIdentifierEnd: entire input is identifier" {
    try std.testing.expectEqual(@as(usize, 8), findIdentifierEnd("longname", 0));
}

test "findIdentifierEnd: empty and start at end" {
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("", 0));
    try std.testing.expectEqual(@as(usize, 3), findIdentifierEnd("abc", 3));
}

test "findIdentifierEnd: non-identifier at position 0" {
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd(" abc", 0));
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("+abc", 0));
}

test "findIdentifierEnd: long input exceeding vector width" {
    // 200-byte identifier
    const long_ident = "a" ** 200;
    const input = long_ident ++ " rest";
    try std.testing.expectEqual(@as(usize, 200), findIdentifierEnd(input, 0));
}

test "findNumberEnd: basic" {
    try std.testing.expectEqual(@as(usize, 3), findNumberEnd("123abc", 0));
    try std.testing.expectEqual(@as(usize, 5), findNumberEnd("99999", 0));
}

test "findNumberEnd: empty and no digits" {
    try std.testing.expectEqual(@as(usize, 0), findNumberEnd("", 0));
    try std.testing.expectEqual(@as(usize, 0), findNumberEnd("abc", 0));
}

test "findNumberEnd: start offset" {
    try std.testing.expectEqual(@as(usize, 7), findNumberEnd("abc1234xyz", 3));
}

test "findNumberEnd: long number" {
    const long_num = "9" ** 200;
    const input = long_num ++ ".5";
    try std.testing.expectEqual(@as(usize, 200), findNumberEnd(input, 0));
}

test "findQuoteEnd: single quote no escape" {
    try std.testing.expectEqual(@as(usize, 5), findQuoteEnd("hello' rest", 0, '\'', false));
}

test "findQuoteEnd: single quote with backslash escape" {
    // Backslash should be found first
    try std.testing.expectEqual(@as(usize, 3), findQuoteEnd("abc\\n' rest", 0, '\'', true));
}

test "findQuoteEnd: double quote" {
    try std.testing.expectEqual(@as(usize, 3), findQuoteEnd("foo\" bar", 0, '"', false));
}

test "findQuoteEnd: no match returns input.len" {
    try std.testing.expectEqual(@as(usize, 10), findQuoteEnd("0123456789", 0, '\'', false));
}

test "findQuoteEnd: empty input" {
    try std.testing.expectEqual(@as(usize, 0), findQuoteEnd("", 0, '\'', false));
}

test "findQuoteEnd: long string" {
    const long_str = "x" ** 200;
    const input = long_str ++ "'end";
    try std.testing.expectEqual(@as(usize, 200), findQuoteEnd(input, 0, '\'', false));
}

test "findNonWhitespace: spaces and tabs" {
    try std.testing.expectEqual(@as(usize, 4), findNonWhitespace("    hello", 0));
    try std.testing.expectEqual(@as(usize, 3), findNonWhitespace("\t\t\thello", 0));
    try std.testing.expectEqual(@as(usize, 5), findNonWhitespace("  \t  X", 0));
}

test "findNonWhitespace: newline is not whitespace for this function" {
    try std.testing.expectEqual(@as(usize, 2), findNonWhitespace("  \nhello", 0));
}

test "findNonWhitespace: no whitespace" {
    try std.testing.expectEqual(@as(usize, 0), findNonWhitespace("hello", 0));
}

test "findNonWhitespace: all whitespace" {
    try std.testing.expectEqual(@as(usize, 5), findNonWhitespace("     ", 0));
}

test "findNonWhitespace: empty" {
    try std.testing.expectEqual(@as(usize, 0), findNonWhitespace("", 0));
}

test "findNonWhitespace: long whitespace run" {
    const long_ws = " " ** 200;
    const input = long_ws ++ "X";
    try std.testing.expectEqual(@as(usize, 200), findNonWhitespace(input, 0));
}

test "findIdentifierEnd: exactly vector width" {
    if (vector_len) |vl| {
        // Input exactly vl bytes of identifier chars
        const buf = "a" ** 128;
        const slice = buf[0..vl];
        try std.testing.expectEqual(vl, findIdentifierEnd(slice, 0));
    }
}

test "findIdentifierEnd: vector width minus one" {
    if (vector_len) |vl| {
        if (vl > 1) {
            const buf = "b" ** 127;
            const slice = buf[0 .. vl - 1];
            try std.testing.expectEqual(vl - 1, findIdentifierEnd(slice, 0));
        }
    }
}

test "findIdentifierEnd: vector width plus one" {
    if (vector_len) |vl| {
        const buf = "c" ** 129;
        const input = buf[0 .. vl + 1];
        try std.testing.expectEqual(vl + 1, findIdentifierEnd(input, 0));
    }
}

test "findIdentifierEnd: boundary characters" {
    // Test chars just outside identifier ranges
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("/abc", 0)); // '/' = '0' - 1
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd(":abc", 0)); // ':' = '9' + 1
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("@abc", 0)); // '@' = 'A' - 1
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("[abc", 0)); // '[' = 'Z' + 1
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("`abc", 0)); // '`' = 'a' - 1
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("{abc", 0)); // '{' = 'z' + 1
    // Underscore IS identifier
    try std.testing.expectEqual(@as(usize, 1), findIdentifierEnd("_+", 0));
}

test "findQuoteEnd: newline passthrough" {
    try std.testing.expectEqual(@as(usize, 7), findQuoteEnd("abc\ndef'", 0, '\'', false));
}

test "findNonWhitespace: start offset" {
    try std.testing.expectEqual(@as(usize, 6), findNonWhitespace("abc   X", 3));
}

test "findNumberEnd: boundary characters" {
    try std.testing.expectEqual(@as(usize, 0), findNumberEnd("/abc", 0)); // '/' = '0' - 1
    try std.testing.expectEqual(@as(usize, 0), findNumberEnd(":abc", 0)); // ':' = '9' + 1
}

test "SIMD availability check" {
    // This test just documents what the comptime detection decided
    if (has_simd) {
        try std.testing.expect(vector_len.? >= 8);
    }
}
