const std = @import("std");

fn sourceSection(start: []const u8, end: []const u8) []const u8 {
    const source = @embedFile("src/main.zig");
    const first = std.mem.indexOf(u8, source, start) orelse std.debug.panic("Missing read harness start: {s}", .{start});
    const rest = source[first..];
    const last = std.mem.indexOf(u8, rest, end) orelse std.debug.panic("Missing read harness end: {s}", .{end});
    return rest[0..last];
}

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
    "src/dsp/alpha_processing_neon.c",
    "src/dsp/cpu.c",
    "src/dsp/dec.c",
    "src/dsp/dec_clip_tables.c",
    "src/dsp/dec_sse2.c",
    "src/dsp/dec_neon.c",
    "src/dsp/filters.c",
    "src/dsp/filters_sse2.c",
    "src/dsp/filters_neon.c",
    "src/dsp/lossless.c",
    "src/dsp/lossless_sse2.c",
    "src/dsp/lossless_neon.c",
    "src/dsp/rescaler.c",
    "src/dsp/rescaler_sse2.c",
    "src/dsp/rescaler_neon.c",
    "src/dsp/upsampling.c",
    "src/dsp/upsampling_sse2.c",
    "src/dsp/upsampling_neon.c",
    "src/dsp/yuv.c",
    "src/dsp/yuv_sse2.c",
    "src/dsp/yuv_neon.c",
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

// Files of the vendored libopus 1.5.2 (fixed-point, see vendor/libopus/VENDORED.txt).
const libopus_sources = [_][]const u8{
    "celt/bands.c",
    "celt/celt.c",
    "celt/celt_encoder.c",
    "celt/celt_decoder.c",
    "celt/cwrs.c",
    "celt/entcode.c",
    "celt/entdec.c",
    "celt/entenc.c",
    "celt/kiss_fft.c",
    "celt/laplace.c",
    "celt/mathops.c",
    "celt/mdct.c",
    "celt/modes.c",
    "celt/pitch.c",
    "celt/celt_lpc.c",
    "celt/quant_bands.c",
    "celt/rate.c",
    "celt/vq.c",
    "silk/CNG.c",
    "silk/code_signs.c",
    "silk/init_decoder.c",
    "silk/decode_core.c",
    "silk/decode_frame.c",
    "silk/decode_parameters.c",
    "silk/decode_indices.c",
    "silk/decode_pulses.c",
    "silk/decoder_set_fs.c",
    "silk/dec_API.c",
    "silk/enc_API.c",
    "silk/encode_indices.c",
    "silk/encode_pulses.c",
    "silk/gain_quant.c",
    "silk/interpolate.c",
    "silk/LP_variable_cutoff.c",
    "silk/NLSF_decode.c",
    "silk/NSQ.c",
    "silk/NSQ_del_dec.c",
    "silk/PLC.c",
    "silk/shell_coder.c",
    "silk/tables_gain.c",
    "silk/tables_LTP.c",
    "silk/tables_NLSF_CB_NB_MB.c",
    "silk/tables_NLSF_CB_WB.c",
    "silk/tables_other.c",
    "silk/tables_pitch_lag.c",
    "silk/tables_pulses_per_block.c",
    "silk/VAD.c",
    "silk/control_audio_bandwidth.c",
    "silk/quant_LTP_gains.c",
    "silk/VQ_WMat_EC.c",
    "silk/HP_variable_cutoff.c",
    "silk/NLSF_encode.c",
    "silk/NLSF_VQ.c",
    "silk/NLSF_unpack.c",
    "silk/NLSF_del_dec_quant.c",
    "silk/process_NLSFs.c",
    "silk/stereo_LR_to_MS.c",
    "silk/stereo_MS_to_LR.c",
    "silk/check_control_input.c",
    "silk/control_SNR.c",
    "silk/init_encoder.c",
    "silk/control_codec.c",
    "silk/A2NLSF.c",
    "silk/ana_filt_bank_1.c",
    "silk/biquad_alt.c",
    "silk/bwexpander_32.c",
    "silk/bwexpander.c",
    "silk/debug.c",
    "silk/decode_pitch.c",
    "silk/inner_prod_aligned.c",
    "silk/lin2log.c",
    "silk/log2lin.c",
    "silk/LPC_analysis_filter.c",
    "silk/LPC_inv_pred_gain.c",
    "silk/table_LSF_cos.c",
    "silk/NLSF2A.c",
    "silk/NLSF_stabilize.c",
    "silk/NLSF_VQ_weights_laroia.c",
    "silk/pitch_est_tables.c",
    "silk/resampler.c",
    "silk/resampler_down2_3.c",
    "silk/resampler_down2.c",
    "silk/resampler_private_AR2.c",
    "silk/resampler_private_down_FIR.c",
    "silk/resampler_private_IIR_FIR.c",
    "silk/resampler_private_up2_HQ.c",
    "silk/resampler_rom.c",
    "silk/sigm_Q15.c",
    "silk/sort.c",
    "silk/sum_sqr_shift.c",
    "silk/stereo_decode_pred.c",
    "silk/stereo_encode_pred.c",
    "silk/stereo_find_predictor.c",
    "silk/stereo_quant_pred.c",
    "silk/LPC_fit.c",
    "silk/fixed/LTP_analysis_filter_FIX.c",
    "silk/fixed/LTP_scale_ctrl_FIX.c",
    "silk/fixed/corrMatrix_FIX.c",
    "silk/fixed/encode_frame_FIX.c",
    "silk/fixed/find_LPC_FIX.c",
    "silk/fixed/find_LTP_FIX.c",
    "silk/fixed/find_pitch_lags_FIX.c",
    "silk/fixed/find_pred_coefs_FIX.c",
    "silk/fixed/noise_shape_analysis_FIX.c",
    "silk/fixed/process_gains_FIX.c",
    "silk/fixed/regularize_correlations_FIX.c",
    "silk/fixed/residual_energy16_FIX.c",
    "silk/fixed/residual_energy_FIX.c",
    "silk/fixed/warped_autocorrelation_FIX.c",
    "silk/fixed/apply_sine_window_FIX.c",
    "silk/fixed/autocorr_FIX.c",
    "silk/fixed/burg_modified_FIX.c",
    "silk/fixed/k2a_FIX.c",
    "silk/fixed/k2a_Q16_FIX.c",
    "silk/fixed/pitch_analysis_core_FIX.c",
    "silk/fixed/vector_ops_FIX.c",
    "silk/fixed/schur64_FIX.c",
    "silk/fixed/schur_FIX.c",
    "src/opus.c",
    "src/opus_decoder.c",
    "src/opus_encoder.c",
    "src/extensions.c",
    "src/repacketizer.c",
    "src/wazig_nb_frames.c",
};

