const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const exe = b.addExecutable(.{
        .name = "Messages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.subsystem = .windows;
    exe.root_module.link_libc = true;
    for ([_][]const u8{
        "user32",
        "gdi32",
        "kernel32",
        "comctl32",
        "ole32",
        "windowscodecs",
        "shell32",
        "dwmapi",
    }) |library| {
        exe.root_module.linkSystemLibrary(library, .{});
    }
    b.installArtifact(exe);

    // Tests must target Windows because main.zig @cImports windows.h; run them
    // under Windows (CI) or wine locally.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
            .optimize = optimize,
        }),
    });
    tests.root_module.link_libc = true;
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    b.installFile("assets/IBMPlexSans-Regular.ttf", "bin/IBMPlexSans-Regular.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");
}
