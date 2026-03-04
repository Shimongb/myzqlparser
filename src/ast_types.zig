const std = @import("std");

/// Precision and scale info for exact numeric types (NUMERIC, DECIMAL, DEC).
pub const ExactNumberInfo = union(enum) {
    /// No precision or scale, e.g. `DECIMAL`.
    none,
    /// Precision only, e.g. `DECIMAL(10)`.
    precision: u64,
    /// Precision and scale, e.g. `DECIMAL(10,2)`.
    precision_and_scale: struct { precision: u64, scale: i64 },
};

/// Character length specification for CHAR/VARCHAR types.
pub const CharacterLength = union(enum) {
    /// Integer length, e.g. `VARCHAR(255)` or `VARCHAR(255 CHARACTERS)`.
    integer: struct {
        length: u64,
        unit: ?CharLengthUnits,
    },
    /// `VARCHAR(MAX)` (T-SQL).
    max,
};

/// Unit for character lengths.
pub const CharLengthUnits = enum {
    /// CHARACTERS
    characters,
    /// OCTETS
    octets,
};

/// Binary length specification for VARBINARY types.
pub const BinaryLength = union(enum) {
    /// Integer length, e.g. `VARBINARY(100)`.
    integer: u64,
    /// `VARBINARY(MAX)` (T-SQL).
    max,
};

/// Timezone info for TIME/TIMESTAMP types.
pub const TimezoneInfo = enum {
    /// No timezone info, e.g. `TIMESTAMP`.
    none,
    /// `WITH TIME ZONE`
    with_time_zone,
    /// `WITHOUT TIME ZONE`
    without_time_zone,
};

