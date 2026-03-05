const std = @import("std");
const span = @import("span.zig");
const keywords = @import("keywords.zig");
const errors = @import("errors.zig");
const simd = @import("simd.zig");

pub const Location = span.Location;
pub const Span = span.Span;
pub const Keyword = keywords.Keyword;
pub const TokenizerError = errors.TokenizerError;

/// Whitespace variants tracked in the token stream.
pub const Whitespace = union(enum) {
    Space,
    Newline,
    Tab,
    /// A single-line comment (-- or #). The comment field includes the newline.
    SingleLineComment: struct { prefix: []const u8, comment: []const u8 },
    /// A block comment (/* ... */). The content excludes delimiters.
    MultiLineComment: []const u8,
};

/// A keyword or optionally quoted identifier.
pub const Word = struct {
    /// The identifier value, without enclosing quotes.
    value: []const u8,
    /// Quote character if the identifier was delimited (e.g. `"`, `` ` ``).
    /// Null means unquoted.
    quote_style: ?u8,
    /// Keyword matched for unquoted words. NoKeyword if not recognized.
    keyword: Keyword,
};

/// All token variants produced by the tokenizer.
pub const Token = union(enum) {
    /// End of input.
    EOF,
    /// A keyword or identifier.
    Word: Word,
    /// An unsigned numeric literal. The bool indicates a trailing 'L' suffix.
    Number: struct { value: []const u8, long: bool },
    /// A character that could not be tokenized.
    Char: u8,
    /// Single-quoted string: 'string'
    SingleQuotedString: []const u8,
    /// Double-quoted string.
    DoubleQuotedString: []const u8,
    /// Hex string literal: X'deadbeef'
    HexStringLiteral: []const u8,
    /// National string literal: N'...'
    NationalStringLiteral: []const u8,
    /// Byte string literal: B'...'
    SingleQuotedByteStringLiteral: []const u8,
    Comma,
    Whitespace: Whitespace,
    DoubleEq,
    Eq,
    Neq,
    Lt,
    Gt,
    LtEq,
    GtEq,
    /// MySQL NULL-safe equality: <=>
    Spaceship,
    Plus,
    Minus,
    Mul,
    Div,
    Mod,
    /// String concatenation: ||
    StringConcat,
    LParen,
    RParen,
    Period,
    Colon,
    /// :: (PostgreSQL cast)
    DoubleColon,
    /// := (assignment)
    Assignment,
    SemiColon,
    Backslash,
    LBracket,
    RBracket,
    Ampersand,
    Pipe,
    Caret,
    LBrace,
    RBrace,
    /// => (right arrow)
    RArrow,
    Sharp,
    Tilde,
    ExclamationMark,
    AtSign,
    ShiftLeft,
    ShiftRight,
    /// Prepared statement placeholder: ? or $N
    Placeholder: []const u8,
};

/// A Token with its source location (Span).
pub const TokenWithSpan = struct {
    token: Token,
    span: Span,

    pub fn wrap(token: Token) TokenWithSpan {
        return .{ .token = token, .span = Span.empty };
    }

    pub fn at(token: Token, start: Location, end: Location) TokenWithSpan {
        return .{ .token = token, .span = Span.init(start, end) };
    }
};

/// Controls tokenizer dialect behavior.
pub const Dialect = enum {
    Generic,
    MySQL,
};

