//! Remove stale generated views before installing the selected runicode outputs.

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedInstallDirectory;
    try std.Io.Dir.cwd().deleteTree(init.io, args[1]);
}

const std = @import("std");