/// SQL data types, covering standard SQL and MySQL.
///
/// Each variant maps to a SQL type keyword or family. Optional fields
/// represent optional parameters such as precision, scale, or length.
pub const DataType = union(enum) {
    // ----- Character types -----
    /// CHAR[(n)] or CHARACTER[(n)]
    char: ?CharacterLength,
    /// CHAR VARYING[(n)] or CHARACTER VARYING[(n)]
    char_varying: ?CharacterLength,
    /// VARCHAR[(n)]
    varchar: ?CharacterLength,
    /// NVARCHAR[(n)]
    nvarchar: ?CharacterLength,
    /// CHARACTER LARGE OBJECT[(n)] or CHAR LARGE OBJECT[(n)]
    char_large_object: ?u64,
    /// CLOB[(n)]
    clob: ?u64,
    /// TEXT
    text,
    /// TINYTEXT (MySQL)
    tiny_text,
    /// MEDIUMTEXT (MySQL)
    medium_text,
    /// LONGTEXT (MySQL)
    long_text,
    /// UUID
    uuid,

    // ----- Binary types -----
    /// BINARY[(n)]
    binary: ?u64,
    /// VARBINARY[(n)]
    varbinary: ?BinaryLength,
    /// BLOB[(n)]
    blob: ?u64,
    /// TINYBLOB (MySQL)
    tiny_blob,
    /// MEDIUMBLOB (MySQL)
    medium_blob,
    /// LONGBLOB (MySQL)
    long_blob,
    /// BYTEA (PostgreSQL -- kept because generic)
    bytea,

    // ----- Exact numeric types -----
    /// NUMERIC[(p[,s])]
    numeric: ExactNumberInfo,
    /// DECIMAL[(p[,s])]
    decimal: ExactNumberInfo,
    /// DECIMAL UNSIGNED (MySQL, deprecated)
    decimal_unsigned: ExactNumberInfo,
    /// DEC[(p[,s])]
    dec: ExactNumberInfo,
    /// DEC UNSIGNED (MySQL, deprecated)
    dec_unsigned: ExactNumberInfo,

    // ----- Integer types -----
    /// TINYINT[(n)]
    tiny_int: ?u64,
    /// TINYINT UNSIGNED[(n)] (MySQL)
    tiny_int_unsigned: ?u64,
    /// SMALLINT[(n)]
    small_int: ?u64,
    /// SMALLINT UNSIGNED[(n)] (MySQL)
    small_int_unsigned: ?u64,
    /// MEDIUMINT[(n)] (MySQL)
    medium_int: ?u64,
    /// MEDIUMINT UNSIGNED[(n)] (MySQL)
    medium_int_unsigned: ?u64,
    /// INT[(n)]
    int: ?u64,
    /// INT UNSIGNED[(n)] (MySQL)
    int_unsigned: ?u64,
    /// INTEGER[(n)]
    integer: ?u64,
    /// INTEGER UNSIGNED[(n)] (MySQL)
    integer_unsigned: ?u64,
    /// BIGINT[(n)]
    big_int: ?u64,
    /// BIGINT UNSIGNED[(n)] (MySQL)
    big_int_unsigned: ?u64,
    /// SIGNED [INTEGER] -- MySQL CAST target type
    signed,
    /// SIGNED INTEGER -- MySQL CAST target type
    signed_integer,
    /// UNSIGNED [INTEGER] -- MySQL CAST target type
    unsigned,
    /// UNSIGNED INTEGER -- MySQL CAST target type
    unsigned_integer,

    // ----- Approximate numeric types -----
    /// FLOAT[(p)] or FLOAT[(p,s)]
    float: ExactNumberInfo,
    /// FLOAT UNSIGNED (MySQL, deprecated)
    float_unsigned: ExactNumberInfo,
    /// REAL
    real,
    /// REAL UNSIGNED (MySQL, deprecated)
    real_unsigned,
    /// DOUBLE[(p,s)]
    double: ExactNumberInfo,
    /// DOUBLE UNSIGNED (MySQL, deprecated)
    double_unsigned: ExactNumberInfo,
    /// DOUBLE PRECISION
    double_precision,
    /// DOUBLE PRECISION UNSIGNED (MySQL, deprecated)
    double_precision_unsigned,

    // ----- Boolean -----
    /// BOOL (alias for BOOLEAN)
    bool,
    /// BOOLEAN
    boolean,

    // ----- Date/time types -----
    /// DATE
    date,
    /// TIME[(p)] [WITH|WITHOUT TIME ZONE]
    time: struct { precision: ?u64, tz: TimezoneInfo },
    /// DATETIME[(p)] (MySQL)
    datetime: ?u64,
    /// TIMESTAMP[(p)] [WITH|WITHOUT TIME ZONE]
    timestamp: struct { precision: ?u64, tz: TimezoneInfo },

    // ----- JSON -----
    /// JSON
    json,

    // ----- Bit types -----
    /// BIT[(n)]
    bit: ?u64,
    /// BIT VARYING[(n)]
    bit_varying: ?u64,

    // ----- MySQL-specific types -----
    /// ENUM('v1', 'v2', ...) (MySQL)
    /// Values are owned slices of string literals.
    @"enum": []const []const u8,
    /// SET('v1', 'v2', ...) (MySQL)
    /// Values are owned slices of string literals.
    set: []const []const u8,

    // ----- Generic/custom types -----
    /// A user-defined or dialect-specific type name with optional modifiers.
    /// name is the dot-separated type name; modifiers are string parameters.
    custom: struct {
        name: []const u8,
        modifiers: []const []const u8,
    },

    // ----- Array type -----
    /// ARRAY type with optional element type.
    array: ?*const DataType,

    // ----- Unspecified -----
    /// No type specified (e.g. SQLite `CREATE TABLE t1 (a)`).
    unspecified,
};

test "DataType variants compile" {
    const t1: DataType = .{ .varchar = .{ .integer = .{ .length = 255, .unit = null } } };
    const t2: DataType = .{ .int = null };
    const t3: DataType = .{ .decimal = .none };
    const t4: DataType = .{ .timestamp = .{ .precision = null, .tz = .none } };
    const t5: DataType = .{ .@"enum" = &.{} };
    _ = .{ t1, t2, t3, t4, t5 };
}