/// Internal scan state (position + line tracking).
const State = struct {
    input: []const u8,
    pos: usize,
    line: u64,
    col: u64,

    fn init(input: []const u8) State {
        return .{ .input = input, .pos = 0, .line = 1, .col = 1 };
    }

    fn peek(self: *const State) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn peekN(self: *const State, n: usize) ?u8 {
        const idx = self.pos + n;
        if (idx >= self.input.len) return null;
        return self.input[idx];
    }

    fn next(self: *State) ?u8 {
        if (self.pos >= self.input.len) return null;
        const ch = self.input[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return ch;
    }

    /// Advance position to `new_pos` when the skipped bytes contain no newlines.
    /// Updates col by the distance jumped.
    fn advanceTo(self: *State, new_pos: usize) void {
        self.col += new_pos - self.pos;
        self.pos = new_pos;
    }

    /// Advance position to `new_pos`, scanning skipped bytes for newlines
    /// to keep line/col accurate. Use for regions that may contain newlines
    /// (e.g. string literals).
    fn advanceToWithLineTracking(self: *State, new_pos: usize) void {
        for (self.input[self.pos..new_pos]) |c| {
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        self.pos = new_pos;
    }

    fn location(self: *const State) Location {
        return Location.init(self.line, self.col);
    }
};

/// The SQL tokenizer. Produces a list of TokenWithSpan from a SQL string.
///
/// On failure, `tokenize` and `tokenizeWithLocation` return `error.TokenizerError`.
/// Inspect the `err` field for the message and source location.
pub const Tokenizer = struct {
    dialect: Dialect,
    input: []const u8,
    /// Populated when tokenization fails. Null on success.
    err: ?TokenizerError = null,

    pub fn init(dialect: Dialect, input: []const u8) Tokenizer {
        return .{ .dialect = dialect, .input = input };
    }

    /// Tokenize the SQL input and return all tokens with spans.
    /// Caller is responsible for freeing the returned slice.
    /// On error, inspect `self.err` for details.
    pub fn tokenizeWithLocation(
        self: *Tokenizer,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, TokenizerError }![]TokenWithSpan {
        var buf: std.ArrayList(TokenWithSpan) = .empty;
        errdefer buf.deinit(allocator);

        var state = State.init(self.input);
        while (true) {
            const start = state.location();
            const tok = try self.nextToken(&state) orelse break;
            const end = state.location();
            try buf.append(allocator, TokenWithSpan.at(tok, start, end));
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Tokenize and return tokens without span info.
    /// On error, inspect `self.err` for details.
    pub fn tokenize(
        self: *Tokenizer,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, TokenizerError }![]Token {
        var buf: std.ArrayList(Token) = .empty;
        errdefer buf.deinit(allocator);

        var state = State.init(self.input);
        while (true) {
            const tok = try self.nextToken(&state) orelse break;
            try buf.append(allocator, tok);
        }
        return buf.toOwnedSlice(allocator);
    }

    // -----------------------------------------------------------------------
    // Core dispatch
    // -----------------------------------------------------------------------

    fn nextToken(self: *Tokenizer, s: *State) error{TokenizerError}!?Token {
        const ch = s.peek() orelse return null;

        return switch (ch) {
            ' ' => blk: {
                _ = s.next();
                break :blk Token{ .Whitespace = .Space };
            },
            '\t' => blk: {
                _ = s.next();
                break :blk Token{ .Whitespace = .Tab };
            },
            '\n' => blk: {
                _ = s.next();
                break :blk Token{ .Whitespace = .Newline };
            },
            '\r' => blk: {
                _ = s.next();
                if (s.peek() == '\n') _ = s.next();
                break :blk Token{ .Whitespace = .Newline };
            },
            '\'' => try self.tokenizeSingleQuotedString(s, '\''),
            '"' => try self.tokenizeDoubleQuotedOrIdentifier(s),
            '`' => if (self.dialect == .MySQL)
                try self.tokenizeQuotedIdentifier(s, '`')
            else blk: {
                _ = s.next();
                break :blk Token{ .Char = '`' };
            },
            '0'...'9' => try self.tokenizeNumber(s),
            '.' => try self.tokenizePeriodOrNumber(s),
            '(' => blk: {
                _ = s.next();
                break :blk .LParen;
            },
            ')' => blk: {
                _ = s.next();
                break :blk .RParen;
            },
            ',' => blk: {
                _ = s.next();
                break :blk .Comma;
            },
            ';' => blk: {
                _ = s.next();
                break :blk .SemiColon;
            },
            '[' => blk: {
                _ = s.next();
                break :blk .LBracket;
            },
            ']' => blk: {
                _ = s.next();
                break :blk .RBracket;
            },
            '{' => blk: {
                _ = s.next();
                break :blk .LBrace;
            },
            '}' => blk: {
                _ = s.next();
                break :blk .RBrace;
            },
            '\\' => blk: {
                _ = s.next();
                break :blk .Backslash;
            },
            '-' => try self.tokenizeMinus(s),
            '/' => try self.tokenizeSlash(s),
            '+' => blk: {
                _ = s.next();
                break :blk .Plus;
            },
            '*' => blk: {
                _ = s.next();
                break :blk .Mul;
            },
            '%' => blk: {
                _ = s.next();
                break :blk .Mod;
            },
            '|' => try self.tokenizePipe(s),
            '=' => try self.tokenizeEq(s),
            '!' => try self.tokenizeExclamation(s),
            '<' => try self.tokenizeLt(s),
            '>' => try self.tokenizeGt(s),
            ':' => try self.tokenizeColon(s),
            '&' => blk: {
                _ = s.next();
                break :blk .Ampersand;
            },
            '^' => blk: {
                _ = s.next();
                break :blk .Caret;
            },
            '#' => try self.tokenizeHash(s),
            '~' => blk: {
                _ = s.next();
                break :blk .Tilde;
            },
            '@' => blk: {
                _ = s.next();
                const at_start = s.pos - 1;
                // Check for @@ (system variable prefix)
                if (s.peek()) |c2| {
                    if (c2 == '@') {
                        _ = s.next(); // consume second @
                        // @@identifier or @@scope.identifier
                        if (s.peek()) |c3| {
                            if (isIdentifierStart(c3)) {
                                _ = s.next();
                                while (s.peek()) |cn| {
                                    if (isIdentifierPart(cn)) {
                                        _ = s.next();
                                    } else break;
                                }
                                // Check for @@scope.name (e.g. @@global.server_id)
                                if (s.peek()) |dot| {
                                    if (dot == '.') {
                                        // Save full state for backtracking
                                        const saved_pos = s.pos;
                                        const saved_line = s.line;
                                        const saved_col = s.col;
                                        _ = s.next(); // consume '.'
                                        if (s.peek()) |after_dot| {
                                            if (isIdentifierStart(after_dot)) {
                                                _ = s.next();
                                                while (s.peek()) |cn| {
                                                    if (isIdentifierPart(cn)) {
                                                        _ = s.next();
                                                    } else break;
                                                }
                                                // Include scope.name in the placeholder
                                            } else {
                                                // Dot not followed by identifier; backtrack
                                                s.pos = saved_pos;
                                                s.line = saved_line;
                                                s.col = saved_col;
                                            }
                                        } else {
                                            s.pos = saved_pos;
                                            s.line = saved_line;
                                            s.col = saved_col;
                                        }
                                    }
                                }
                                break :blk Token{ .Placeholder = s.input[at_start..s.pos] };
                            }
                        }
                        // Bare @@ without identifier; backtrack second @
                        s.pos -= 1;
                        s.col -= 1;
                        break :blk .AtSign;
                    } else if (isIdentifierStart(c2)) {
                        // @identifier (user/session variable)
                        _ = s.next();
                        while (s.peek()) |cn| {
                            if (isIdentifierPart(cn)) {
                                _ = s.next();
                            } else break;
                        }
                        break :blk Token{ .Placeholder = s.input[at_start..s.pos] };
                    }
                }
                break :blk .AtSign;
            },
            '?' => blk: {
                _ = s.next();
                const start = s.pos;
                while (s.peek()) |c| {
                    if (c >= '0' and c <= '9') {
                        _ = s.next();
                    } else break;
                }
                break :blk Token{ .Placeholder = s.input[start - 1 .. s.pos] };
            },
            '$' => blk: {
                _ = s.next();
                const start = s.pos;
                while (s.peek()) |c| {
                    if (c >= '0' and c <= '9') {
                        _ = s.next();
                    } else break;
                }
                break :blk Token{ .Placeholder = s.input[start - 1 .. s.pos] };
            },
            'B', 'b' => try self.tokenizeB(s),
            'N', 'n' => try self.tokenizeN(s),
            'X', 'x' => try self.tokenizeX(s),
            else => {
                if (isIdentifierStart(ch)) {
                    return try self.tokenizeIdentifierOrKeyword(s);
                }
                _ = s.next();
                return Token{ .Char = ch };
            },
        };
    }

    // -----------------------------------------------------------------------
    // Token-specific helpers
    // -----------------------------------------------------------------------

    fn tokenizeSingleQuotedString(
        self: *Tokenizer,
        s: *State,
        quote: u8,
    ) error{TokenizerError}!Token {
        const loc = s.location();
        _ = s.next(); // consume opening quote
        const content = try self.readQuotedString(s, loc, quote, self.backslashEscape());
        return Token{ .SingleQuotedString = content };
    }

    fn tokenizeDoubleQuotedOrIdentifier(
        self: *Tokenizer,
        s: *State,
    ) error{TokenizerError}!Token {
        // Both Generic and MySQL treat " as an identifier delimiter.
        return try self.tokenizeQuotedIdentifier(s, '"');
    }

    fn tokenizeQuotedIdentifier(
        self: *Tokenizer,
        s: *State,
        quote_start: u8,
    ) error{TokenizerError}!Token {
        const loc = s.location();
        _ = s.next(); // consume opening quote
        const quote_end: u8 = if (quote_start == '[') ']' else quote_start;
        const value = try self.readQuotedIdentifier(s, loc, quote_end);
        const w = Word{
            .value = value,
            .quote_style = quote_start,
            .keyword = .NoKeyword,
        };
        return Token{ .Word = w };
    }

    fn tokenizeMinus(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = self;
        _ = s.next(); // consume '-'
        if (s.peek() == '-') {
            _ = s.next(); // consume second '-'
            const comment = readLineComment(s);
            return Token{ .Whitespace = .{ .SingleLineComment = .{
                .prefix = "--",
                .comment = comment,
            } } };
        }
        return .Minus;
    }

    fn tokenizeSlash(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next(); // consume '/'
        if (s.peek() == '*') {
            _ = s.next(); // consume '*'
            return try self.tokenizeMultilineComment(s);
        }
        return .Div;
    }

    fn tokenizePipe(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        if (s.peek() == '|') {
            _ = s.next();
            return .StringConcat;
        }
        return .Pipe;
    }

    fn tokenizeEq(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        if (s.peek() == '>') {
            _ = s.next();
            return .RArrow;
        }
        if (s.peek() == '=') {
            _ = s.next();
            return .DoubleEq;
        }
        return .Eq;
    }

    fn tokenizeExclamation(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        if (s.peek() == '=') {
            _ = s.next();
            return .Neq;
        }
        return .ExclamationMark;
    }

    fn tokenizeLt(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        switch (s.peek() orelse 0) {
            '=' => {
                _ = s.next();
                if (s.peek() == '>') {
                    _ = s.next();
                    return .Spaceship;
                }
                return .LtEq;
            },
            '>' => {
                _ = s.next();
                return .Neq;
            },
            '<' => {
                _ = s.next();
                return .ShiftLeft;
            },
            else => return .Lt,
        }
    }

    fn tokenizeGt(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        switch (s.peek() orelse 0) {
            '=' => {
                _ = s.next();
                return .GtEq;
            },
            '>' => {
                _ = s.next();
                return .ShiftRight;
            },
            else => return .Gt,
        }
    }

    fn tokenizeColon(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        if (s.peek() == ':') {
            _ = s.next();
            return .DoubleColon;
        }
        if (s.peek() == '=') {
            _ = s.next();
            return .Assignment;
        }
        return .Colon;
    }

    fn tokenizeHash(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next();
        // MySQL and Generic: # starts a single-line comment.
        if (self.dialect == .MySQL or self.dialect == .Generic) {
            const comment = readLineComment(s);
            return Token{ .Whitespace = .{ .SingleLineComment = .{
                .prefix = "#",
                .comment = comment,
            } } };
        }
        return .Sharp;
    }

    fn tokenizeB(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next(); // consume 'b' or 'B'
        if (s.peek() == '\'') {
            const loc = s.location();
            _ = s.next(); // consume "'"
            const content = try self.readQuotedString(s, loc, '\'', false);
            return Token{ .SingleQuotedByteStringLiteral = content };
        }
        return try self.finishIdentifier(s);
    }

    fn tokenizeN(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next(); // consume 'n' or 'N'
        if (s.peek() == '\'') {
            const loc = s.location();
            _ = s.next(); // consume "'"
            const content = try self.readQuotedString(s, loc, '\'', self.backslashEscape());
            return Token{ .NationalStringLiteral = content };
        }
        return try self.finishIdentifier(s);
    }

    fn tokenizeX(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next(); // consume 'x' or 'X'
        if (s.peek() == '\'') {
            const loc = s.location();
            _ = s.next(); // consume "'"
            const content = try self.readQuotedString(s, loc, '\'', false);
            return Token{ .HexStringLiteral = content };
        }
        return try self.finishIdentifier(s);
    }

    fn tokenizeNumber(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        const start = s.pos;
        // Consume integer part.
        s.advanceTo(simd.findNumberEnd(s.input, s.pos));

        // 0x hex literal.
        if (s.pos - start == 1 and s.input[start] == '0') {
            if (s.peek() == 'x' or s.peek() == 'X') {
                _ = s.next(); // consume 'x'
                const hex_start = s.pos;
                while (s.peek()) |c| {
                    if (isHexDigit(c)) _ = s.next() else break;
                }
                return Token{ .HexStringLiteral = s.input[hex_start..s.pos] };
            }
        }

        // Decimal point.
        if (s.peek() == '.') {
            _ = s.next();
            s.advanceTo(simd.findNumberEnd(s.input, s.pos));
        }

        // Exponent.
        if (s.peek() == 'e' or s.peek() == 'E') {
            if (s.peekN(1)) |next| {
                const is_sign = next == '+' or next == '-';
                const after_sign: ?u8 = if (is_sign) s.peekN(2) else s.peekN(1);
                if (after_sign != null and after_sign.? >= '0' and after_sign.? <= '9') {
                    _ = s.next(); // 'e'/'E'
                    if (is_sign) _ = s.next(); // sign
                    s.advanceTo(simd.findNumberEnd(s.input, s.pos));
                }
            }
        }

        const long = s.peek() == 'L';
        if (long) _ = s.next();
        return Token{ .Number = .{
            .value = s.input[start .. s.pos - @intFromBool(long)],
            .long = long,
        } };
    }

    fn tokenizePeriodOrNumber(self: *Tokenizer, s: *State) error{TokenizerError}!Token {
        _ = s.next(); // consume '.'
        if (s.peek()) |c| {
            if (c >= '0' and c <= '9') {
                const start = s.pos - 1; // include the '.'
                s.advanceTo(simd.findNumberEnd(s.input, s.pos));
                // Exponent.
                if (s.peek() == 'e' or s.peek() == 'E') {
                    if (s.peekN(1)) |next| {
                        const is_sign = next == '+' or next == '-';
                        const after_sign: ?u8 = if (is_sign) s.peekN(2) else s.peekN(1);
                        if (after_sign != null and after_sign.? >= '0' and after_sign.? <= '9') {
                            _ = s.next();
                            if (is_sign) _ = s.next();
                            s.advanceTo(simd.findNumberEnd(s.input, s.pos));
                        }
                    }
                }
                const long = s.peek() == 'L';
                if (long) _ = s.next();
                return Token{ .Number = .{
                    .value = s.input[start .. s.pos - @intFromBool(long)],
                    .long = long,
                } };
            }
        }
        _ = self;
        return .Period;
    }

    fn tokenizeIdentifierOrKeyword(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        const start = s.pos;
        _ = s.next(); // consume first char
        const end = simd.findIdentifierEnd(s.input, s.pos);
        s.advanceTo(end);
        const word = s.input[start..s.pos];
        return makeWord(word, null);
    }

    /// Complete tokenizing an identifier when we have already consumed the first char.
    fn finishIdentifier(_: *Tokenizer, s: *State) error{TokenizerError}!Token {
        // The char at pos - 1 was already consumed.
        const start = s.pos - 1;
        const end = simd.findIdentifierEnd(s.input, s.pos);
        s.advanceTo(end);
        const word = s.input[start..s.pos];
        return makeWord(word, null);
    }

    // -----------------------------------------------------------------------
    // String and identifier reading
    // -----------------------------------------------------------------------

    /// Read a string delimited by `quote`, starting AFTER the opening quote.
    /// Closing quote is consumed on return.
    /// Returns a slice into self.input (zero-copy) when no escaping occurred.
    fn readQuotedString(
        self: *Tokenizer,
        s: *State,
        loc: Location,
        quote: u8,
        backslash_escape: bool,
    ) error{TokenizerError}![]const u8 {
        const start = s.pos;
        while (s.pos < s.input.len) {
            // SIMD-skip to the next quote or escape character.
            const hit = simd.findQuoteEnd(s.input, s.pos, quote, backslash_escape);
            if (hit >= s.input.len) {
                // No quote/escape found -- advance to end and report error.
                s.advanceToWithLineTracking(s.input.len);
                break;
            }
            // Advance state (with line tracking since strings may span lines).
            s.advanceToWithLineTracking(hit);
            const c = s.input[s.pos];
            if (c == '\\' and backslash_escape) {
                _ = s.next(); // backslash
                _ = s.next(); // escaped char
                continue;
            }
            if (c == quote) {
                // Doubled quote is an escape sequence.
                if (s.peekN(1) == quote) {
                    _ = s.next();
                    _ = s.next();
                    continue;
                }
                const content = s.input[start..s.pos];
                _ = s.next(); // consume closing quote
                return content;
            }
            _ = s.next();
        }
        return self.fail(loc, "Unterminated string literal");
    }

    /// Read a quoted identifier (after the opening quote has been consumed).
    /// The closing quote is consumed on return.
    fn readQuotedIdentifier(
        self: *Tokenizer,
        s: *State,
        loc: Location,
        quote_end: u8,
    ) error{TokenizerError}![]const u8 {
        const start = s.pos;
        while (s.pos < s.input.len) {
            // SIMD-skip to the next closing quote candidate.
            // Use line tracking since quoted identifiers could theoretically
            // contain newlines in malformed input.
            const hit = simd.findQuoteEnd(s.input, s.pos, quote_end, false);
            if (hit >= s.input.len) {
                s.advanceToWithLineTracking(s.input.len);
                break;
            }
            s.advanceToWithLineTracking(hit);
            const c = s.input[s.pos];
            if (c == quote_end) {
                if (s.peekN(1) == quote_end) {
                    _ = s.next();
                    _ = s.next();
                    continue;
                }
                const content = s.input[start..s.pos];
                _ = s.next(); // consume closing quote
                return content;
            }
            _ = s.next();
        }
        return self.fail(loc, "Expected close delimiter before EOF");
    }

    fn tokenizeMultilineComment(
        self: *Tokenizer,
        s: *State,
    ) error{TokenizerError}!Token {
        const start = s.pos;
        var depth: u32 = 1;
        while (s.peek()) |c| {
            if (c == '*' and s.peekN(1) == '/') {
                _ = s.next(); // '*'
                _ = s.next(); // '/'
                depth -= 1;
                if (depth == 0) {
                    const content = s.input[start .. s.pos - 2];
                    return Token{ .Whitespace = .{ .MultiLineComment = content } };
                }
            } else if (c == '/' and s.peekN(1) == '*') {
                _ = s.next();
                _ = s.next();
                depth += 1;
            } else {
                _ = s.next();
            }
        }
        return self.fail(s.location(), "Unexpected EOF while in a multi-line comment");
    }

    fn backslashEscape(self: *const Tokenizer) bool {
        return self.dialect == .MySQL;
    }

    /// Record error details in self.err and return the error tag.
    fn fail(self: *Tokenizer, loc: Location, message: []const u8) error{TokenizerError} {
        self.err = .{ .message = message, .location = loc };
        return error.TokenizerError;
    }
};

// -----------------------------------------------------------------------
// Free functions
// -----------------------------------------------------------------------

/// Read characters until end-of-line (inclusive).
fn readLineComment(s: *State) []const u8 {
    const start = s.pos;
    while (s.peek()) |c| {
        if (c == '\n') {
            _ = s.next();
            break;
        }
        if (c == '\r') {
            _ = s.next();
            if (s.peek() == '\n') _ = s.next();
            break;
        }
        _ = s.next();
    }
    return s.input[start..s.pos];
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentifierPart(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

/// Create a Token.Word from an unquoted word string. Performs keyword lookup.
fn makeWord(word: []const u8, quote_style: ?u8) Token {
    const kw = if (quote_style == null)
        keywords.lookupKeywordCaseInsensitive(word)
    else
        .NoKeyword;
    return Token{ .Word = .{
        .value = word,
        .quote_style = quote_style,
        .keyword = kw,
    } };
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "tokenize SELECT" {
    var tokenizer = Tokenizer.init(.Generic, "SELECT");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Word => |w| {
            try std.testing.expectEqualStrings("SELECT", w.value);
            try std.testing.expectEqual(Keyword.SELECT, w.keyword);
        },
        else => return error.UnexpectedToken,
    }
}

test "tokenize simple query" {
    const sql = "SELECT * FROM t WHERE id = 1;";
    var tokenizer = Tokenizer.init(.Generic, sql);
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    // First token is SELECT keyword.
    switch (toks[0]) {
        .Word => |w| try std.testing.expectEqual(Keyword.SELECT, w.keyword),
        else => return error.UnexpectedToken,
    }
    // Last token is semicolon.
    try std.testing.expectEqual(Token.SemiColon, toks[toks.len - 1]);
}

test "tokenize single-quoted string" {
    var tokenizer = Tokenizer.init(.Generic, "'hello world'");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .SingleQuotedString => |s| try std.testing.expectEqualStrings("hello world", s),
        else => return error.UnexpectedToken,
    }
}

test "tokenize line comment" {
    const sql = "SELECT 1 -- this is a comment\n";
    var tokenizer = Tokenizer.init(.Generic, sql);
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    var found_comment = false;
    for (toks) |t| {
        switch (t) {
            .Whitespace => |ws| switch (ws) {
                .SingleLineComment => |c| {
                    try std.testing.expectEqualStrings("--", c.prefix);
                    found_comment = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(found_comment);
}

test "tokenize block comment" {
    const sql = "SELECT /* block */ 1";
    var tokenizer = Tokenizer.init(.Generic, sql);
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    var found = false;
    for (toks) |t| {
        switch (t) {
            .Whitespace => |ws| switch (ws) {
                .MultiLineComment => |c| {
                    try std.testing.expectEqualStrings(" block ", c);
                    found = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}

test "tokenize number literals" {
    {
        var tokenizer = Tokenizer.init(.Generic, "42");
        const toks = try tokenizer.tokenize(std.testing.allocator);
        defer std.testing.allocator.free(toks);
        switch (toks[0]) {
            .Number => |n| try std.testing.expectEqualStrings("42", n.value),
            else => return error.UnexpectedToken,
        }
    }
    {
        var tokenizer = Tokenizer.init(.Generic, "3.14");
        const toks = try tokenizer.tokenize(std.testing.allocator);
        defer std.testing.allocator.free(toks);
        switch (toks[0]) {
            .Number => |n| try std.testing.expectEqualStrings("3.14", n.value),
            else => return error.UnexpectedToken,
        }
    }
}

test "tokenize operators" {
    const sql = "= != <> <= >= < > || + - * / %";
    var tokenizer = Tokenizer.init(.Generic, sql);
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    var ops: std.ArrayList(Token) = .empty;
    defer ops.deinit(std.testing.allocator);
    for (toks) |t| {
        switch (t) {
            .Whitespace => {},
            else => try ops.append(std.testing.allocator, t),
        }
    }
    try std.testing.expectEqual(Token.Eq, ops.items[0]);
    try std.testing.expectEqual(Token.Neq, ops.items[1]);
    try std.testing.expectEqual(Token.Neq, ops.items[2]);
    try std.testing.expectEqual(Token.LtEq, ops.items[3]);
    try std.testing.expectEqual(Token.GtEq, ops.items[4]);
    try std.testing.expectEqual(Token.Lt, ops.items[5]);
    try std.testing.expectEqual(Token.Gt, ops.items[6]);
    try std.testing.expectEqual(Token.StringConcat, ops.items[7]);
    try std.testing.expectEqual(Token.Plus, ops.items[8]);
    try std.testing.expectEqual(Token.Minus, ops.items[9]);
    try std.testing.expectEqual(Token.Mul, ops.items[10]);
    try std.testing.expectEqual(Token.Div, ops.items[11]);
    try std.testing.expectEqual(Token.Mod, ops.items[12]);
}

test "tokenize MySQL backtick identifier" {
    var tokenizer = Tokenizer.init(.MySQL, "`my table`");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Word => |w| {
            try std.testing.expectEqualStrings("my table", w.value);
            try std.testing.expectEqual(@as(?u8, '`'), w.quote_style);
        },
        else => return error.UnexpectedToken,
    }
}

test "tokenize hex string literal" {
    var tokenizer = Tokenizer.init(.Generic, "X'deadbeef'");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .HexStringLiteral => |s| try std.testing.expectEqualStrings("deadbeef", s),
        else => return error.UnexpectedToken,
    }
}

test "tokenize MySQL # comment" {
    const sql = "SELECT 1 # comment\n";
    var tokenizer = Tokenizer.init(.MySQL, sql);
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    var found = false;
    for (toks) |t| {
        switch (t) {
            .Whitespace => |ws| switch (ws) {
                .SingleLineComment => |c| {
                    try std.testing.expectEqualStrings("#", c.prefix);
                    found = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}

test "tokenize spaceship operator" {
    var tokenizer = Tokenizer.init(.MySQL, "a <=> b");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    var found_spaceship = false;
    for (toks) |t| {
        if (t == .Spaceship) found_spaceship = true;
    }
    try std.testing.expect(found_spaceship);
}

test "tokenize unterminated string error with location" {
    var tokenizer = Tokenizer.init(.Generic, "'unterminated");
    const result = tokenizer.tokenize(std.testing.allocator);
    try std.testing.expectError(error.TokenizerError, result);
    // The error info is stored on the tokenizer.
    try std.testing.expect(tokenizer.err != null);
    try std.testing.expectEqualStrings("Unterminated string literal", tokenizer.err.?.message);
    // Line 1 because it's on the first line.
    try std.testing.expectEqual(@as(u64, 1), tokenizer.err.?.location.line);
}

test "tokenize double-quoted identifier" {
    var tokenizer = Tokenizer.init(.Generic, "\"my_col\"");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Word => |w| {
            try std.testing.expectEqualStrings("my_col", w.value);
            try std.testing.expectEqual(@as(?u8, '"'), w.quote_style);
        },
        else => return error.UnexpectedToken,
    }
}

test "tokenize MySQL backslash escape in string" {
    var tokenizer = Tokenizer.init(.MySQL, "'hello\\nworld'");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .SingleQuotedString => |s| {
            // Raw content is returned (escape interpretation left to parser).
            try std.testing.expectEqualStrings("hello\\nworld", s);
        },
        else => return error.UnexpectedToken,
    }
}

test "tokenize MySQL @variable as placeholder" {
    var tokenizer = Tokenizer.init(.MySQL, "@aurora_server_id");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Placeholder => |s| try std.testing.expectEqualStrings("@aurora_server_id", s),
        else => return error.UnexpectedToken,
    }
}

test "tokenize MySQL @@system_variable as placeholder" {
    var tokenizer = Tokenizer.init(.MySQL, "@@server_id");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Placeholder => |s| try std.testing.expectEqualStrings("@@server_id", s),
        else => return error.UnexpectedToken,
    }
}

test "tokenize MySQL @@global.variable as placeholder" {
    var tokenizer = Tokenizer.init(.MySQL, "@@global.server_id");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Placeholder => |s| try std.testing.expectEqualStrings("@@global.server_id", s),
        else => return error.UnexpectedToken,
    }
}

test "tokenize MySQL @@session.variable as placeholder" {
    var tokenizer = Tokenizer.init(.MySQL, "@@session.wait_timeout");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    switch (toks[0]) {
        .Placeholder => |s| try std.testing.expectEqualStrings("@@session.wait_timeout", s),
        else => return error.UnexpectedToken,
    }
}

test "tokenize bare @ remains AtSign" {
    var tokenizer = Tokenizer.init(.MySQL, "@ foo");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    // AtSign, Whitespace, Word("foo")
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expect(toks[0] == .AtSign);
}

test "tokenize @variable in SELECT expression" {
    var tokenizer = Tokenizer.init(.MySQL, "SELECT @var AS v");
    const toks = try tokenizer.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(toks);

    // SELECT, WS, @var, WS, AS, WS, v
    try std.testing.expectEqual(@as(usize, 7), toks.len);
    try std.testing.expect(toks[0] == .Word);
    switch (toks[2]) {
        .Placeholder => |s| try std.testing.expectEqualStrings("@var", s),
        else => return error.UnexpectedToken,
    }
}
