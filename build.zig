const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fdt_dep = b.dependency("fdt", .{
        .target = target,
        .optimize = optimize,
    });

    const fdt_upstream = fdt_dep.builder.dependency("fdt", .{});

    const kmod_dep = b.dependency("kmod", .{
        .target = target,
        .optimize = optimize,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(fdt_upstream.path("libfdt"));

    const exe = b.addExecutable(.{
        .name = "modextractor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = translate_c.createModule() },
                .{ .name = "kmod", .module = kmod_dep.module("kmod") },
            },
        }),
    });
    exe.linkLibrary(fdt_dep.artifact("fdt"));
    exe.linkLibrary(kmod_dep.artifact("kmod"));
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
