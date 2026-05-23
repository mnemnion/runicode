const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const manifest = @import("manifest.zig");

pub const AuditError = error{UnknownUcdFile};

pub fn auditDir(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), ".DS_Store")) continue;
        if (manifest.entryFor(entry.path) == null) {
            if (!builtin.is_test) std.log.err("unknown UCD file: {s}", .{entry.path});
            return error.UnknownUcdFile;
        }
    }
}

test "audit rejects unknown UCD file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Blocks.txt", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "NewUnicodeThing.txt", .data = "" });
    try testing.expectError(error.UnknownUcdFile, auditDir(testing.io, testing.allocator, tmp.dir));
}

test "audit accepts known nested UCD file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "auxiliary");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auxiliary/WordBreakProperty.txt", .data = "" });
    try auditDir(testing.io, testing.allocator, tmp.dir);
}
