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

    const run_gen = b.addRunArtifact(runicode_gen_exe);
    run_gen.addDirectoryArg(b.path("UCD"));
    const generated_sets = run_gen.addOutputFileArg("sets.zig");
    const generated_codepoints = run_gen.addOutputFileArg("codepoints.zig");
    const generated_strs = run_gen.addOutputFileArg("strs.zig");
    const generated_enums = run_gen.addOutputFileArg("enums.zig");
    const generated_maps = run_gen.addOutputFileArg("maps.zig");

    const run_runicode_gen_step = b.step("gen-runicode", "audit bundled Unicode data files");

    run_runicode_gen_step.dependOn(&run_gen.step);

    // General Categories
    {
        const gen_cat_exe = b.addExecutable(.{
            .name = "gen_cat",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gen/gen_cat.zig"),
            }),
        });

        gen_cat_exe.root_module.addImport("ucd-tools", tool_mod);

        b.installArtifact(gen_cat_exe);

        const run_gencat = b.addRunArtifact(gen_cat_exe);

        const run_gencat_step = b.step("gen-cat", "generate files for General Categories");

        run_gencat_step.dependOn(&run_gencat.step);
    }

    // Scripts
    {
        const scripts_exe = b.addExecutable(.{
            .name = "scripts",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gen/scripts.zig"),
            }),
        });

        scripts_exe.root_module.addImport("ucd-tools", tool_mod);

        b.installArtifact(scripts_exe);

        const run_scripts = b.addRunArtifact(scripts_exe);

        const run_scripts_step = b.step("scripts", "generate files for Scripts");

        run_scripts_step.dependOn(&run_scripts.step);
    }

    // Blocks
    {
        const blocks_exe = b.addExecutable(.{
            .name = "blocks",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gen/blocks.zig"),
            }),
        });

        blocks_exe.root_module.addImport("ucd-tools", tool_mod);

        b.installArtifact(blocks_exe);

        const run_blocks = b.addRunArtifact(blocks_exe);

        const run_blocks_step = b.step("blocks", "generate files for blocks");

        run_blocks_step.dependOn(&run_blocks.step);
    }

    // Core Properties
    {
        const props_exe = b.addExecutable(.{
            .name = "props",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gen/props.zig"),
            }),
        });

        props_exe.root_module.addImport("ucd-tools", tool_mod);

        b.installArtifact(props_exe);

        const run_props = b.addRunArtifact(props_exe);

        const run_props_step = b.step("props", "generate files for Properties");

        run_props_step.dependOn(&run_props.step);
    }

    // Auxiliary Properties
    {
        const aux_props_exe = b.addExecutable(.{
            .name = "aux_props",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gen/aux_props.zig"),
            }),
        });

        aux_props_exe.root_module.addImport("ucd-tools", tool_mod);

        b.installArtifact(aux_props_exe);

        const run_aux_props = b.addRunArtifact(aux_props_exe);

        const run_aux_props_step = b.step("aux-props", "generate files for auxiliary properties");

        run_aux_props_step.dependOn(&run_aux_props.step);
    }

    // Outward-facing Modules

    const runicode_mod = b.addModule("runicode", .{
        .root_source_file = b.path("src/runicode.zig"),
        .target = target,
        .optimize = optimize,
    });

    runicode_mod.addImport("runeset", runeset_dep.module("runeset"));
    runicode_mod.addImport("ucd-tools", tool_mod);

    const generated_sets_mod = b.createModule(.{
        .root_source_file = generated_sets,
        .target = target,
        .optimize = optimize,
    });
    generated_sets_mod.addImport("runeset", runeset_dep.module("runeset"));

    const generated_codepoints_mod = b.createModule(.{
        .root_source_file = generated_codepoints,
        .target = target,
        .optimize = optimize,
    });

    const generated_strs_mod = b.createModule(.{
        .root_source_file = generated_strs,
        .target = target,
        .optimize = optimize,
    });

    const generated_enums_mod = b.createModule(.{
        .root_source_file = generated_enums,
        .target = target,
        .optimize = optimize,
    });

    const generated_maps_mod = b.createModule(.{
        .root_source_file = generated_maps,
        .target = target,
        .optimize = optimize,
    });
    generated_maps_mod.addImport("ucd-tools", tool_mod);
    generated_maps_mod.addImport("generated_sets", generated_sets_mod);
    generated_maps_mod.addImport("generated_codepoints", generated_codepoints_mod);
    generated_maps_mod.addImport("generated_strs", generated_strs_mod);
    generated_maps_mod.addImport("generated_enums", generated_enums_mod);

    runicode_mod.addImport("generated_sets", generated_sets_mod);
    runicode_mod.addImport("generated_codepoints", generated_codepoints_mod);
    runicode_mod.addImport("generated_strs", generated_strs_mod);
    runicode_mod.addImport("generated_enums", generated_enums_mod);
    runicode_mod.addImport("generated_maps", generated_maps_mod);

    const lib_unit_tests = b.addTest(.{
        .root_module = runicode_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const tool_unit_tests = b.addTest(.{
        .root_module = tool_mod,
    });

    const run_tool_unit_tests = b.addRunArtifact(tool_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_tool_unit_tests.step);
}
