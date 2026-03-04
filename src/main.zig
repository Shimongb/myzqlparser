/// myzqlparser CLI
///
/// Usage: myzqlparser [OPTIONS] [SQL]
///
///   --dialect generic|mysql   SQL dialect (default: generic)
///   --format json|debug       Output format (default: json)
///   --help                    Show this help text
///
/// If SQL is not provided as an argument, reads from stdin.
/// Statements may be separated by semicolons.
/// Exits 0 on success, 1 on parse or I/O error.
const std = @import("std");
const Io = std.Io;

const myzqlparser = @import("myzqlparser");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [65536]u8 = undefined;
    var stdout_fwriter: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fwriter.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fwriter: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fwriter.interface;

    // Parse CLI arguments.
    const args = try init.minimal.args.toSlice(arena);

    var dialect_str: []const u8 = "generic";
    var format_str: []const u8 = "json";
    var sql_arg: ?[]const u8 = null;
    var show_help = false;

    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--dialect")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --dialect requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            dialect_str = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --format requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            format_str = args[i];
        } else if (std.mem.startsWith(u8, arg, "--dialect=")) {
            dialect_str = arg["--dialect=".len..];
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_str = arg["--format=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            sql_arg = arg;
        } else {
            try stderr.print("error: unknown option: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(1);
        }
    }

    if (show_help) {
        try stdout.writeAll(
            \\Usage: myzqlparser [OPTIONS] [SQL]
            \\
            \\Options:
            \\  --dialect generic|mysql   SQL dialect (default: generic)
            \\  --format  json|debug      Output format (default: json)
            \\  --help                    Show this help
            \\
            \\If SQL is not provided, reads from stdin.
            \\
        );
        try stdout.flush();
        return;
    }

    // Validate dialect.
    const tok_dialect: myzqlparser.Dialect = if (std.mem.eql(u8, dialect_str, "generic"))
        .Generic
    else if (std.mem.eql(u8, dialect_str, "mysql"))
        .MySQL
    else {
        try stderr.print("error: unknown dialect '{s}' (expected generic or mysql)\n", .{dialect_str});
        try stderr.flush();
        std.process.exit(1);
    };

    const parser_dialect: myzqlparser.ParserDialect = if (std.mem.eql(u8, dialect_str, "generic"))
        .generic
    else
        .mysql;

    // Validate format.
    const use_json = if (std.mem.eql(u8, format_str, "json"))
        true
    else if (std.mem.eql(u8, format_str, "debug"))
        false
    else {
        try stderr.print("error: unknown format '{s}' (expected json or debug)\n", .{format_str});
        try stderr.flush();
        std.process.exit(1);
    };

    // Read SQL input.
    const sql: []const u8 = if (sql_arg) |s| s else blk: {
        // Read stdin into arena.
        var stdin_buf: std.ArrayList(u8) = .empty;
        var stdin_reader_buf: [4096]u8 = undefined;
        var stdin_frd: Io.File.Reader = .init(.stdin(), io, &stdin_reader_buf);
        stdin_frd.interface.appendRemainingUnlimited(arena, &stdin_buf) catch |err| {
            try stderr.print("error: failed to read stdin: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        break :blk stdin_buf.items;
    };

    // Parse.
    var diag: myzqlparser.ParseDiagnostics = .{};
    const stmts = myzqlparser.parseDiag(arena, sql, tok_dialect, parser_dialect, &diag) catch |err| {
        if (diag.error_message.len > 0) {
            try stderr.writeAll("error: ");
            try stderr.writeAll(diag.error_message);
            try diag.error_location.format(stderr);
            try stderr.writeByte('\n');
        } else {
            try stderr.print("error: parse failed: {s}\n", .{@errorName(err)});
        }
        try stderr.flush();
        std.process.exit(1);
    };

    // Output.
    if (use_json) {
        try outputJson(stdout, arena, stmts);
    } else {
        try outputDebug(stdout, stmts);
    }
    try stdout.flush();
}

fn outputJson(w: *std.Io.Writer, allocator: std.mem.Allocator, stmts: []const myzqlparser.Statement) !void {
    const ast_json = myzqlparser.ast_json;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginArray();
    for (stmts) |stmt| {
        try ast_json.writeStatement(&jw, stmt);
    }
    try jw.endArray();
    try aw.writer.flush();
    const json_bytes = aw.writer.buffer[0..aw.writer.end];
    try w.writeAll(json_bytes);
    try w.writeByte('\n');
}

fn outputDebug(w: *std.Io.Writer, stmts: []const myzqlparser.Statement) !void {
    const ast_display = myzqlparser.ast_display;
    for (stmts, 0..) |stmt, i| {
        if (i > 0) try w.writeByte('\n');
        try ast_display.writeStatement(w, stmt);
        try w.writeByte(';');
        try w.writeByte('\n');
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
