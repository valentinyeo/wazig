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

    // Telegram (TDLib) support: -Dtdlib=<dir> points at a directory holding
    // include/td/... and the static tdjson_static libraries. Without it the
    // build compiles src/telegram_stub.zig instead and Telegram stays off.
    const tdlib_dir = b.option([]const u8, "tdlib", "Path to a built TDLib static install") orelse "";
    const td_enabled = tdlib_dir.len > 0;
    build_info.addOption(bool, "td_enabled", td_enabled);
    const telegram_api_id = b.option(i32, "telegram-api-id", "Telegram application api_id (build-time, from CI secret)") orelse 0;
    const telegram_api_hash = b.option([]const u8, "telegram-api-hash", "Telegram application api_hash (build-time, from CI secret)") orelse "";
    build_info.addOption(i32, "telegram_api_id", telegram_api_id);
    build_info.addOption([]const u8, "telegram_api_hash", telegram_api_hash);
    if (td_enabled and (telegram_api_id == 0 or telegram_api_hash.len == 0) and (optimize == .ReleaseSmall or optimize == .ReleaseFast or optimize == .ReleaseSafe)) {
        // A release build without credentials would ship a binary where the
        // Telegram login can never succeed: fail the build instead.
        std.debug.print("error: -Dtdlib requires -Dtelegram-api-id and -Dtelegram-api-hash in release builds\n", .{});
        std.process.exit(1);
    }

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
        "msimg32",
    }) |library| {
        exe.root_module.linkSystemLibrary(library, .{});
    }
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/app.rc") });
    if (td_enabled) {
        exe.root_module.addIncludePath(.{ .cwd_relative = tdlib_dir });
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ tdlib_dir, "include" }) });
        // Order matters: each archive may reference symbols in the next.
        const td_archives = [_][]const u8{
            "libtdjson_static.a", "libtdjson_private.a", "libtdclient.a", "libtdcore.a",
            "libtddb.a",          "libtdmtproto.a",      "libtdnet.a",    "libtdactor.a",
            "libtdapi.a",         "libtdutils.a",        "libtdsqlite.a", "libtde2e.a",
            // OpenSSL (static) and zlib are copied next to the TDLib archives.
            "libssl.a",           "libcrypto.a",         "libz.a",
        };
        for (td_archives) |archive| {
            const path = b.pathJoin(&.{ tdlib_dir, "lib", archive });
            exe.root_module.addObjectFile(.{ .cwd_relative = path });
        }
        // TDLib is compiled with the mingw g++, so it needs the mingw
        // libstdc++/libgcc (win32 threads variant) rather than zig's libc++.
        const mingw_lib_dir = b.option([]const u8, "mingw-lib-dir", "Path to the mingw win32-threads gcc lib directory") orelse "/usr/lib/gcc/x86_64-w64-mingw32/13-win32";
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libstdc++.a" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libgcc_eh.a" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libgcc.a" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libgcc_s.a" }) });
        // TDLib also needs the Windows socket/crypto stack.
        exe.root_module.link_libc = true;
        for ([_][]const u8{ "ws2_32", "iphlpapi", "crypt32", "bcrypt", "advapi32", "userenv", "ncrypt", "cryptbase", "secur32", "psapi" }) |library| {
            exe.root_module.linkSystemLibrary(library, .{});
        }
        // Shims for the dllimport _vsnprintf/_timezone symbols the mingw-built
        // TDLib/OpenSSL archives reference.
        exe.root_module.addCSourceFile(.{ .file = b.path("src/tdlib_mingw_shims.c"), .flags = &.{"-std=gnu11"} });
    }
    b.installArtifact(exe);

    b.installFile("assets/IBMPlexSans-Regular.ttf", "bin/IBMPlexSans-Regular.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");

    // Tests live in Windows-free modules so they run on any host.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/emoji_picker.zig", "src/played.zig", "src/update.zig", "src/avatar_mask.zig", "src/compose_layout.zig", "src/telegram_json.zig" }) |test_root| {
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
