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
    exe.subsystem = .Windows;
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
        "mfplat",
        "mfplay",
        "urlmon",
    }) |library| {
        exe.root_module.linkSystemLibrary(library, .{});
    }
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/app.rc") });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/emoji_picker.zig", "src/avatar.zig", "src/avatar_cache.zig" }) |test_root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_root),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    b.installFile("assets/IBMPlexSans-Regular.ttf", "bin/IBMPlexSans-Regular.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");
}
