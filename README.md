# :zap: myzqlparser

A SQL parser for MySQL and ANSI SQL, written in Zig.

Parses SQL text into a typed AST, then serializes it back to SQL or JSON. Ships as both a library (`@import("myzqlparser")`) and a CLI tool.

## Features

- **Zero-copy tokenizer** - token string values are slices into the original input
- **Recursive descent parser** - full SELECT/INSERT/UPDATE/DELETE/DDL coverage
- **Two output modes** - JSON AST (for tooling) and SQL pretty-print (for humans)
- **MySQL dialect support** - backtick identifiers, `@@variables`, index hints, `AUTO_INCREMENT`
- **Arena-friendly** - designed for arena allocators; no individual frees needed
- **Descriptive errors** - `Expected: X, found: Y at Line: L, Column: C`

## Requirements

**Zig 0.16.0-dev or later.** The project uses Zig 0.16 APIs (`std.Io.Writer`, unmanaged `ArrayList`, new `main` signature). It will not build with Zig 0.15 or earlier.

Download Zig 0.16 dev builds from <https://ziglang.org/download/>.

## Build & Test

```sh
zig build            # build the CLI binary (zig-out/bin/myzqlparser)
zig build test       # run all 203 tests
zig build run -- "SELECT 1"   # parse SQL via build system
```

## CLI Usage

```
Usage: myzqlparser [OPTIONS] [SQL]

Options:
  --dialect generic|mysql   SQL dialect (default: generic)
  --format  json|debug      Output format (default: json)
  --help                    Show this help

If SQL is not provided, reads from stdin.
```

### Examples

Parse a query and get the reconstructed SQL:

```sh
$ myzqlparser --format debug "SELECT id, name FROM users WHERE active = 1 ORDER BY name"
SELECT id, name FROM users WHERE active = 1 ORDER BY name;
```

Multi-statement input via stdin:

```sh
$ echo "INSERT INTO logs (msg) VALUES ('hello'); SELECT COUNT(*) FROM logs" \
    | myzqlparser --format debug
INSERT INTO logs (msg) VALUES ('hello');

SELECT COUNT(*) FROM logs;
```

MySQL dialect with backtick identifiers and system variables:

```sh
$ myzqlparser --dialect mysql --format debug \
    "SELECT * FROM \`orders\` FORCE INDEX (idx_date) WHERE @@sql_mode = 'STRICT'"
```

Parse errors include location info:

```
$ myzqlparser "SELECT ,;"
error: Expected: an expression, found: , at Line: 1, Column: 8
```

JSON output (default) produces a full AST. Pipe through `jq` for inspection:

```sh
myzqlparser "SELECT 1" | jq '.[0].Query.body.Select.projection'
```

## Library Usage

Add `myzqlparser` as a module dependency in your `build.zig`:

```zig
const myzql = b.dependency("myzqlparser", .{ .target = target });
exe.root_module.addImport("myzqlparser", myzql.module("myzqlparser"));
```

Parse SQL and iterate over statements:

```zig
const std = @import("std");
const myzqlparser = @import("myzqlparser");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sql = "SELECT id FROM users; DELETE FROM logs WHERE ts < '2024-01-01'";

    const stmts = try myzqlparser.parse(
        arena,
        sql,
        .Generic,   // tokenizer dialect
        .generic,   // parser dialect
    );

    for (stmts) |stmt| {
        switch (stmt) {
            .Query => |q| {
                // work with the query AST
                _ = q;
            },
            .Delete => |d| {
                // work with the delete AST
                _ = d;
            },
            else => {},
        }
    }
}
```

### Error Handling

Use `parseDiag` instead of `parse` to get error details on failure:

```zig
var diag: myzqlparser.ParseDiagnostics = .{};
const stmts = myzqlparser.parseDiag(arena, sql, .Generic, .generic, &diag) catch |err| {
    // diag.error_message: "Expected: an expression, found: ,"
    // diag.error_location: { .line = 1, .column = 8 }
    std.debug.print("error: {s}\n", .{diag.error_message});
    return err;
};
```

The `error_message` string is allocated from the same arena allocator passed to `parseDiag`. It remains valid as long as the arena is live.

## Supported Dialects

| Dialect | Tokenizer | Parser | Description |
|---------|-----------|--------|-------------|
| Generic | `.Generic` | `.generic` | ANSI SQL - standard identifiers, operators, literals |
| MySQL   | `.MySQL`   | `.mysql`   | Adds backtick quoting, `@var`/`@@var`/`@@scope.var`, index hints (`USE INDEX`, `FORCE INDEX`, `IGNORE INDEX`), `AUTO_INCREMENT` |

Both dialects support: `SELECT` (with joins, subqueries, CTEs, set operations), `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`/`VIEW`/`INDEX`, `ALTER TABLE`, `DROP`.

## Architecture

```
SQL text
  --> Tokenizer (tokenizer.zig)
    --> Token stream (zero-copy slices into input)
      --> Parser (parser.zig + parser_dml_ddl.zig)
        --> AST (ast.zig, ast_query.zig, ast_ddl.zig, ast_dml.zig)
          --> JSON (ast_json.zig) or SQL (ast_display.zig)
```

## Status

Under active development. 203 tests passing. The dialect focus is MySQL and ANSI SQL.
