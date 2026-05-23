const std = @import("std");
const audit = @import("ucd/audit.zig");
const alias_data = @import("ucd/aliases.zig");
const emit = @import("ucd/emit.zig");
const jobs_data = @import("ucd/jobs.zig");
const worker = @import("ucd/worker.zig");
const manifest = @import("ucd/manifest.zig");
const testing = std.testing;

comptime {
    std.testing.refAllDecls(worker);
}

const Aliases = alias_data.Aliases;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len != 3) return error.InvalidArguments;

    var ucd_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer ucd_dir.close(io);
    try std.Io.Dir.cwd().deleteTree(io, argv[2]);
    try std.Io.Dir.cwd().createDirPath(io, argv[2]);
    var out_dir = try std.Io.Dir.cwd().openDir(io, argv[2], .{});
    defer out_dir.close(io);

    try audit.auditDir(io, allocator, ucd_dir);
    var aliases = alias_data.Aliases.init(allocator);
    defer aliases.deinit();

    try aliases.loadPropertyAliasesFile(io, ucd_dir);
    try aliases.loadPropertyValueAliasesFile(io, ucd_dir);

    const stats = try runJobs(io, allocator, init.gpa, ucd_dir, out_dir, &aliases, &manifest.known_files);

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.print("runicode-gen: completed {d} jobs, loaded {d} property groups\n", .{ stats.jobs, stats.groups });
    try stdout_writer.interface.flush();

    std.process.cleanExit(io);
}

const RunStats = struct {
    jobs: usize,
    groups: usize,
};

fn runJobs(
    io: std.Io,
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    ucd_dir: std.Io.Dir,
    out_dir: std.Io.Dir,
    aliases: *const Aliases,
    entries: []const manifest.UcdFile,
) !RunStats {
    try precreateOutputDirs(io, out_dir);

    const planned_jobs = try jobs_data.jobs(allocator, entries);
    defer jobs_data.freeJobs(allocator, planned_jobs);

    var futures: std.ArrayList(std.Io.Future(anyerror!worker.WorkerStats)) = .empty;
    defer futures.deinit(allocator);
    try futures.ensureTotalCapacity(allocator, planned_jobs.len);

    var group_meta: std.ArrayList(emit.GroupMeta) = .empty;
    defer {
        freeGroupMetaItems(allocator, group_meta.items);
        group_meta.deinit(allocator);
    }

    var first_error: ?anyerror = null;

    for (planned_jobs) |job| {
        const future = std.Io.concurrent(io, worker.runJob, .{ io, gpa, ucd_dir, out_dir, aliases, job }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                const stats = worker.runJob(io, gpa, ucd_dir, out_dir, aliases, job) catch |worker_err| {
                    if (first_error == null) first_error = worker_err;
                    continue;
                };
                appendWorkerStats(allocator, &group_meta, stats) catch |append_err| {
                    if (first_error == null) first_error = append_err;
                };
                continue;
            },
        };
        futures.appendAssumeCapacity(future);
    }

    for (futures.items) |*future| {
        const stats = future.await(io) catch |worker_err| {
            if (first_error == null) first_error = worker_err;
            continue;
        };
        appendWorkerStats(allocator, &group_meta, stats) catch |append_err| {
            if (first_error == null) first_error = append_err;
        };
    }

    if (first_error) |err| return err;

    const groups = try group_meta.toOwnedSlice(allocator);
    defer emit.freeGroupMeta(allocator, groups);
    try emit.emitRootIndexes(allocator, .{ .io = io, .dir = out_dir }, groups, aliases);

    return .{
        .jobs = planned_jobs.len,
        .groups = groups.len,
    };
}

fn precreateOutputDirs(io: std.Io, out_dir: std.Io.Dir) !void {
    inline for (.{ "sets", "codepoints", "strs", "maps" }) |path| {
        _ = try out_dir.createDirPath(io, path);
    }
}

fn appendWorkerStats(
    allocator: std.mem.Allocator,
    group_meta: *std.ArrayList(emit.GroupMeta),
    stats: worker.WorkerStats,
) !void {
    defer stats.deinit();

    const start = group_meta.items.len;
    errdefer freeGroupMetaItems(allocator, group_meta.items[start..]);

    try group_meta.ensureUnusedCapacity(allocator, stats.groups.len);
    for (stats.groups) |group| {
        const name = try allocator.dupe(u8, group.name);
        errdefer allocator.free(name);

        const values = try allocator.alloc([]const u8, group.values.len);
        var value_count: usize = 0;
        errdefer {
            for (values[0..value_count]) |value| allocator.free(value);
            allocator.free(values);
        }

        for (group.values, values) |value, *owned_value| {
            owned_value.* = try allocator.dupe(u8, value);
            value_count += 1;
        }

        group_meta.appendAssumeCapacity(.{
            .name = name,
            .values = values,
        });
    }
}

fn freeGroupMetaItems(allocator: std.mem.Allocator, groups: []const emit.GroupMeta) void {
    for (groups) |group| {
        allocator.free(group.name);
        for (group.values) |value| allocator.free(value);
        allocator.free(group.values);
    }
}

test "runJobs dispatches workers and writes root indexes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Blocks.txt",
        .data =
        \\0041; Basic Latin
        \\
        ,
    });
    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);

    var aliases = Aliases.init(testing.allocator);
    defer aliases.deinit();
    try aliases.loadPropertyLine("blk ; Block");
    try aliases.loadPropertyValueLine("blk ; Basic_Latin ; Basic Latin");

    const stats = try runJobs(testing.io, testing.allocator, testing.allocator, tmp.dir, out, &aliases, &.{
        .{ .path = "Blocks.txt", .kind = .codepoint_property, .property = "blk", .namespace = "Blocks" },
    });

    try testing.expectEqual(@as(usize, 1), stats.jobs);
    try testing.expectEqual(@as(usize, 1), stats.groups);
    var root = try out.openFile(testing.io, "runicode.zig", .{});
    root.close(testing.io);
    var sets = try out.openFile(testing.io, "sets.zig", .{});
    sets.close(testing.io);
    var leaf = try out.openFile(testing.io, "sets/blocks/Basic_Latin.zig", .{});
    leaf.close(testing.io);
}
