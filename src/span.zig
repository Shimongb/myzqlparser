const std = @import("std");

/// A position in the source SQL string, identified by line and column.
/// Line and column are 1-based. Line 0 or column 0 indicates an unknown/empty location.
pub const Location = struct {
    line: u64,
    column: u64,

    pub const empty: Location = .{ .line = 0, .column = 0 };

    pub fn init(line: u64, column: u64) Location {
        return .{ .line = line, .column = column };
    }

    pub fn isKnown(self: Location) bool {
        return self.line != 0;
    }

    /// Return a Span from self to end.
    pub fn spanTo(self: Location, end: Location) Span {
        return Span.init(self, end);
    }

    pub fn format(self: Location, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.line == 0) return;
        try writer.print(" at Line: {d}, Column: {d}", .{ self.line, self.column });
    }
};

/// A contiguous range of source text, from start (inclusive) to end (inclusive).
pub const Span = struct {
    start: Location,
    end: Location,

    pub const empty: Span = .{
        .start = Location.empty,
        .end = Location.empty,
    };

    pub fn init(start: Location, end: Location) Span {
        return .{ .start = start, .end = end };
    }

    pub fn isEmpty(self: Span) bool {
        return self.start.line == 0;
    }

    /// Return the smallest Span that covers both self and other.
    /// If either span is empty, returns the other.
    pub fn merge(self: Span, other: Span) Span {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        const start = if (locationLt(self.start, other.start)) self.start else other.start;
        const end = if (locationLt(self.end, other.end)) other.end else self.end;
        return .{ .start = start, .end = end };
    }
};

fn locationLt(a: Location, b: Location) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

test "Location empty" {
    const loc = Location.empty;
    try std.testing.expect(!loc.isKnown());
}

test "Location init" {
    const loc = Location.init(3, 7);
    try std.testing.expectEqual(@as(u64, 3), loc.line);
    try std.testing.expectEqual(@as(u64, 7), loc.column);
    try std.testing.expect(loc.isKnown());
}

test "Span merge" {
    const a = Span.init(Location.init(1, 1), Location.init(1, 5));
    const b = Span.init(Location.init(2, 3), Location.init(2, 10));
    const merged = a.merge(b);
    try std.testing.expectEqual(Location.init(1, 1), merged.start);
    try std.testing.expectEqual(Location.init(2, 10), merged.end);
}

test "Span merge with empty" {
    const s = Span.init(Location.init(1, 1), Location.init(1, 5));
    const merged = s.merge(Span.empty);
    try std.testing.expectEqual(s.start, merged.start);
    try std.testing.expectEqual(s.end, merged.end);
}
