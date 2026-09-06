const std = @import("std");

// Files of the vendored libwebp 1.4.0 subset that decodes WebP (see vendor/libwebp).
const libwebp_sources = [_][]const u8{
    "src/dec/alpha_dec.c",
    "src/dec/buffer_dec.c",
    "src/dec/frame_dec.c",
    "src/dec/idec_dec.c",
    "src/dec/io_dec.c",
    "src/dec/quant_dec.c",
    "src/dec/tree_dec.c",
    "src/dec/vp8_dec.c",
    "src/dec/vp8l_dec.c",
    "src/dec/webp_dec.c",
    "src/dsp/alpha_processing.c",
    "src/dsp/alpha_processing_sse2.c",
    "src/dsp/cpu.c",
    "src/dsp/dec.c",
    "src/dsp/dec_clip_tables.c",
    "src/dsp/dec_sse2.c",
    "src/dsp/filters.c",
    "src/dsp/filters_sse2.c",
    "src/dsp/lossless.c",
    "src/dsp/lossless_sse2.c",
    "src/dsp/rescaler.c",
    "src/dsp/rescaler_sse2.c",
    "src/dsp/upsampling.c",
    "src/dsp/upsampling_sse2.c",
    "src/dsp/yuv.c",
    "src/dsp/yuv_sse2.c",
    "src/utils/bit_reader_utils.c",
    "src/utils/color_cache_utils.c",
    "src/utils/filters_utils.c",
    "src/utils/huffman_utils.c",
    "src/utils/palette.c",
    "src/utils/quant_levels_dec_utils.c",
    "src/utils/random_utils.c",
    "src/utils/rescaler_utils.c",
    "src/utils/thread_utils.c",
    "src/utils/utils.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    // ponytail: local builds without -Dversion report 0.9.7 to the self-update check;
    // upgrade path: make -Dversion required once CI is the only release builder.
    const version = b.option([]const u8, "version", "App version embedded for self-update (e.g. 0.9.7)") orelse "0.9.7";

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "Messages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Vendored libwebp 1.4.0 (decode-only): Windows WIC has no WebP codec, so
    // stickers need this to render.
    exe.root_module.addIncludePath(b.path("vendor/libwebp"));
    exe.root_module.addCSourceFiles(.{ .root = b.path("vendor/libwebp"), .files = &libwebp_sources });
    exe.root_module.addOptions("build_info", build_info);
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
        "mfplay",
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

    // Tests live in Windows-free modules so they run on any host.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/emoji_picker.zig", "src/played.zig", "src/update.zig" }) |test_root| {
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
    // webp.zig tests use the host target: they must run on the CI machine
    // even when the exe is cross-compiled for Windows.
    const webp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/webp.zig"),
            .target = b.resolveTargetQuery(.{}),
        }),
    });
    const run_webp_tests = b.addRunArtifact(webp_tests);
    test_step.dependOn(&run_webp_tests.step);
}
