# Quickstart

Get myzqlparser running in under 2 minutes.

## Prerequisites

**Zig 0.16.0-dev or later** - download from <https://ziglang.org/download/>.

Verify your version:

```sh
zig version
# must show 0.16.0-dev.XXXX or later
```

## Build

```sh
cd myzqlparser
zig build
```

The CLI binary is at `zig-out/bin/myzqlparser`.

## Parse SQL

From the command line:

```sh
./zig-out/bin/myzqlparser --format debug "SELECT id, name FROM users WHERE id = 1"
# SELECT id, name FROM users WHERE id = 1;
```

From stdin:

```sh
echo "SELECT 1; SELECT 2" | ./zig-out/bin/myzqlparser --format debug
```

JSON AST output (default format):

```sh
./zig-out/bin/myzqlparser "SELECT 1" | jq .
```

MySQL dialect:

```sh
./zig-out/bin/myzqlparser --dialect mysql "SELECT * FROM \`users\` WHERE @@sql_mode = 'STRICT'"
```

## Use as a Library

Add myzqlparser as a dependency in your `build.zig`:

```zig
const myzql = b.dependency("myzqlparser", .{ .target = target });
exe.root_module.addImport("myzqlparser", myzql.module("myzqlparser"));
```

Then in your Zig source:

```zig
const std = @import("std");
const myzqlparser = @import("myzqlparser");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stmts = try myzqlparser.parse(arena, "SELECT 1", .Generic, .generic);

    // stmts[0] is a Statement.Query
    _ = stmts;
}
```

For error details, use `parseDiag` instead of `parse`:

```zig
var diag: myzqlparser.ParseDiagnostics = .{};
const stmts = myzqlparser.parseDiag(arena, sql, .Generic, .generic, &diag) catch {
    std.debug.print("{s}\n", .{diag.error_message});
    // diag.error_location has .line and .column
    return error.ParseFailed;
};
```

## Run Tests

```sh
zig build test
```

## Next Steps

See [README.md](README.md) for the full API reference, supported dialects, and architecture overview.
