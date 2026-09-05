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
        "mfplat",
        "mfreadwrite",
        "mfuuid",
        "winhttp",
        "urlmon",
    }) |library| {
        exe.root_module.linkSystemLibrary(library, .{});
    }
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/app.rc") });
    b.installArtifact(exe);
    b.installFile("assets/IBMPlexSans-Regular.ttf", "bin/IBMPlexSans-Regular.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");
}
