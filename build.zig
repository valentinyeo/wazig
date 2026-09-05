const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // Release CI passes -Dversion=<tag without the v>; local builds fall back to the current line.
    const app_version = b.option([]const u8, "version", "App version embedded in the exe") orelse "0.9.7";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", app_version);

    const exe = b.addExecutable(.{
        .name = "Messages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
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
        "mfplat",
        "mfreadwrite",
        "mfuuid",
        "winhttp",
        "urlmon",
    }) |library| {
        exe.root_module.linkSystemLibrary(library, .{});
    }
    b.installArtifact(exe);
    b.installFile("assets/IBMPlexSans-Regular.ttf", "bin/IBMPlexSans-Regular.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");

    // Tests live in Windows-free modules so they run on any host.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emoji_picker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
