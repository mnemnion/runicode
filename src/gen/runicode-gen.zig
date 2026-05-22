const std = @import("std");
const audit = @import("ucd/audit.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len < 2) return error.InvalidArguments;

    var ucd_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer ucd_dir.close(io);

    try audit.auditDir(io, allocator, ucd_dir);
    std.process.cleanExit(io);
}
