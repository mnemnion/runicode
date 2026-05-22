const std = @import("std");
const audit = @import("ucd/audit.zig");
const alias_data = @import("ucd/aliases.zig");
const Db = @import("ucd/db.zig").Db;
const manifest = @import("ucd/manifest.zig");
const parse = @import("ucd/parse.zig");

const Aliases = alias_data.Aliases;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len < 2) return error.InvalidArguments;

    var ucd_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer ucd_dir.close(io);

    try audit.auditDir(io, allocator, ucd_dir);
    var aliases = alias_data.Aliases.init(allocator);
    defer aliases.deinit();

    try aliases.loadPropertyAliasesFile(io, ucd_dir);
    try aliases.loadPropertyValueAliasesFile(io, ucd_dir);

    var db = Db.init(allocator);
    defer db.deinit();

    for (manifest.known_files) |entry| {
        switch (entry.kind) {
            .codepoint_property => try readCodepointPropertyFile(io, allocator, ucd_dir, &db, &aliases, entry),
            else => {},
        }
    }

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.print("runicode-gen: loaded {d} property groups\n", .{db.propertyCount()});
    try stdout_writer.interface.flush();

    std.process.cleanExit(io);
}

fn readCodepointPropertyFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    ucd_dir: std.Io.Dir,
    db: *Db,
    aliases: *Aliases,
    entry: manifest.UcdFile,
) !void {
    var file = try ucd_dir.openFile(io, entry.path, .{});
    defer file.close(io);

    var in_buf: [4096]u8 = undefined;
    var in_reader = file.reader(io, &in_buf);
    while (try in_reader.interface.takeDelimiter('\n')) |line| {
        var field_list = try parse.fields(allocator, line);
        defer field_list.deinit(allocator);

        if (field_list.items.len == 0) continue;
        if (field_list.items.len < 2 or field_list.items.len > 3) return error.InvalidCodepointPropertyLine;

        const range = try parse.parseCodepointRange(field_list.items[0]);
        const raw_property = entry.property orelse field_list.items[1];
        const property = aliases.canonicalProperty(raw_property) orelse raw_property;
        const raw_value = if (entry.property != null)
            field_list.items[1]
        else if (field_list.items.len == 3)
            field_list.items[2]
        else
            "Y";
        const value = aliases.canonicalValue(property, raw_value) orelse raw_value;

        try db.addRange(property, value, range);
    }
}
