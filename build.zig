const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // String generation

    const gen_cat_str_exe = b.addExecutable(.{
        .name = "gen_cat",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gen/gen_cat_string.zig"),
    });

    b.installArtifact(gen_cat_str_exe);

    const run_gencatstr = b.addRunArtifact(gen_cat_str_exe);

    const run_gencat_step = b.step("gen-cat-str", "generate strings namespace for General Categories");

    run_gencat_step.dependOn(&run_gencatstr.step);

    _ = b.addModule("runicode", .{
        .root_source_file = b.path("src/runicode.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/runicode.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
