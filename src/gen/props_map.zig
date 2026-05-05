//! Compile-time construction of loose-matching property maps.

const std = @import("std");
const runeset = @import("runeset");

const RuneSet = runeset.RuneSet;

pub const NamedRuneSetMap = NamedMap;

pub fn NamedMap(comptime Source: type) type {
    comptime {
        const decls = sourceDecls(Source);
        if (decls.len == 0) {
            @compileError("NamedMap requires at least one declaration");
        }

        @setEvalBranchQuota(evalBranchQuota(decls.len));

        const First = @TypeOf(@field(Source, decls[0].name));
        const Value = mapValueType(First);

        var key_bufs: [decls.len][128]u8 = undefined;
        var key_lens: [decls.len]usize = undefined;
        var values: [decls.len]Value = undefined;
        for (decls, 0..) |decl, idx| {
            const value = @field(Source, decl.name);
            const len = normalizePropName(decl.name, &key_bufs[idx]) orelse {
                @compileError("declaration name cannot be normalized: " ++ decl.name);
            };
            key_lens[idx] = len;
            values[idx] = mapValue(value, Value);
        }

        const final_key_bufs = key_bufs;
        const final_key_lens = key_lens;
        const final_values = values;
        var pairs: [decls.len]struct { []const u8, Value } = undefined;
        for (&pairs, 0..) |*pair, idx| {
            pair.* = .{ final_key_bufs[idx][0..final_key_lens[idx]], final_values[idx] };
        }

        const map = std.StaticStringMap(Value).initComptime(pairs);
        return struct {
            map: std.StaticStringMap(Value) = map,
            buf: [128]u8 = undefined,

            pub fn get(props: *@This(), name: []const u8) ?Value {
                const len = normalizePropName(name, &props.buf) orelse return null;
                return props.map.get(props.buf[0..len]);
            }
        };
    }
}

pub fn normalizePropName(name: []const u8, buf: []u8) ?usize {
    const start = prefixlessPropNameStart(name) orelse return null;
    var len: usize = 0;
    var pending_sep = false;

    for (name[start..]) |byte| {
        switch (byte) {
            ' ', '_', '-' => {
                pending_sep = len != 0;
            },
            'A'...'Z', 'a'...'z', '0'...'9' => {
                if (pending_sep) {
                    if (len == buf.len) return null;
                    buf[len] = '_';
                    len += 1;
                    pending_sep = false;
                }
                if (len == buf.len) return null;
                buf[len] = std.ascii.toLower(byte);
                len += 1;
            },
            else => return null,
        }
    }

    return len;
}

fn mapValueType(comptime Decl: type) type {
    return switch (@typeInfo(Decl)) {
        .array => |array| []const array.child,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| []const array.child,
            else => Decl,
        },
        else => Decl,
    };
}

fn mapValue(comptime value: anytype, comptime Value: type) Value {
    return switch (@typeInfo(@TypeOf(value))) {
        .array => value[0..],
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => value[0..],
            else => value,
        },
        else => value,
    };
}

fn sourceDecls(comptime Source: type) []const std.builtin.Type.Declaration {
    const source_info = @typeInfo(Source);
    if (source_info != .@"struct") {
        @compileError("NamedMap requires a struct or namespace type");
    }
    return source_info.@"struct".decls;
}

fn evalBranchQuota(comptime decl_count: usize) u32 {
    if (decl_count == 0) return 1_000;
    const n_log_n = decl_count * std.math.log2_int_ceil(usize, decl_count);
    return @intCast(10_000 + decl_count * 1_000 + n_log_n * 100);
}

fn prefixlessPropNameStart(name: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < name.len and isLoosePropNameSeparator(name[idx])) : (idx += 1) {}

    if (idx + 2 > name.len or
        std.ascii.toLower(name[idx]) != 'i' or
        std.ascii.toLower(name[idx + 1]) != 's')
    {
        return idx;
    }

    var probe = idx + 2;
    while (probe < name.len and isLoosePropNameSeparator(name[probe])) : (probe += 1) {}
    return if (probe < name.len) idx + 2 else idx;
}

fn isLoosePropNameSeparator(byte: u8) bool {
    return byte == ' ' or byte == '_' or byte == '-';
}

const TestSets = struct {
    pub const Greek = RuneSet{ .body = &.{ 1, 2, 3, 4 } };
    pub const Latin_Extended_A = RuneSet{ .body = &.{ 5, 6, 7, 8 } };
};

const TestCodepoints = struct {
    pub const Lu = [_]u21{ 0x41, 0x42 };
    pub const Lowercase_Letter = [_]u21{ 0x61, 0x62, 0x63 };
};

const TestStrings = struct {
    pub const Greek = "abc";
    pub const Latin_Extended_A = "defgh";
};

test "NamedMap looks up RuneSets with loose matching" {
    var map = NamedMap(TestSets){};

    try std.testing.expect((map.get("Greek") orelse unreachable).equalTo(TestSets.Greek));
    try std.testing.expect((map.get("latin extended a") orelse unreachable).equalTo(TestSets.Latin_Extended_A));
    try std.testing.expect((map.get("Is-Latin_Extended_A") orelse unreachable).equalTo(TestSets.Latin_Extended_A));
}

test "NamedMap returns null for invalid names and misses" {
    var map = NamedMap(TestSets){};

    try std.testing.expectEqual(null, map.get("Greek!"));
    try std.testing.expectEqual(null, map.get("Not_A_Script"));
}

test "NamedMap looks up array declarations as slices" {
    var map = NamedMap(TestCodepoints){};

    try std.testing.expectEqualSlices(u21, &TestCodepoints.Lu, map.get("Lu") orelse unreachable);
    try std.testing.expectEqualSlices(u21, &TestCodepoints.Lowercase_Letter, map.get("lowercase letter") orelse unreachable);
}

test "NamedMap looks up string declarations as slices" {
    var map = NamedMap(TestStrings){};

    try std.testing.expectEqualStrings(TestStrings.Greek, map.get("Greek") orelse unreachable);
    try std.testing.expectEqualStrings(TestStrings.Latin_Extended_A, map.get("latin extended a") orelse unreachable);
}
