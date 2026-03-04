const std = @import("std");
const span = @import("span.zig");

pub const Location = span.Location;

/// An error produced by the tokenizer, with a human-readable message and a source location.
pub const TokenizerError = struct {
    message: []const u8,
    location: Location,

    pub fn format(self: TokenizerError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.message);
        try self.location.format(writer);
    }
};

/// An error produced by the parser, with a human-readable message and a source location.
pub const ParserError = struct {
    message: []const u8,
    location: Location,

    pub fn format(self: ParserError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.message);
        try self.location.format(writer);
    }
};

test "TokenizerError format" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    const err = TokenizerError{
        .message = "Unterminated string literal",
        .location = Location.init(3, 12),
    };
    try err.format(&allocating.writer);
    const s = try allocating.toOwnedSlice();
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("Unterminated string literal at Line: 3, Column: 12", s);
}
