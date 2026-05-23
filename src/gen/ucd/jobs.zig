const std = @import("std");
const testing = std.testing;

const manifest = @import("manifest.zig");

pub const JobKind = enum {
    namespace,
    scripts_bundle,
    general_category,
    core_properties,
};

pub const Job = struct {
    kind: JobKind,
    namespace: []const u8,
    entries: []const manifest.UcdFile,
};

pub fn freeJobs(allocator: std.mem.Allocator, built: []const Job) void {
    for (built) |job| allocator.free(job.entries);
    allocator.free(built);
}

const PendingJob = struct {
    kind: JobKind,
    namespace: []const u8,
    entries: std.ArrayList(manifest.UcdFile) = .empty,

    fn deinit(pending: *PendingJob, allocator: std.mem.Allocator) void {
        pending.entries.deinit(allocator);
    }
};

pub fn jobs(allocator: std.mem.Allocator, entries: []const manifest.UcdFile) ![]Job {
    var pending: std.ArrayList(PendingJob) = .empty;
    defer {
        for (pending.items) |*item| item.deinit(allocator);
        pending.deinit(allocator);
    }

    for (entries) |entry| {
        if (!emitsSetGroup(entry.kind)) continue;
        const namespace = entry.namespace orelse continue;
        const kind = kindForEntry(entry);
        const job_namespace = namespaceForKind(kind, namespace);
        const slot = try pendingJob(allocator, &pending, kind, job_namespace);
        try slot.entries.append(allocator, entry);
    }

    std.mem.sort(PendingJob, pending.items, {}, pendingLessThan);

    const built = try allocator.alloc(Job, pending.items.len);
    errdefer allocator.free(built);

    for (pending.items, built) |item, *job| {
        std.mem.sort(manifest.UcdFile, item.entries.items, {}, entryLessThan);
        const job_entries = try allocator.dupe(manifest.UcdFile, item.entries.items);
        errdefer allocator.free(job_entries);
        job.* = .{
            .kind = item.kind,
            .namespace = item.namespace,
            .entries = job_entries,
        };
    }

    return built;
}

fn emitsSetGroup(kind: manifest.FileKind) bool {
    return switch (kind) {
        .codepoint_property, .script_extensions => true,
        else => false,
    };
}

fn kindForEntry(entry: manifest.UcdFile) JobKind {
    if (std.mem.eql(u8, entry.path, "Scripts.txt") or std.mem.eql(u8, entry.path, "ScriptExtensions.txt")) {
        return .scripts_bundle;
    }
    if (std.mem.eql(u8, entry.namespace orelse "", "GeneralCategory")) return .general_category;
    if (std.mem.eql(u8, entry.namespace orelse "", "CoreProperties")) return .core_properties;
    return .namespace;
}

fn namespaceForKind(kind: JobKind, namespace: []const u8) []const u8 {
    return switch (kind) {
        .scripts_bundle => "Scripts",
        else => namespace,
    };
}

fn pendingJob(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(PendingJob),
    kind: JobKind,
    namespace: []const u8,
) !*PendingJob {
    for (pending.items) |*item| {
        if (item.kind == kind and std.mem.eql(u8, item.namespace, namespace)) return item;
    }
    try pending.append(allocator, .{
        .kind = kind,
        .namespace = namespace,
    });
    return &pending.items[pending.items.len - 1];
}

fn pendingLessThan(_: void, lhs: PendingJob, rhs: PendingJob) bool {
    return std.mem.lessThan(u8, lhs.namespace, rhs.namespace);
}

fn entryLessThan(_: void, lhs: manifest.UcdFile, rhs: manifest.UcdFile) bool {
    if (std.mem.eql(u8, lhs.path, "Scripts.txt")) return true;
    if (std.mem.eql(u8, rhs.path, "Scripts.txt")) return false;
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

test "scripts and script extensions are bundled into one job" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const built = try jobs(arena.allocator(), &.{
        .{ .path = "Scripts.txt", .kind = .codepoint_property, .property = "sc", .namespace = "Scripts" },
        .{ .path = "ScriptExtensions.txt", .kind = .script_extensions, .property = "scx", .namespace = "ScriptsExtended" },
    });

    try testing.expectEqual(@as(usize, 1), built.len);
    try testing.expectEqual(JobKind.scripts_bundle, built[0].kind);
    try testing.expectEqualStrings("Scripts", built[0].namespace);
    try testing.expectEqual(@as(usize, 2), built[0].entries.len);
    try testing.expectEqualStrings("Scripts.txt", built[0].entries[0].path);
    try testing.expectEqualStrings("ScriptExtensions.txt", built[0].entries[1].path);
}

test "unrelated namespaces remain separate deterministic jobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const built = try jobs(arena.allocator(), &.{
        .{ .path = "PropList.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
        .{ .path = "Blocks.txt", .kind = .codepoint_property, .property = "blk", .namespace = "Blocks" },
        .{ .path = "extracted/DerivedGeneralCategory.txt", .kind = .codepoint_property, .property = "gc", .namespace = "GeneralCategory" },
        .{ .path = "emoji/emoji-data.txt", .kind = .codepoint_property, .namespace = "CoreProperties" },
    });

    try testing.expectEqual(@as(usize, 3), built.len);
    try testing.expectEqual(JobKind.namespace, built[0].kind);
    try testing.expectEqualStrings("Blocks", built[0].namespace);
    try testing.expectEqual(@as(usize, 1), built[0].entries.len);
    try testing.expectEqual(JobKind.core_properties, built[1].kind);
    try testing.expectEqualStrings("CoreProperties", built[1].namespace);
    try testing.expectEqual(@as(usize, 2), built[1].entries.len);
    try testing.expectEqualStrings("PropList.txt", built[1].entries[0].path);
    try testing.expectEqualStrings("emoji/emoji-data.txt", built[1].entries[1].path);
    try testing.expectEqual(JobKind.general_category, built[2].kind);
    try testing.expectEqualStrings("GeneralCategory", built[2].namespace);
}

test "non set-emitting manifest entries are skipped in first threaded pass" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const built = try jobs(arena.allocator(), &.{
        .{ .path = "UnicodeData.txt", .kind = .unicode_data, .namespace = "UnicodeData" },
        .{ .path = "NameAliases.txt", .kind = .records, .namespace = "NameAliases" },
        .{ .path = "Blocks.txt", .kind = .codepoint_property, .property = "blk", .namespace = "Blocks" },
    });

    try testing.expectEqual(@as(usize, 1), built.len);
    try testing.expectEqualStrings("Blocks", built[0].namespace);
}
