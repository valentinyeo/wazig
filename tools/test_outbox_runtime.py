#!/usr/bin/env python3
"""Run main.zig's outbox lifecycle with fake Win32 I/O, without a Windows host.

The fixture supplies only platform/UI boundaries. Production function bodies
are extracted verbatim, except startNextSend stops before spawning the child.
--negative-controls reintroduces each reviewed defect and requires a failing
assertion, not a compilation failure. No provider or user data is accessed.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FUNCTIONS = (
    "persistOutbox", "loadOutbox", "enqueueSlackOutbox", "retrySlackOutbox",
    "retireSlackOutbox", "removeFirstPendingSend", "sendMessage",
    "resolveSlackSend", "pendingByClientMsgId", "jobIsWrite", "jobIsSlack",
    "wacliEnqueue", "wacliTakeJob", "wacliJobArgs", "startNextSend", "retryWacliRefreshes", "appendWhatsAppPending", "retryingBubbleText", "localSendId",
)


def extract(source, name):
    # Top-level closing braces have no indentation in this project's Zig style.
    start = source.index(f"fn {name}(")
    end = source.index("\n}\n", start) + 3
    body = source[start:end]
    if name == "startNextSend":
        body = body[:body.index("    const pending = &a.pending_sends[0];")] + "    spawned += 1;\n}\n"
    return body


def mutate(source, name):
    if name in ("short-job-args", "nul-field", "negative-time", "evict-write"):
        return source
    replacements = {
        "ignored-swap": ("return win.MoveFileExW(wide.ptr, target.ptr, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH) != 0;", "_ = win.MoveFileExW(wide.ptr, target.ptr, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH); return true;"),
        "unflushed-write": ("win.FlushFileBuffers(handle) != 0", "true"),
        "local-zero": ("a.send_seq += 1;\n            pending.seq = a.send_seq;", "pending.seq = 0;"),
        "no-credentials": ("or !slackConfigured(a) ", ""),
        "wrong-retirement": ("if (!std.mem.eql(u8, slot.entry.idSlice(), id)) continue;", "_ = id;"),
        "wrong-failed-bubble": ("const index = pendingByClientMsgId(a, client_msg_id) orelse return;", "const index = if (!result.ok) oldestPendingSend(a) orelse return else pendingByClientMsgId(a, client_msg_id) orelse return;"),
        "slack-paste-to-whatsapp": ("staged_file.len > 0 and !selectedChatIsSlack(a)", "staged_file.len > 0"),
        "same-text-reload": ("if (head.retries > 0 and head.ambiguous and", "if ((head.retries > 0 and head.ambiguous or head.retries == 0) and"),
        "delete-before-retirement": ("if (!persistOutbox(a)) {\n        setStatus(a, \"Could not save send completion; retrying journal\");\n        return;\n    }", "_ = persistOutbox(a);"),
        "silent-admission": ("if (!persistOutbox(a)) {\n        a.pending_send_count -= 1;\n        pending.* = .{};\n        setStatus(a, \"Could not save outbox; message not queued\");\n        return;\n    }", "_ = persistOutbox(a);"),
        "utf8-truncation": ("if (text.len > outbox.max_text_len)", "if (false)"),
        "hidden-restored-bubble": ("if (from_reload and !pending.from_disk)", "if (from_reload)"),
        "lost-refresh": ("if (!jobIsWrite(job.kind)) a.wacli_refresh_again = true;", ""),
        "partial-load": ("if (win.ReadFile(handle, buffer[total..].ptr, @intCast(buffer.len - total), &got, null) == 0) return;", "if (win.ReadFile(handle, buffer[total..].ptr, @intCast(buffer.len - total), &got, null) == 0) break;"),
    }
    if name == "overtake-refused":
        old = re.search(r"    for \(a.slack_outbox\[0\.\.a.slack_outbox_count\]\) \|\*earlier\| \{.*?\n    }", source, re.S).group()
        return source.replace(old, "", 1)
    old, new = replacements[name]
    assert old in source, name
    return source.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", required=True)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    source = (ROOT / "src/main.zig").read_text()
    bodies = "\n\n".join(extract(source, name) for name in FUNCTIONS)
    fixture = (ROOT / "tools/outbox_runtime_test.zig").read_text()
    for name in ("max_pending_sends", "max_slack_outbox", "max_wacli_args", "wacli_arg_cap", "wacli_queue_size"):
        declaration = re.search(rf"^const {name} = .*?;", source, re.M).group()
        fixture = re.sub(rf"^const {name} = .*?;", lambda _: declaration, fixture, flags=re.M)
    for name in ("PendingSend", "SlackOutbox", "WacliJob", "WacliResult"):
        pattern = rf"^const {name} = struct \{{.*?^}};"
        declaration = re.search(pattern, source, re.M | re.S).group()
        fixture = re.sub(pattern, lambda _: declaration, fixture, flags=re.M | re.S)
    mutants = [None]
    if args.negative_controls:
        mutants += ["ignored-swap", "unflushed-write", "local-zero", "no-credentials",
                    "wrong-retirement", "wrong-failed-bubble", "slack-paste-to-whatsapp",
                    "same-text-reload", "delete-before-retirement", "silent-admission",
                    "utf8-truncation", "partial-load", "overtake-refused", "short-job-args",
                    "nul-field", "negative-time", "lost-refresh", "evict-write", "hidden-restored-bubble"]
    (ROOT / ".zig-cache").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="outbox-runtime-", dir=ROOT / ".zig-cache") as directory:
        directory = Path(directory)
        format_source = (ROOT / "src/outbox.zig").read_text()
        for mutant in mutants:
            effective_format = format_source
            if mutant == "nul-field":
                effective_format = effective_format.replace("if (std.mem.indexOfScalar(u8, field, 0) != null) return false;", "_ = field;")
            if mutant == "evict-write":
                effective_format = effective_format.replace("if (!keep[index]) return index;", "_ = keep[index]; return index;")
            if mutant == "negative-time":
                effective_format = effective_format.replace("if (value.queued_unix < 0) return false;", "")
            (directory / "outbox.zig").write_text(effective_format)
            production = bodies if mutant is None else mutate(bodies, mutant)
            effective_fixture = fixture.replace("const wacli_arg_cap = 4095;", "const wacli_arg_cap = 512;") if mutant == "short-job-args" else fixture
            (directory / "test.zig").write_text(effective_fixture + "\n" + production)
            run = subprocess.run([args.zig, "test", str(directory / "test.zig")], cwd=ROOT,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if mutant is None:
                print(run.stdout, end="")
                if run.returncode:
                    raise SystemExit(run.returncode)
            else:
                if run.returncode == 0 or "FAIL (Test" not in run.stdout:
                    print(run.stdout, end="")
                    raise SystemExit(f"Negative control {mutant} did not fail a runtime assertion")
                failures = [line for line in run.stdout.splitlines() if "FAIL (Test" in line]
                print(f"NEGATIVE CONTROL {mutant}: " + "; ".join(failures))
    print("OUTBOX_RUNTIME_VERIFIED")


if __name__ == "__main__":
    main()