// Only the unit tests decode (round trip); the app only encodes.
const libopus_decoder_only = [_][]const u8{
    "celt/celt_decoder.c",
    "silk/dec_API.c",
    "silk/init_decoder.c",
    "silk/decode_core.c",
    "silk/decode_frame.c",
    "silk/decode_parameters.c",
    "silk/decode_indices.c",
    "silk/decode_pulses.c",
    "silk/decoder_set_fs.c",
    "silk/PLC.c",
    "silk/CNG.c",
    "src/opus_decoder.c",
};

fn addOpus(b: *std.Build, module: *std.Build.Module, with_decoder: bool) void {
    module.addIncludePath(b.path("vendor/libopus"));
    module.addIncludePath(b.path("vendor/libopus/include"));
    var files: std.ArrayList([]const u8) = .empty;
    for (libopus_sources) |file| {
        const decoder_only = for (libopus_decoder_only) |name| {
            if (std.mem.eql(u8, name, file)) break true;
        } else false;
        // wazig_nb_frames.c stands in for opus_decoder.c when no decoder is linked.
        const stand_in = std.mem.eql(u8, file, "src/wazig_nb_frames.c");
        if ((with_decoder and !stand_in) or (!with_decoder and !decoder_only)) files.append(b.allocator, file) catch @panic("Out of memory");
    }
    module.addCSourceFiles(.{
        .root = b.path("vendor/libopus"),
        .files = files.items,
        .flags = &.{ "-DHAVE_CONFIG_H", "-Ivendor/libopus/celt", "-Ivendor/libopus/silk", "-Ivendor/libopus/silk/fixed", "-Ivendor/libopus/src" },
    });
}

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
    // Baked credentials are only defaults so their owner skips the in-app
    // api_id/api_hash step; without them the Add Telegram flow asks for keys
    // at runtime and stores them in the registry. Builds never require them.
    const telegram_api_hash = b.option([]const u8, "telegram-api-hash", "Telegram application api_hash (baked default)") orelse "";
    build_info.addOption(i32, "telegram_api_id", telegram_api_id);
    build_info.addOption([]const u8, "telegram_api_hash", telegram_api_hash);

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
    addOpus(b, exe.root_module, false);
    exe.root_module.addOptions("build_info", build_info);
    exe.subsystem = .windows;
    exe.root_module.link_libc = true;
    for ([_][]const u8{
        "user32",
        // Before gdi32: newer gdi32 import libs also list the Script* calls,
        // and usp10.dll is the export every supported Windows has.
        "usp10",
        "gdi32",
        "kernel32",
        "comctl32",
        "ole32",
        "windowscodecs",
        "dwmapi",
        "mfuuid",
        "winhttp",
        "crypt32",
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

    // wazigctl.exe: console CLI that drives the running app over its
    // per-user control pipe (src/control.zig). Shipped next to Messages.exe.
    const ctl = b.addExecutable(.{
        .name = "wazigctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wazigctl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ctl.subsystem = .console;
    ctl.root_module.link_libc = true;
    ctl.root_module.linkSystemLibrary("kernel32", .{});
    const install_ctl = b.addInstallArtifact(ctl, .{});
    b.getInstallStep().dependOn(&install_ctl.step);
    b.step("wazigctl", "Build only wazigctl.exe").dependOn(&install_ctl.step);

    b.installFile("assets/IBMPlexSans-Regular.ttf", "bin/IBMPlexSans-Regular.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");

    // Tests live in Windows-free modules so they run on any host.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/chat_order.zig", "src/chat_reconcile.zig", "src/archive_rules.zig", "src/emoji_picker.zig", "src/shortcodes.zig", "src/played.zig", "src/pending_reads.zig", "src/update.zig", "src/avatar_mask.zig", "src/compose_layout.zig", "src/scrollbar.zig", "src/message_scroll.zig", "src/media_age.zig", "src/media_drain.zig", "src/paste_image.zig", "src/telegram_json.zig", "src/accounts.zig", "src/slack.zig", "src/message_filter.zig", "src/chat_cache.zig", "src/unfurl.zig", "src/auth_status.zig", "src/messenger_view.zig", "src/shortcuts.zig", "src/sidebar_nav.zig", "src/sync_gate.zig", "src/control.zig", "src/colr.zig", "src/bitmap_lru.zig", "src/format_request.zig", "src/voice_sent.zig", "src/send_args.zig", "src/voice_pos.zig", "src/mic_choice.zig" }) |test_root| {
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
    // Compile the actual UI decisions with host stubs, rather than testing
    // another copy of the state machine that can drift from main.zig.
    const read_harness_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/chat_reconcile_test.zig"),
        sourceSection("fn refreshMessages(", "/// WAZI-79: the WAL tick"),
        sourceSection("fn reconcileOpenChat(", "fn youSender("),
        "fn resultFor(job: WacliJob) WacliResult { var storage = WacliResult{}; const result = &storage;\n",
        sourceSection("    result.* = .{ .kind = job.kind", "    switch (job.kind)"),
        "return storage; }\nfn deliverChats(a: *App, result: *const WacliResult) void {\n",
        sourceSection("                    // A stale failure must not restart", "                },\n                .messages =>"),
        "}\nfn deliver(a: *App, result: *WacliResult) void { a.pending -= 1;\n",
        sourceSection("                    // Chat kind + error only", "                },\n                .reaction =>"),
        "}\nfn tick(a: *App) void {\n",
        sourceSection("                if (a.msg_read_retry_ticks > 0)", "                if (changed and"),
        "}\n",
        sourceSection("fn applyMessageData(", "    var selected_id = Utf8Text(191){};"),
        "_ = list; _ = chat_changed; a.painted += 1;\n",
        sourceSection("    a.displayed_jid.set(chat.jid.slice());\n    //", "    // Optimistic bubbles"),
        "return true; }\n",
    }) catch @panic("Out of memory building read harness");
    const read_harness = b.addWriteFiles().add("chat_reconcile_test.zig", read_harness_source);
    const read_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = read_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{.{ .name = "chat_reconcile", .module = b.createModule(.{
            .root_source_file = b.path("src/chat_reconcile.zig"),
            .target = b.resolveTargetQuery(.{}),
        }) }},
    }) });
    test_step.dependOn(&b.addRunArtifact(read_tests).step);

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

    // voice_note.zig tests also use the host target; they run the vendored
    // libopus encoder and decoder against a generated tone.
    const voice_module = b.createModule(.{
        .root_source_file = b.path("src/voice_note.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
        .link_libc = true,
    });
    addOpus(b, voice_module, true);
    const voice_tests = b.addTest(.{ .root_module = voice_module });
    test_step.dependOn(&b.addRunArtifact(voice_tests).step);
}
