const std = @import("std");

fn sourceSection(start: []const u8, end: []const u8) []const u8 {
    const source = @embedFile("src/main.zig");
    const first = std.mem.indexOf(u8, source, start) orelse std.debug.panic("Missing read harness start: {s}", .{start});
    const rest = source[first..];
    const last = std.mem.indexOf(u8, rest, end) orelse std.debug.panic("Missing read harness end: {s}", .{end});
    return rest[0..last];
}

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
    const version = b.option([]const u8, "version", "App version embedded for self-update (e.g. 0.9.7)") orelse "0.9.8";

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);

    const tdlib_dir = b.option([]const u8, "tdlib", "Path to a built TDLib static install") orelse "";
    const td_enabled = tdlib_dir.len > 0;
    build_info.addOption(bool, "td_enabled", td_enabled);
    const telegram_api_id = b.option(i32, "telegram-api-id", "Telegram application api_id (build-time, from CI secret)") orelse 0;
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
    exe.root_module.addIncludePath(b.path("vendor/libwebp"));
    exe.root_module.addCSourceFiles(.{ .root = b.path("vendor/libwebp"), .files = &libwebp_sources });
    addOpus(b, exe.root_module, false);
    exe.root_module.addOptions("build_info", build_info);
    exe.subsystem = .windows;
    exe.root_module.link_libc = true;
    for ([_][]const u8{
        "user32",
        "usp10",
        "gdi32",
        "kernel32",
        "comctl32",
        "ole32",
        "windowscodecs",
        "dwmapi",
        "mfuuid",
        "winhttp",
        "ws2_32",
        "crypt32",
        "msimg32",
    }) |library| {
        exe.root_module.linkSystemLibrary(library, .{});
    }
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/app.rc") });
    if (td_enabled) {
        exe.root_module.addIncludePath(.{ .cwd_relative = tdlib_dir });
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ tdlib_dir, "include" }) });
        const td_archives = [_][]const u8{
            "libtdjson_static.a", "libtdjson_private.a", "libtdclient.a", "libtdcore.a",
            "libtddb.a",          "libtdmtproto.a",      "libtdnet.a",    "libtdactor.a",
            "libtdapi.a",         "libtdutils.a",        "libtdsqlite.a", "libtde2e.a",
            "libssl.a",           "libcrypto.a",         "libz.a",
        };
        for (td_archives) |archive| {
            const path = b.pathJoin(&.{ tdlib_dir, "lib", archive });
            exe.root_module.addObjectFile(.{ .cwd_relative = path });
        }
        const mingw_lib_dir = b.option([]const u8, "mingw-lib-dir", "Path to the mingw win32-threads gcc lib directory") orelse b.pathJoin(&.{ tdlib_dir, "lib" });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libstdc++.a" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libgcc_eh.a" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libgcc.a" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mingw_lib_dir, "libgcc_s.a" }) });
        exe.root_module.link_libc = true;
        for ([_][]const u8{ "ws2_32", "iphlpapi", "crypt32", "bcrypt", "advapi32", "userenv", "ncrypt", "cryptbase", "secur32", "psapi" }) |library| {
            exe.root_module.linkSystemLibrary(library, .{});
        }
        exe.root_module.addCSourceFile(.{ .file = b.path("src/tdlib_mingw_shims.c"), .flags = &.{"-std=gnu11"} });
    }
    b.installArtifact(exe);

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
    b.installFile("assets/IBMPlexSans-Medium.ttf", "bin/IBMPlexSans-Medium.ttf");
    b.installFile("assets/IBMPlexSans-SemiBold.ttf", "bin/IBMPlexSans-SemiBold.ttf");
    b.installFile("assets/IBMPlexSans-Bold.ttf", "bin/IBMPlexSans-Bold.ttf");
    b.installFile("assets/IBM-Plex-LICENSE.txt", "bin/IBM-Plex-LICENSE.txt");

    const edit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/directwrite_edit.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    edit_tests.root_module.link_libc = true;
    for ([_][]const u8{ "user32", "gdi32", "msimg32", "ole32", "oleacc", "oleaut32" }) |library| edit_tests.root_module.linkSystemLibrary(library, .{});
    b.step("test-edit", "Run native DirectWrite editing tests on Windows").dependOn(&b.addRunArtifact(edit_tests).step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/attachments.zig", "src/staged_images.zig", "src/hub_test.zig", "src/wa_hub_test.zig", "src/pin_icon_test.zig", "src/message_double_click.zig", "src/reaction_chip.zig", "src/passage.zig", "src/recording_paint.zig", "src/font_config.zig", "src/edit_contract.zig", "src/drafts.zig", "src/theme.zig", "src/menu_theme.zig", "src/chat_key.zig", "src/chat_order.zig", "src/chat_rows.zig", "src/people_index.zig", "src/chat_reconcile.zig", "src/archive_rules.zig", "src/media_layout.zig", "src/chat_menu.zig", "src/emoji_picker.zig", "src/slack_emoji.zig", "src/shortcodes.zig", "src/played.zig", "src/pending_reads.zig", "src/read_state.zig", "src/update.zig", "src/avatar_mask.zig", "src/text_draw.zig", "src/smooth_geometry.zig", "src/smooth_coverage.zig", "src/compose_layout.zig", "src/update_card_layout.zig", "src/field_pill.zig", "src/scrollbar.zig", "src/message_scroll.zig", "src/media_age.zig", "src/media_drain.zig", "src/paste_image.zig", "src/telegram_json.zig", "src/accounts.zig", "src/slack.zig", "src/slack_oauth.zig", "src/message_filter.zig", "src/chat_cache.zig", "src/outbox.zig", "src/slack_send.zig", "src/unfurl.zig", "src/auth_status.zig", "src/messenger_view.zig", "src/shortcuts.zig", "src/sidebar_nav.zig", "src/sync_gate.zig", "src/control.zig", "src/colr.zig", "src/bitmap_lru.zig", "src/format_request.zig", "src/voice_sent.zig", "src/send_args.zig", "src/voice_pos.zig", "src/mic_choice.zig", "src/dictation_policy.zig", "src/deepgram_key.zig", "src/environment_keys.zig", "src/format_cache.zig", "src/image_gallery.zig", "src/video_alias.zig" }) |test_root| {
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
    const message_menu_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/message_menu_test.zig"),
        sourceSection("fn appendMessageMenuItem(", "fn openUrlWide("),
        sourceSection("fn openReactionMenu(", "fn measureReactionRow("),
    }) catch @panic("Out of memory building message menu harness");
    const message_menu_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("message_menu_test.zig", message_menu_source),
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "theme", .module = b.createModule(.{ .root_source_file = b.path("src/theme.zig"), .target = b.resolveTargetQuery(.{}) }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(message_menu_tests).step);
    const transcription_retry_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/transcription_retry_test.zig"),
        sourceSection("fn beginTranscriptionOpen(", "fn appendDebugLog("),
        blk: {
            const source = @embedFile("src/dictation.zig");
            const first = std.mem.indexOf(u8, source, "const Transport = struct {") orelse @panic("Missing transcription transport");
            const rest = source[first..];
            const last = std.mem.indexOf(u8, rest, "fn transcribeAt(") orelse @panic("Missing transcription transport end");
            break :blk rest[0..last];
        },
    }) catch @panic("Out of memory building transcription retry harness");
    const transcription_retry_harness = b.addWriteFiles().add("transcription_retry_test.zig", transcription_retry_source);
    const transcription_retry_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = transcription_retry_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "dictation_policy", .module = b.createModule(.{ .root_source_file = b.path("src/dictation_policy.zig"), .target = b.resolveTargetQuery(.{}) }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(transcription_retry_tests).step);
    const canvas_source = sourceSection("fn canvasProc(", "fn selectChatRow(");
    const canvas_input_start = std.mem.indexOf(u8, canvas_source, "            a.click_origin =") orelse @panic("Missing canvas input start");
    const canvas_input_end = std.mem.indexOf(u8, canvas_source, "        win.WM_RBUTTONUP =>") orelse @panic("Missing canvas input end");
    const double_click_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/message_double_click_test.zig"),
        "fn hubConfigured(_: *const App) bool { return false; }\nfn enqueueHubReaction(_: *App, _: *PendingReaction) void {}\n",
        sourceSection("fn WideText(", "const Chat = struct"),
        sourceSection("const max_pending_reactions =", "const WacliJobKind = enum"),
        sourceSection("fn selectionPoint(", "fn copyPassage("),
        sourceSection("fn hitTestWord(", "fn linkSpanHit("),
        sourceSection("fn handleCanvasDoubleClick(", "fn reactToSelected("),
        sourceSection("fn findPendingReaction(", "fn insertEmoji("),
        "fn foldReactions(a: *App) void {\n",
        sourceSection("    var reaction_index: usize = 0;", "    reapplyPendingReactions(a, chat.jid.slice());"),
        "}\n",
        "fn canvasProc(hwnd: usize, message: u32, wparam: usize, lparam: isize) isize { const a = app_ptr.?; switch (message) {\n",
        canvas_source[std.mem.indexOf(u8, canvas_source, "        win.WM_TIMER =>").?..std.mem.indexOf(u8, canvas_source, "        win.WM_MOUSEWHEEL =>").?],
        "win.WM_LBUTTONDOWN => { const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam))))); const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));\n",
        sourceSection("            for (a.messages[0..a.message_count]) |*item| {", "            for (a.messages[0..a.message_count], 0..) |*item, index| {"),
        canvas_source[canvas_input_start..canvas_input_end],
        "else => return 0, } }\n",
        "fn loadReaction(a: *App, message: *Message, object: std.json.ObjectMap) void { const reaction_to = getString(object, \"ReactionToID\");\n",
        sourceSection("        message.reaction_to.set(reaction_to);", "        message.timestamp.set(getString(object, \"Timestamp\"));"),
        "}\n",
    }) catch @panic("Out of memory building double-click harness");
    const double_click_harness = b.addWriteFiles().add("message_double_click_test.zig", double_click_source);
    const double_click_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = double_click_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "passage", .module = b.createModule(.{ .root_source_file = b.path("src/passage.zig"), .target = b.resolveTargetQuery(.{}) }) },
            .{ .name = "send_args", .module = b.createModule(.{
                .root_source_file = b.path("src/send_args.zig"),
                .target = b.resolveTargetQuery(.{}),
            }) },
            .{ .name = "message_double_click", .module = b.createModule(.{
                .root_source_file = b.path("src/message_double_click.zig"),
                .target = b.resolveTargetQuery(.{}),
            }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(double_click_tests).step);
    const recording_files = b.addWriteFiles();
    _ = recording_files.add("recording_paint.zig", @embedFile("src/recording_paint.zig"));
    const recording_source = std.mem.concat(b.allocator, u8, &.{
        "const recording_paint = @import(\"recording_paint.zig\");\n",
        @embedFile("tools/recording_paint_test.zig"),
        sourceSection("fn drawVoiceButton(", "fn paintVoiceButton("),
        sourceSection("fn invalidateRecordingTick(", "fn queueVoiceNote("),
    }) catch @panic("Out of memory building recording paint harness");
    const recording_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = recording_files.add("recording_test.zig", recording_source),
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "chat_key", .module = b.createModule(.{ .root_source_file = b.path("src/chat_key.zig"), .target = b.resolveTargetQuery(.{}) }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(recording_tests).step);

    const repaint_files = b.addWriteFiles();
    _ = repaint_files.add("compose_layout.zig", @embedFile("src/compose_layout.zig"));
    _ = repaint_files.add("theme.zig", @embedFile("src/theme.zig"));
    const buffer_source = @embedFile("src/paint_buffer.zig");
    const repaint_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("tools/repaint_test.zig"),
        buffer_source[(std.mem.indexOfScalar(u8, buffer_source, '\n') orelse unreachable) + 1 ..],
        sourceSection("fn stagedPreviewColumns(", "fn layout(a:"),
        "fn composeChanged(a: *App) void {\n",
        sourceSection("\n                saveComposerDraft(a);", "            } else if (id == id_search"),
        "}\n",
    }) catch @panic("Out of memory building repaint harness");
    const repaint_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = repaint_files.add("repaint_test.zig", repaint_source),
        .target = b.resolveTargetQuery(.{}),
    }) });
    test_step.dependOn(&b.addRunArtifact(repaint_tests).step);

    const slack_worker_source = @embedFile("src/slack_win.zig");
    const slack_send_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/slack_send_test.zig"),
        sourceSection("const SlackOutbox = struct", "const StagedImage = struct {"),
        sourceSection("const WacliJobKind = enum", "const MsgCacheEntry = struct {"),
        sourceSection("fn wacliJobArgs(", "fn wacliPendingGet("),
        sourceSection("fn enqueueSlackOutbox(", "fn requestSlackDownload("),
        "fn resendSlackBubble(a: *App) bool { const message = &a.messages[0];\n",
        sourceSection("    if (selectedChatIsSlack(a)) {\n        for (a.slack_outbox", "    if (selectedChatIsTelegram(a)) return false;"),
        "return false; }\n",
        slack_worker_source[std.mem.indexOf(u8, slack_worker_source, "fn shareImage(").?..],
    }) catch @panic("Out of memory building Slack send harness");
    const slack_send_harness = b.addWriteFiles().add("slack_send_test.zig", slack_send_source);
    const slack_send_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = slack_send_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "chat_key", .module = b.createModule(.{ .root_source_file = b.path("src/chat_key.zig"), .target = b.resolveTargetQuery(.{}) }) },
            .{ .name = "outbox", .module = b.createModule(.{ .root_source_file = b.path("src/outbox.zig"), .target = b.resolveTargetQuery(.{}) }) },
            .{ .name = "slack_send", .module = b.createModule(.{ .root_source_file = b.path("src/slack_send.zig"), .target = b.resolveTargetQuery(.{}) }) },
            .{ .name = "slack", .module = b.createModule(.{ .root_source_file = b.path("src/slack.zig"), .target = b.resolveTargetQuery(.{}) }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(slack_send_tests).step);

    const read_harness_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/chat_reconcile_test.zig"),
        sourceSection("fn unifiedHub(", "fn hubConfigured("),
        sourceSection("fn applyHubAccounts(", "fn startHubSend("),
        sourceSection("fn hubRefreshMessages(", "fn hubSendText("),
        sourceSection("fn beginTranscriptionOpen(", "fn appendDebugLog("),
        sourceSection("fn refreshMessages(", "fn reconcileOpenChat(a: *App) void {"),
        sourceSection("fn reconcileOpenChat(", "fn youSender("),
        "fn resultFor(job: WacliJob) WacliResult { var storage = WacliResult{}; const result = &storage;\n",
        sourceSection("    result.* = .{ .kind = job.kind", "    switch (job.kind)"),
        "return storage; }\nfn deliverChats(a: *App, result: *const WacliResult) void {\n",
        sourceSection("                    if (!result.ok and result.gen == a.chats_gen) {", "                },\n                .messages =>"),
        "}\nfn deliver(a: *App, result: *WacliResult) void { a.pending -= 1; _ = deliverResult(a, result); }\nfn deliverResult(a: *App, result: *WacliResult) usize {\n",
        sourceSection("            if (result.kind != .cache_tag and result.provider == .whatsapp", "            switch (result.kind) {"),
        sourceSection("                    var kind: []const u8 = \"unknown\";", "                },\n                .background_media =>"),
        "return 0; }\nfn tick(a: *App) void {\n",
        sourceSection("                if (a.msg_read_retry_ticks > 0)", "                if (changed and"),
        "}\n",
        sourceSection("fn applyMessageData(", "    var selected_id = Utf8Text(191){};"),
        "clearMessages(a); a.message_count = list.items.len; a.msg_applied_hash = std.hash.Wyhash.hash(0, raw); a.painted += 1;\n",
        sourceSection("    a.displayed_jid.set(chat.jid.slice());\n    a.displayed_account = chat.account;\n    a.displayed_provider = chat.provider;\n    if (fresh_read) a.displayed_timestamp.set(chat.timestamp.slice());", "    for (a.pending_sends[0..a.pending_send_count]) |*pending| {"),
        "return true; }\n",
    }) catch @panic("Out of memory building read harness");
    const read_files = b.addWriteFiles();
    _ = read_files.addCopyFile(b.path("src/wa_hub.zig"), "wa_hub.zig");
    _ = read_files.addCopyFile(b.path("src/transport.zig"), "transport.zig");
    _ = read_files.addCopyFile(b.path("src/chat_key.zig"), "chat_key.zig");
    const read_harness = read_files.add("chat_reconcile_test.zig", read_harness_source);
    const read_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = read_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{ .{ .name = "chat_key", .module = b.createModule(.{ .root_source_file = b.path("src/chat_key.zig"), .target = b.resolveTargetQuery(.{}) }) }, .{ .name = "chat_reconcile", .module = b.createModule(.{
            .root_source_file = b.path("src/chat_reconcile.zig"),
            .target = b.resolveTargetQuery(.{}),
        }) } },
    }) });
    test_step.dependOn(&b.addRunArtifact(read_tests).step);

    const format_harness_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/format_pipeline_test.zig"),
        sourceSection("fn WideText(", "fn Utf8Text("),
        sourceSection("fn loadTranscriptCache(", "fn readFileWin("),
        sourceSection("fn pollFormatting(", "fn cycleSpeed("),
    }) catch @panic("Out of memory building format harness");
    const format_harness = b.addWriteFiles().add("format_pipeline_test.zig", format_harness_source);
    const format_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = format_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "format_cache", .module = b.createModule(.{ .root_source_file = b.path("src/format_cache.zig"), .target = b.resolveTargetQuery(.{}) }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(format_tests).step);

    const control_archive_source = sourceSection("fn controlWhatsAppChats(", "fn controlSortChats(");
    const control_archive_filter = control_archive_source[std.mem.indexOf(u8, control_archive_source, "        chat.archived =").?..std.mem.indexOf(u8, control_archive_source, "        try list.append").?];
    const archive_filter_source = @embedFile("src/messenger_view.zig");
    const archive_harness_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/archive_actions_test.zig"),
        "const messenger_view = struct {\n",
        archive_filter_source[std.mem.indexOf(u8, archive_filter_source, "pub fn archiveMatches(").?..std.mem.indexOf(u8, archive_filter_source, "pub fn mergeChatData(").?],
        "};\n",
        sourceSection("fn getBool(", "fn getInt("),
        "fn archiveInboxRow(a: *App, row: Chat, object: std.json.ObjectMap) ?Chat { for ([_]Chat{row}) |item| { var chat = item;\n",
        sourceSection("        chat.archived =", "        a.chats[a.chat_count] = chat;"),
        "return chat; } return null; }\n",
        "fn archiveControlRow(a: *App, row: Chat, object: std.json.ObjectMap) ?Chat { const show_archived = a.show_archived; for ([_]Chat{row}) |item| { var chat = item;\n",
        control_archive_filter,
        "return chat; } return null; }\n",
        "fn unifiedHub(a: *const App) bool { return a.unified_hub; }\n",
        "fn hubConfigured(a: *const App) bool { return a.unified_hub; }\n",
        "fn applyHubArchiveResult(a: *App, result: *const WacliResult) void { switch (result.kind) {\n",
        sourceSection("        .hub_archive => {\n", "        .hub_media => {\n"),
        "else => {}, } }\n",
        sourceSection("fn retryUnarchiveChat(", "fn startNextArchive("),
        sourceSection("fn queueUnarchiveChat(", "const archived_scan_min_ticks"),
        sourceSection("fn archiveChat(", "fn paneFollowSelection(a: *App, open_jid: []const u8) void {"),
        if (std.mem.indexOf(u8, @embedFile("src/main.zig"), "fn archiveShortcutAllowed(") != null)
            sourceSection("fn archiveShortcutAllowed(", "fn archiveSelectedChat(")
        else
            "",
        sourceSection("fn archiveSelectedChat(", "const control_call_posted: u8 = 0;"),
        sourceSection("fn startNextArchive(", "fn checkArchive("),
        "fn completePendingSend(_: *App, _: bool) bool { return true; }\n",
        sourceSection("fn removeFirstPendingSend(", "fn playableVideoPath("),
        sourceSection("fn buildPaletteItems(", "    a.palette_item_count = 0;"),
        "std.mem.doNotOptimizeAway(a); }\nfn activateArchivePalette(a: *App, item: struct { command: u16 }) void {\n",
        sourceSection("    const command = item.command;\n    closePalette(a);", "fn openPalette("),
        "fn archiveKey(a: *App, key: u32, control: bool, alt: bool, shift: bool, focus: ?win.HWND, message: *const win.MSG) bool {\nstd.mem.doNotOptimizeAway(focus); std.mem.doNotOptimizeAway(message);\n",
        sourceSection("    if (control and !alt and key == 'E') {", "    if (control and shift and key == 'C') {"),
        sourceSection("    if (key == 'E') {", "    if (key == 'U') {"),
        "return false; }\n",
    }) catch @panic("Out of memory building archive harness");
    const archive_harness = b.addWriteFiles().add("archive_actions_test.zig", archive_harness_source);
    const archive_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = archive_harness,
        .target = b.resolveTargetQuery(.{}),
        .imports = &.{
            .{ .name = "chat_key", .module = b.createModule(.{ .root_source_file = b.path("src/chat_key.zig"), .target = b.resolveTargetQuery(.{}) }) },
            .{ .name = "archive_rules", .module = b.createModule(.{
                .root_source_file = b.path("src/archive_rules.zig"),
                .target = b.resolveTargetQuery(.{}),
            }) },
            .{ .name = "voice_sent", .module = b.createModule(.{
                .root_source_file = b.path("src/voice_sent.zig"),
                .target = b.resolveTargetQuery(.{}),
            }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(archive_tests).step);

    const read_state_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/read_state_test.zig"),
        "fn unifiedHub(_: *const App) bool { return false; }\n",
        "fn hubConfigured(_: *const App) bool { return false; }\nfn startHubMarkRead(_: *App) void {}\n",
        sourceSection("fn invalidateChatRow(", "fn persistReadState("),
        sourceSection("fn queueUnreadProbe(", "fn tgChatIdString(buffer: *[24]u8, chat_id: i64) []const u8 {"),
        sourceSection("fn markChatRead(a: *App) void {", "    if (!unifiedHub(a) and chat.provider == .telegram)"),
        sourceSection("    const needs_receipt = chat.provider_unread", "const slack_mark_debounce_ms: u32 = 750;"),
        sourceSection("fn startNextMarkRead(a: *App) void {", "const mark_read_hung_child_timeout_ms: u64 = 90_000;"),
    }) catch @panic("Out of memory building read state harness");
    const read_state_files = b.addWriteFiles();
    _ = read_state_files.addCopyFile(b.path("src/chat_key.zig"), "chat_key.zig");
    _ = read_state_files.addCopyFile(b.path("src/transport.zig"), "transport.zig");
    _ = read_state_files.addCopyFile(b.path("src/read_state.zig"), "read_state.zig");
    _ = read_state_files.addCopyFile(b.path("src/media_age.zig"), "media_age.zig");
    const read_state_harness = read_state_files.add("read_state_test.zig", read_state_source);
    const read_state_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = read_state_harness,
        .target = b.resolveTargetQuery(.{}),
    }) });
    test_step.dependOn(&b.addRunArtifact(read_state_tests).step);

    const media_failure_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/media_failure_test.zig"),
        "fn unifiedHub(_: *const App) bool { return false; }\n",
        sourceSection("fn Utf8Text(", "const Chat = struct"),
        sourceSection("const MediaFailure = struct", "fn mediaBusy("),
        "const App = struct {\n",
        sourceSection("    media_attempts: [512]u64", "    media_burst_started_ms:"),
        sourceSection("    media_failures: [16]MediaFailure", "    avatar_session:"),
        "displayed_provider: @TypeOf((Chat{}).provider) = .whatsapp, displayed_account: Utf8Text(32) = .{}, chats: [1]Chat = .{.{}}, chat_count: usize = 1, selected_chat: usize = 0, displayed_jid: Utf8Text(191) = .{}, messages: [1]Message = .{.{}}, message_count: usize = 1, send_child: ?u8 = null, pending_send_count: usize = 0, read_child: ?u8 = null, archive_child: ?u8 = null, pending_download_jid: Utf8Text(191) = .{}, pending_download_id: Utf8Text(191) = .{}, hwnd: ?usize = null, started: usize = 0 };\n",
        sourceSection("fn downloadMedia(", "fn isDownloadableMedia("),
        "fn attachmentState(a: *const App, message: *const Message, local: bool) media_drain.AttachmentState {\n",
        sourceSection("            const attachment_state: media_drain.AttachmentState", "            const label = media_drain.attachmentLabel"),
        "return attachment_state; }\n",
    }) catch @panic("Out of memory building media failure harness");
    const media_failure_files = b.addWriteFiles();
    for ([_][]const u8{ "media_drain.zig", "media_age.zig", "sync_gate.zig", "played.zig", "chat_cache.zig", "chat_key.zig", "transport.zig" }) |name| {
        _ = media_failure_files.addCopyFile(b.path(b.fmt("src/{s}", .{name})), name);
    }
    const media_failure_harness = media_failure_files.add("media_failure_test.zig", media_failure_source);
    const media_failure_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = media_failure_harness,
        .target = b.resolveTargetQuery(.{}),
    }) });
    test_step.dependOn(&b.addRunArtifact(media_failure_tests).step);

    const background_media_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/background_media_test.zig"),
        sourceSection("fn Utf8Text(", "const Chat = struct"),
        sourceSection("const WacliJobKind = enum", "const MsgCacheEntry = struct {"),
        sourceSection("const background_media_limit =", "fn mediaBusy("),
        sourceSection("fn mediaAttempted(", "fn isDownloadableMedia("),
        sourceSection("fn wacliJobArgs(", "fn wacliPendingGet("),
        sourceSection("fn observeBackgroundMediaChats(", "fn ensureAvatarSession("),
        sourceSection("const MediaDownload = struct", "const background_media_limit ="),
        "fn finishHubMedia(a: *App, result: *const WacliResult) void { switch (result.kind) {\n",
        sourceSection("        .hub_media => {\n            for (&a.media_downloads)", "        .hub_avatar => {\n            if (a.avatar_active_index)"),
        "else => unreachable, } }\n",
    }) catch @panic("Out of memory building background media harness");
    const background_media_files = b.addWriteFiles();
    for ([_][]const u8{ "media_drain.zig", "media_age.zig", "sync_gate.zig", "played.zig", "chat_cache.zig", "chat_key.zig", "transport.zig" }) |name| {
        _ = background_media_files.addCopyFile(b.path(b.fmt("src/{s}", .{name})), name);
    }
    const background_media_harness = background_media_files.add("background_media_test.zig", background_media_source);
    const background_media_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = background_media_harness,
        .target = b.resolveTargetQuery(.{}),
    }) });
    test_step.dependOn(&b.addRunArtifact(background_media_tests).step);

    const composer_button_files = b.addWriteFiles();
    _ = composer_button_files.addCopyFile(b.path("src/main.zig"), "main-source.zig");
    _ = composer_button_files.addCopyFile(b.path("src/theme.zig"), "theme.zig");
    _ = composer_button_files.addCopyFile(b.path("src/compose_layout.zig"), "compose_layout.zig");
    const composer_paint_source = sourceSection("fn drawComposerButton(", "fn drawSetupButton(");
    const composer_paint_start = std.mem.indexOf(u8, composer_paint_source, "    var shapes =") orelse @panic("Missing composer painting body");
    const composer_layout_source = sourceSection("fn layoutRegion(", "    const header_height:");
    const composer_layout_start = std.mem.indexOf(u8, composer_layout_source, "    const left_width =") orelse @panic("Missing composer layout body");
    const composer_button_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/composer_button_test.zig"),
        sourceSection("fn drawDictationIcon(", "fn drawComposerButton("),
        "fn drawComposerButton(a: *App, item: *win.DRAWITEMSTRUCT) void {\n",
        composer_paint_source[composer_paint_start..],
        "fn layoutComposer(a: *App, width: i32, height: i32) void {\n",
        composer_layout_source[composer_layout_start..],
        "    const sizes = .{ .edit_height = px(a, 44) };\n",
        sourceSection("            a.compose_geometry =", "            const inner = a.compose_geometry.text;"),
        sourceSection("    const buttons = [_]?win.HWND", "    updateAttachButton(a);"),
        "}\n",
    }) catch @panic("Out of memory building composer button harness");
    const composer_button_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = composer_button_files.add("composer_button_test.zig", composer_button_source),
        .target = b.resolveTargetQuery(.{}),
    }) });
    test_step.dependOn(&b.addRunArtifact(composer_button_tests).step);

    const drafts_ui_source = std.mem.concat(b.allocator, u8, &.{
        @embedFile("src/drafts_ui_test.zig"),
        sourceSection("fn visibleChatIndex(", "fn chatProvider("),
        sourceSection("fn composerText(", "fn ensureDictation("),
        sourceSection("fn updateDictation(", "fn selectChat("),
    }) catch @panic("Out of memory building drafts UI harness");
    const drafts_ui_files = b.addWriteFiles();
    for ([_][]const u8{ "drafts.zig", "chat_key.zig", "transport.zig", "theme.zig", "edit_contract.zig" }) |name| {
        _ = drafts_ui_files.addCopyFile(b.path(b.fmt("src/{s}", .{name})), name);
    }
    const drafts_ui_harness = drafts_ui_files.add("drafts_ui_test.zig", drafts_ui_source);
    const drafts_ui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = drafts_ui_harness,
        .target = b.resolveTargetQuery(.{}),
    }) });
    test_step.dependOn(&b.addRunArtifact(drafts_ui_tests).step);

    const webp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/webp.zig"),
            .target = b.resolveTargetQuery(.{}),
        }),
    });
    const run_webp_tests = b.addRunArtifact(webp_tests);
    test_step.dependOn(&run_webp_tests.step);

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
