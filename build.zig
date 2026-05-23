const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Tool module for internal use
    const tool_mod = b.createModule(.{
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

    const unicoder_dep = b.dependency("unicoder", .{
        .target = target,
        .optimize = optimize,
    });

    tool_mod.addImport("unicoder", unicoder_dep.module("unicoder"));

    // Generator Steps
    //
    // I'm just going to do this directly with custom executables, rather than
    // figure out how to follow the Approved Method within the Zig build system.

    const runicode_gen_exe = b.addExecutable(.{
        .name = "runicode-gen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = optimize,
            .root_source_file = b.path("src/gen/runicode-gen.zig"),
        }),
    });

    b.installArtifact(runicode_gen_exe);
    runicode_gen_exe.root_module.addImport("runeset", runeset_dep.module("runeset"));

    const run_gen = b.addRunArtifact(runicode_gen_exe);
    run_gen.addDirectoryArg(b.path("UCD"));
    const generated_dir = run_gen.addOutputDirectoryArg("runicode-generated");
    const generated_runicode = generated_dir.path(b, "runicode.zig");
    const install_generated_code = b.addInstallDirectory(.{
        .source_dir = generated_dir,
        .install_dir = .{ .custom = "gen" },
        .install_subdir = "",
        .exclude_extensions = &.{".DS_Store"},
    });
    install_generated_code.step.dependOn(&CleanInstallDir.create(b, .{ .custom = "gen" }, "").step);

    const run_runicode_gen_step = b.step("gen-runicode", "audit bundled Unicode data files");

    run_runicode_gen_step.dependOn(&run_gen.step);
    const install_code_step = b.step("install-code", "Install generated runicode source into zig-out/gen");
    install_code_step.dependOn(&install_generated_code.step);

    // Outward-facing Modules

    const runicode_mod = b.addModule("runicode", .{
        .root_source_file = generated_runicode,
        .target = target,
        .optimize = optimize,
    });

    runicode_mod.addImport("runeset", runeset_dep.module("runeset"));
    runicode_mod.addImport("ucd-tools", tool_mod);

    const tool_unit_tests = b.addTest(.{
        .root_module = tool_mod,
    });

    const run_tool_unit_tests = b.addRunArtifact(tool_unit_tests);

    const gen_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/gen/runicode-gen.zig"),
        }),
    });
    gen_unit_tests.root_module.addImport("runeset", runeset_dep.module("runeset"));

    const run_gen_unit_tests = b.addRunArtifact(gen_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tool_unit_tests.step);
    test_step.dependOn(&run_gen_unit_tests.step);
}

const CleanInstallDir = struct {
    step: std.Build.Step,
    install_dir: std.Build.InstallDir,
    install_subdir: []const u8,

    fn create(b: *std.Build, install_dir: std.Build.InstallDir, install_subdir: []const u8) *CleanInstallDir {
        const clean = b.allocator.create(CleanInstallDir) catch @panic("OOM");
        clean.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("clean install {s}/", .{install_subdir}),
                .owner = b,
                .makeFn = make,
            }),
            .install_dir = install_dir.dupe(b),
            .install_subdir = b.dupe(install_subdir),
        };
        return clean;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const clean: *CleanInstallDir = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const dest = b.getInstallPath(clean.install_dir, clean.install_subdir);
        std.Io.Dir.cwd().deleteTree(io, dest) catch |err| {
            return step.fail("unable to remove install directory '{s}': {t}", .{ dest, err });
        };
    }
};
