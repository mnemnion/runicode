const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Tool module for internal use
    const tool_mod = b.addModule("ucd_tools", .{
        .root_source_file = b.path("src/gen/ucd-tools.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ezcaper_dep = b.dependency("ezcaper", .{
        .target = target,
        .optimize = optimize,
    });

    tool_mod.addImport("ezcaper", ezcaper_dep.module("ezcaper"));

    const runeset_dep = b.dependency("runeset", .{
        .target = target,
        .optimize = optimize,
    });

    tool_mod.addImport("runeset", runeset_dep.module("runeset"));

    // Generator Steps
    //
    // I'm just going to do this directly with custom executables, rather than
    // figure out how to follow the Approved Method within the Zig build system.

    // General Categories

    const gen_cat_exe = b.addExecutable(.{
        .name = "gen_cat",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gen/gen_cat.zig"),
    });

    gen_cat_exe.root_module.addImport("ucd-tools", tool_mod);

    b.installArtifact(gen_cat_exe);

    const run_gencat = b.addRunArtifact(gen_cat_exe);

    const run_gencat_step = b.step("gen-cat", "generate files for General Categories");

    run_gencat_step.dependOn(&run_gencat.step);

    // Scripts

    const scripts_exe = b.addExecutable(.{
        .name = "scripts",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gen/scripts.zig"),
    });

    scripts_exe.root_module.addImport("ucd-tools", tool_mod);

    b.installArtifact(scripts_exe);

    const run_scripts = b.addRunArtifact(scripts_exe);

    const run_scripts_step = b.step("scripts", "generate files for Scripts");

    run_scripts_step.dependOn(&run_scripts.step);

    // Core Properties

    const props_exe = b.addExecutable(.{
        .name = "props",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gen/props.zig"),
    });

    props_exe.root_module.addImport("ucd-tools", tool_mod);

    b.installArtifact(props_exe);

    const run_props = b.addRunArtifact(props_exe);

    const run_props_step = b.step("props", "generate files for Properties");

    run_props_step.dependOn(&run_props.step);

    // Outward-facing Modules

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
