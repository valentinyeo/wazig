import ast
import importlib.util
import hashlib
import io
import json
import threading
from pathlib import Path
import re
import sys
from types import SimpleNamespace

root = Path(__file__).resolve().parents[2]

OLD_SOURCE_ACCOUNT = '''pub fn sourceAccount(row: std.json.ObjectMap, fallback: []const u8) []const u8 {
    const account = string(row, "account");
    return if (account.len > 0) account else fallback;
}

'''


def read(path):
    return (root / path).read_text(encoding='utf-8')


def require(text, fragments):
    for fragment in fragments:
        assert fragment in text, fragment


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


def view_identity(source):
    require(source, [
        'pub fn viewAccount(', 'if (account.len > 0) return account;',
        'std.mem.indexOfScalar(u8, jid,', "jid[colon + 1 ..], '@'", 'return jid[0..colon]',
        'std.mem.startsWith(u8, jid, "slack:")', 'return rest[0..colon]',
    ])


def model(source):
    require(source, [
        'pub const Account = struct', 'key: chat_key.Stored', 'pub fn mergeOrder(',
        'for ([_]Provider{ .whatsapp, .slack, .telegram, .signal })', 'try appendUnique(allocator, &result, item)',
        'pub fn forNumber(number: usize, views: []const Account)', 'number - 1',
        'pub fn accountMatches(', 'key.account', 'pub fn saveOrder(',
        'if (present)', 'views[next].key.key()', 'views[next..]',
        'pub fn inboxMoveUp(', 'by_time == .lt',
        'test "account view order merges saved missing and new accounts without losing absent entries"',
        'test "Alt+N maps saved account positions including two WhatsApp accounts"',
        'test "combined inbox sorts activity across accounts without prioritizing old pins"',
        'test "two WhatsApp account views isolate a shared contact in projection search selection and sending"',
        'try std.testing.expectEqualStrings("wa-b", merged.items[3].key.key().account)',
        'try std.testing.expect(!rows[0].pinned)', 'chat_key.indexOf(Row, &output, key)',
        'try std.testing.expectEqual(@as(usize, 2), count)',
    ])


def check_model():
    source = read('src/messenger_view.zig')
    model(source)
    hub = read('src/hub.zig')
    view_identity(hub)
    old = OLD_SOURCE_ACCOUNT
    try:
        view_identity(old)
    except AssertionError:
        pass
    else:
        raise AssertionError('cache-account-only negative control unexpectedly accepted')
    assert section(hub, 'pub fn sourceAccount(', 'pub fn viewAccount(') == section(old, 'pub fn sourceAccount(', 'pub fn providerForView(')
    regression = read('src/hub_test.zig')
    require(regression, [
        'test "real hub prefixed jids without account produce four views without changing routing identity"',
        'test "hub view accounts prefer explicit accounts and safely fall back for unprefixed handles"',
        'personal:0000000000@s.whatsapp.net', 'business:0000000000@s.whatsapp.net',
        'slack:T0ABC123:C0000000000', 'slack:T0DEF456:C0000000000',
        'hub.viewAccount(row.object, "hub-cache")', 'try std.testing.expectEqual(@as(usize, 4), known.items.len)',
        'try std.testing.expectEqual(@as(usize, 1), count)',
        'try std.testing.expect(!chat_key.Key.eql(routing[0].key(), routing[1].key()))',
        'try std.testing.expectEqualStrings("hub-cache", routing[index].key().account)',
        'body.value.object.get("account") == null',
    ])
    for token in ['pub fn mergeOrder(', 'pub fn accountMatches(', 'pub fn inboxMoveUp(', 'pub fn forNumber(']:
        try:
            model(source.replace(token, 'removed-function(', 1))
        except AssertionError:
            pass
        else:
            raise AssertionError(f'model mutation accepted: {token}')
    main = read('src/main.zig')
    require(main, ['messenger_view.mergeOrder(a.allocator, a.view_order, known.items)',
                   'messenger_view.forNumber(key - \'0\', a.views.items)',
                   'messenger_view.inboxMoveUp(by_time, jid_order)',
                   'if (!chatInView(a, chat_key.of(cached))) continue;',
                   'if (!chatInView(a, chatViewKey(&chat))) continue;'])
    require(read('src/outbox.zig'), ['if (!source_unified or !target.unified) entry.account.set(target.account)',
                                    'test "unified outbox adoption preserves the source account for shared-contact sends"'])
    require(read('src/chat_reconcile_test.zig'), ['test "account view history accepts source accounts without confusing the hub cache namespace"'])
    require(read('src/hub_test.zig'), ['test "hub source accounts retain per-account view labels independently of cache namespace"'])
    require(read('build.zig'), ['"src/messenger_view.zig"', '"src/control.zig"', '"src/outbox.zig"', '"src/hub_test.zig"'])


def check_integration():
    source = read('src/main.zig')
    require(source, [
        'loadRegistryString(init.gpa, lit("ViewOrder"))', 'saveRegistryString(a.allocator, lit("ViewOrder"), text)',
        'loadRegistryString(init.gpa, lit("AccountView"))', 'saveRegistryString(a.allocator, lit("AccountView"), a.view_account.slice())',
        'hub.sourceAccount(object, a.cache_tag.slice())',
        'chat.view_account.set(hub.viewAccount(object, a.cache_tag.slice()))',
        'if (!messenger_view.accountMatches(view, account, chatViewKey(&chat))) continue;',
        'hub.viewAccount(row.object, a.cache_tag.slice())',
        'view_account: Utf8Text(32) = .{}', 'fn chatViewKey(chat: *const Chat) chat_key.Key',
        'if (chat.view_account.len > 0) key.account = chat.view_account.slice()',
        'slack_win.loadInstallation(a.allocator, account)', 'parsed.value.team_name',
        'messenger_view.providerView(chat.provider), chatViewKey(chat).account, view.key.key()',
        'installation.team_id.slice(), installation.team_name.slice()', 'telegramReady(a)',
        'appendPalette(a, "Sort views", "", command_sort_views)', 'command_sort_views => openSortViews(a)',
        'a.palette_views_mode and control and !alt and !shift', 'moveView(a, key == win.VK_DOWN)',
        'if (!saveViewOrder(a))', 'fn buildSortViewsItems(', 'item.view_identity.account_len > 0',
        'switchAccountView(a, wanted.key())', 'appendPalette(a, "Show combined inbox", "Alt+I", command_show_all)',
        'key == \'I\'', '"Show {s}"', 'activeViewLabel(a)', 'fn updateChatTooltip(',
        'win.TTM_UPDATETIPTEXTW', 'message.hwnd == app.chats_hwnd.?',
        '\\"current_view\\"', '\\"view_order\\"', '\\"provider\\"', '\\"account\\"', '\\"label\\"', '\\"inbox\\"',
        'chat_key.Key.eql(chat_key.of(chat), item.chat_identity.key())',
        '.provider = pending.provider, .account = pending.account, .jid = pending.jid',
        '(!unifiedHub(a) and !std.mem.eql(u8, head.account.slice(), a.cache_tag.slice()))',
        'if (result.kind != .cache_tag and result.provider == .whatsapp',
        'a.view_selected[@intFromEnum(messenger_view.View.all)] = wanted',
    ])
    links = source.split('fn buildLinkPaletteItems(', 1)[1].split('fn whatsappStorePresent(', 1)[0]
    assert links.count('item.view_identity = .{};') == 2
    assert source.count('chat.account.set(hub.sourceAccount(object, a.cache_tag.slice()));') == 2
    assert source.count('chat.view_account.set(hub.viewAccount(object, a.cache_tag.slice()));') == 2
    assert source.count('hub.viewAccount(') == 6
    assert source.count('.view_account = hub.viewAccount(object, "")') == 1
    assert source.count('.account = hub.sourceAccount(object, "")') == 1
    routing_function_sha256 = {
        'unifiedHubRequest': '0f3c0953dc5314dc815cfb390dd28e68e6d3e75cc295f2c5f22019056f0d4058',
        'restoreOutbox': '97c3d2512d210e72021031071928cc33ccbf4e3038f427ba57a51fce5bcf3f98',
        'loadOutbox': '040428fa42997f7006f87154b7713db94102b863d4536fa853496fc8c4103f0b',
        'bindOutboxAccount': 'c18bfcb6097cec448f946232c1cc8a5a1d92055cfc533e855132e64ea2412b6b',
        'startHubSend': '6e4246a0416884bd87273a0e16e9a3ea09f5624ee705592b24dcd2c260074f61',
        'markChatRead': '5676c98f78dfe3942babf4b8c1f510f3cacd32a975ffb85403bf1ba58d9b3545',
        'startNextMarkRead': '159224436c04c9369adec4daee7cd3379ceee2554330e8db74b7816423651de1',
        'loadPendingReads': 'f24e69e81447328bbb7a6349acade9df6a256cd8374df178570f39bcaef30799',
        'persistPendingReads': '695d922f67253237c5b26207d3f37f19d7274a5a99a33e7e91c612e4f230351e',
        'msgCacheGet': '35de7a11c5298f2b4f7954cda6b73e8b4bb9d54a82e4053b32cc8f4745ac593e',
        'loadMsgCacheDisk': 'd86c62bd4d9c3a242afcd9aeaa3b757af3e09c54fe288a2e73e19dbf31654a19',
        'archiveChat': 'afde1be37fffc35efa3140e04944c737cd1aee6a2e88f277134407ae60bfc56a',
        'startNextArchive': 'c346ccb3d69e3fb5a16f6216f91f8e2390aac40164187b77be632a329df1f67d',
    }
    for name, expected in routing_function_sha256.items():
        current = re.search(rf'^fn {name}\([^\n]*\n.*?^}}', source, re.M | re.S)
        assert current, f'missing identity audit function: {name}'
        assert hashlib.sha256(current.group().encode()).hexdigest() == expected, f'routing identity path changed: {name}'
    routing_file_sha256 = {
        'src/outbox.zig': '4e39faf317e342d24ff3ff38b997df2e1b7b3ffdf89b968af8d7c2df94908f6f',
        'src/chat_cache.zig': 'fe97020e73578d02e52daf25961b65a2151c38b67bbfaa0942e459df05732013',
        'src/read_state.zig': 'c40146cd2dc3ab78a3ad91e5b868a2edf1ae0da2e277eceb5328663af1f13f07',
        'src/pending_reads.zig': 'bac1f5848428e4e9fdc00033eb94386fcce945aa759aef0d8576b2a00df98f4f',
    }
    for path, expected in routing_file_sha256.items():
        assert hashlib.sha256(read(path).encode()).hexdigest() == expected, f'routing identity file changed: {path}'
    control = read('src/control.zig')
    require(control, ['view_number: ?usize', 'std.mem.eql(u8, items[0], "inbox")', 'std.fmt.parseInt(usize, items[0], 10)',
                      'test "view accepts an account position and combined inbox while retaining provider aliases"'])
    markers = re.findall(r'sourceSection\("((?:\\.|[^"\\])*)", "((?:\\.|[^"\\])*)"\)', read('build.zig'))
    assert markers
    for start, end in markers:
        first = ast.literal_eval('"' + start + '"')
        last = ast.literal_eval('"' + end + '"')
        assert first in source, f'missing harness start: {first}'
        assert last in source[source.index(first) + len(first):], f'missing harness end: {last}'
    require(read('src/shortcuts.zig'), ['Alt+I / Alt+1..9'])


def check_journey():
    runner = read('tools/verify-wazig/run.ps1')
    journeys = json.loads(read('tools/verify-wazig/journeys.json'))['journeys']
    entry = next(row for row in journeys if row['name'] == 'views')
    assert entry['hub'] == 'views' and entry['chats'] == 8 and entry['pr'] and entry['evidence']
    require(runner, ['journeys.json', '-Mode $journey.hub', '. (Join-Path $PSScriptRoot $journey.script)'])
    require(read('tools/verify-wazig/' + entry['script']), ['. "$PSScriptRoot/views.ps1"', 'Invoke-ViewsJourney $session $messages $start'])
    journey = read('tools/verify-wazig/views.ps1')
    require(journey, ['Assert-AccountView', "@('personal', 'business', 'T0ABC123', 'T0DEF456')", 'Where-Object view_account -ne $Account',
                      "Send-Keys $Session '^1'", "Send-Keys $Session '^2'", "Send-Keys $Session '^{TAB}'", "Send-Keys $Session '^+{TAB}'",
                      "Send-Keys $Session '^f'", "Send-Keys $Session '%i'", "Send-Keys $Session '^{DOWN}'",
                      "'Sort views'", "'ViewOrder not saved at move time'", "'Quit Messages'",
                      "WAZIG_VERIFY_RESTART", "'restart.json'", 'restart-4', 'other.messages.json', 'inbox.chats.json'])
    require(journey, ['view_order.Count -eq 6', "(Read-ListCount $list) -eq 6"])
    assert set(re.findall(r'Read-Control \$Session (\w+)', journey)) == {'status', 'chats', 'messages'}
    fixture = ast.parse(read('tools/verify-wazig/fake-hub.py'))
    assignment = next(node for node in fixture.body if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'VIEW_ACCOUNTS' for target in node.targets))
    accounts = ast.literal_eval(assignment.value)
    assert [provider for provider, _, _ in accounts].count('whatsapp') == 2
    assert [provider for provider, _, _ in accounts].count('slack') == 2
    assert len({account for _, account, _ in accounts}) == 4
    require(read('tools/verify-wazig/fake-hub.py'), ['Verification Shared', 'range(2)', 'source_account=view_account(row)',
                                                  'class ViewsHandler(Handler)', 'bridge.Handler.respond(self', "modes.add_argument('--' + mode"])
    evidence = read('tools/verify-wazig/check-views-evidence.py')
    require(evidence, ['assert partition == all_keys', 'assert identities(inbox) == all_keys', 'reverse=True',
                       'source_account', "other['messages']", "restart['new_pid'] == session['pid']", "['root', 'id', 'sha256']",
                       "capture(f'restart-{number}')", "'view-order.txt'", "assert len(set(images)) == 4"])
    require(evidence, ["== expected + [('telegram', 'telegram', 'Telegram'), ('signal', 'signal', 'Signal')]",
                       "== order + [('telegram', 'telegram', 'Telegram'), ('signal', 'signal', 'Signal')]", "+ ['telegram:telegram', 'signal:signal']"])
    require(read('tools/verify-wazig/check-evidence.py'), ["row['name'] == session['feature']", "journey['validator']"])
    require(read('tools/verify-wazig/' + entry['validator']['file']), ['check-views-evidence.py'])
    workflow = read('.github/workflows/verify.yml')
    require(workflow, ['fromJSON(needs.plan.outputs.matrix)', 'if: matrix.evidence',
                       'src/messenger_view.zig', 'src/chat_key.zig', 'src/control.zig', 'src/outbox.zig'])
    for path in (root / 'tools/verify-wazig').glob('*.py'):
        ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
    require(read('.claude/skills/verify-wazig/features/views.md'), [
        'personal and business', 'T0ABC123 and T0DEF456', 'Rows omit account and account_name',
        'Chat.view_account', 'Chat.account', 'locally saved workspace name',
        'source_account personal', 'in business', 'descending activity timestamps',
        'restart-1.png through restart-4.png',
    ])
    require(read('CHANGELOG.md'), ['IGSH-602:', 'Sort views', 'Alt+I combined inbox',
                                 'real hub prefixed chat IDs', 'preserving send and cache identities'])


def check_fixture():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('views_fixture', root / 'tools/verify-wazig/fake-hub.py')
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    rows = fixture.view_rows()
    assert len(rows) == 8
    assert all('account' not in row and 'account_name' not in row for row in rows)
    accounts = {(row['provider'], fixture.view_account(row)) for row in rows}
    assert accounts == {('whatsapp', 'personal'), ('whatsapp', 'business'), ('slack', 'T0ABC123'), ('slack', 'T0DEF456')}
    wa = [row for row in rows if row['provider'] == 'whatsapp']
    assert len({row['jid'].split(':', 1)[1] for row in wa}) == 2
    assert all('@s.whatsapp.net' in row['jid'] for row in wa)
    assert all(row['jid'].startswith('slack:T') and ':C' in row['jid'] for row in rows if row['provider'] == 'slack')
    state = SimpleNamespace(view_rows=rows, sends={}, lock=threading.Condition(), stamp='2026-01-02T00:00:00Z')
    handler = object.__new__(fixture.ViewsHandler)
    handler.server = SimpleNamespace(state=state)
    handler.authorized = lambda: True
    responses = []
    handler.respond = lambda status, data, **extra: responses.append((status, data, extra))
    handler.path = '/v1/wazig/chats'
    handler.do_GET()
    assert responses[-1][0] == 200 and responses[-1][1] == rows
    for index, row in enumerate(rows):
        body = dict(chat=row['jid'], text='Synthetic send', reply_to='', client_id=f'client-{index}')
        handler.path = '/v1/wazig/send'
        encoded = json.dumps(body).encode()
        handler.headers = {'Content-Length': str(len(encoded))}
        handler.rfile = io.BytesIO(encoded)
        handler.do_POST()
        status, reply, extra = responses[-1]
        assert status == 200 and extra['accepted'] and reply['chat'] == row['jid']
        assert extra['source_account'] == fixture.view_account(row)
        handler.rfile = io.BytesIO(encoded)
        handler.do_POST()
        assert responses[-1][2]['duplicate'] and not responses[-1][2]['accepted']
        body['account'] = fixture.view_account(row)
        encoded = json.dumps(body).encode()
        handler.headers = {'Content-Length': str(len(encoded))}
        handler.rfile = io.BytesIO(encoded)
        handler.do_POST()
        assert responses[-1][0] == 400, 'fixture accepted a non-unified send shape'
    handler.path = '/v1/wazig/messages?chat=' + wa[0]['jid']
    handler.do_GET()
    assert len(responses[-1][1]) == 2
    assert all(row['ChatJID'] == wa[0]['jid'] for row in responses[-1][1])
    require(OLD_SOURCE_ACCOUNT, ['account.len > 0', 'else fallback'])
    old_views = {(row['provider'], row.get('account', 'hub-cache')) for row in rows}
    assert len(old_views) == 2 and len(accounts) == 4

def tooltip_registration(source):
    require(source, ['const tooltip_info_size = @offsetOf(win.TOOLINFOW, "lParam") + @sizeOf(win.LPARAM);'])
    infos = re.findall(r'win\.TOOLINFOW\{(.*?)\n    };', source, re.S)
    assert len(infos) == 4, 'audit every tooltip registration and update structure'
    for info in infos:
        require(info, ['.cbSize = tooltip_info_size,'])
    add = section(source, 'fn addTooltip(', 'fn updateChatTooltip(')
    require(add, ['.uFlags = win.TTF_IDISHWND | win.TTF_SUBCLASS,',
                  '.hwnd = win.GetParent(target),', '.uId = @intFromPtr(target),',
                  'if (win.SendMessageW(tt, win.TTM_ADDTOOLW, 0, @as(win.LPARAM, @bitCast(@intFromPtr(&info)))) == 0)',
                  'appendLaunchLog(a, "tooltip: TTM_ADDTOOLW failed for window")'])
    create = section(source, 'fn createTooltips(', 'fn attachUnavailableReason(')
    require(create, ['addTooltip(a, tt, a.chats_hwnd,',
                     'if (win.SendMessageW(tt, win.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&attach_info))) == 0)',
                     'appendLaunchLog(a, "tooltip: TTM_ADDTOOLW failed for attachment rectangle")'])


def check_tooltip_registration():
    source = read('src/main.zig')
    tooltip_registration(source)
    old_add = """fn addTooltip(tt: win.HWND, tool: ?win.HWND, text: [*:0]const u16) void {
    const target = tool orelse return;
    var info = win.TOOLINFOW{
        .cbSize = tooltip_info_size,
        .uFlags = win.TTF_IDISHWND | win.TTF_SUBCLASS,
        .hwnd = win.GetParent(target),
        .uId = @intFromPtr(target),
        .lpszText = @constCast(text),
    };
    _ = win.SendMessageW(tt, win.TTM_ADDTOOLW, 0, @as(win.LPARAM, @bitCast(@intFromPtr(&info))));
}"""
    old_attach = '_ = win.SendMessageW(tt, win.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&attach_info)));'
    add = re.search(r'^fn addTooltip\([^\n]*\n.*?^}', source, re.M | re.S).group()
    attach = 'if (win.SendMessageW(tt, win.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&attach_info))) == 0) {\n        appendLaunchLog(a, "tooltip: TTM_ADDTOOLW failed for attachment rectangle");\n    }'
    for current, old in [(add, old_add), (attach, old_attach)]:
        assert current in source
        try:
            tooltip_registration(source.replace(current, old, 1))
        except AssertionError:
            pass
        else:
            raise AssertionError('unchecked tooltip registration negative control unexpectedly accepted')
    for match in re.finditer(r'\.cbSize = tooltip_info_size,', source):
        try:
            tooltip_registration(source[:match.start()] + '.cbSize = @sizeOf(win.TOOLINFOW),' + source[match.end():])
        except AssertionError:
            pass
        else:
            raise AssertionError('V3 tooltip size mutation unexpectedly accepted')
    print('TOOLTIP REGISTRATION VERIFIED: V2 size for registration and updates, failures logged; old V3 source rejected')


def check_workspace_names():
    check_tooltip_registration()
    hub = read('src/hub.zig')
    main = read('src/main.zig')
    name_fragments = ['pub fn workspaceName(', 'string(row, "team_name")', 'pub fn accountView(',
                      'if (supplied.len > 0) supplied else cached_name', 'messenger_view.Account.init(provider, account, name)']
    require(hub, name_fragments)
    old = OLD_SOURCE_ACCOUNT + """pub fn accountView(row: std.json.ObjectMap, fallback: []const u8) ?messenger_view.Account {
    const provider = sourceProvider(row) orelse return null;
    return messenger_view.Account.init(provider, sourceAccount(row, fallback), string(row, "account_name"));
}
"""
    try:
        require(old, name_fragments)
    except AssertionError:
        pass
    else:
        raise AssertionError('old-code name-parser negative control unexpectedly accepted')
    require(main, ['hubWorkspaceNames(a, rows)', 'providerStatePath(a, "workspace-names.json")',
                   'readFileWin(a.allocator, path, msg_cache_max_bytes)', 'writeCacheFileAtomic(a, path, raw)',
                   'if (name.len == 0) continue;', 'hub.accountView(row.object, a.cache_tag.slice(), cached_name, direct_name, if (present) |index| known.items[index] else null)',
                   'installation.team_name.slice()', 'parsed.value.team_name'])
    for start, end in [('fn activeViewLabel(', 'fn hubWorkspaceNames('),
                       ('fn updateChatTooltip(', 'fn updateTooltipTheme('),
                       ('fn buildSortViewsItems(', 'fn openSortViews(')]:
        require(section(main, start, end), ['view.labelText()'])
    require(section(main, 'fn buildPaletteItems(', 'fn paletteScore('), ['view.labelText()'])
    require(section(main, 'fn loadChatsCache(', 'fn msgCacheDirName('), ['applyChats(a, data, false)'])
    require(section(main, 'fn applyChats(', 'fn '), ['rebuildViews(a, data.items)'])
    journey = read('tools/verify-wazig/views.ps1')
    validator = read('tools/verify-wazig/check-views-evidence.py')
    for check_id in ['view-label', 'sort-views', 'palette', 'inbox-tooltip']:
        require(journey, [f"Save-WorkspaceNameCheck $Session '{check_id}'"])
        require(validator, [f"'{check_id}'"])
    require(journey, ['Read-ListLabels $list', 'VerifyMenus]::Hover', 'tooltips_class32', '$tip.Current.Name',
                      'Save-Screen $Session workspace-palette', 'Save-Screen $Session "inbox-tooltip-$team"'])
    require(read('tools/verify-wazig/run.ps1'), ['$result.checks', '$journey.result_checks'])
    entry = next(row for row in json.loads(read('tools/verify-wazig/journeys.json'))['journeys'] if row['name'] == 'views')
    assert entry['result_checks'] == 'workspace-names.json'
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('workspace_names_fixture', root / 'tools/verify-wazig/fake-hub.py')
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    rows = fixture.view_rows()
    assert len(rows) == 8
    expected = {'T0ABC123': 'Alpha Workspace', 'T0DEF456': 'Beta Workspace'}
    for row in rows:
        if row['provider'] == 'slack':
            assert row['team_name'] == expected[fixture.view_account(row)]
        else:
            assert 'team_name' not in row
        assert 'account' not in row and 'account_name' not in row
    require(read('src/hub_test.zig'), ['"Slack Alpha Workspace", known.items[2].labelText()',
                                      '"Slack T0DEF456", known.items[3].labelText()',
                                      '"Slack Beta Workspace", cached.labelText()', '"Slack Direct Workspace", direct.labelText()'])
    decision = section(hub, 'pub fn accountView(', 'pub fn providerForView(')
    def require_precedence(source):
        require(source, ['if (direct_name.len > 0) direct_name else if (supplied.len > 0)',
                         'if (provider == .slack and name.len == 0) if (existing) |view| return view;',
                         'if (existing) |previous| view.selected = previous.selected;',
                         'messenger_view.Account.init(provider, account, name)'])
        assert 'view.label_buf' not in source
    require_precedence(decision)
    for fragment in ['if (direct_name.len > 0) direct_name else ',
                     'if (provider == .slack and name.len == 0) if (existing) |view| return view;',
                     'if (existing) |previous| view.selected = previous.selected;',
                     'messenger_view.Account.init(provider, account, name)']:
        try:
            require_precedence(decision.replace(fragment, '', 1))
        except AssertionError:
            pass
        else:
            raise AssertionError(f'workspace precedence mutation accepted: {fragment}')
    require(read('src/hub_test.zig'), [
        'test "hub duplicate rows retain named views and direct sign-in names win"',
        'hub.accountView(row.object, "hub-cache", "", "", view)',
        '"Slack Alpha Workspace", view.labelText()', '"Slack Beta Workspace", view.labelText()',
        '"slack:T0ABC123:C1", view.selected.key().id',
        'hub.accountView(row.object, "hub-cache", "Cached Workspace", "Direct Workspace", direct)',
        '"Slack Direct Workspace", direct.?.labelText()'])
    print('WORKSPACE NAMES VERIFIED: fixture names, parsing, cache, shared labels and four journey checks; old parser rejected')

checks = {'model': check_model, 'integration': check_integration, 'journey': check_journey, 'fixture': check_fixture, 'workspace-names': check_workspace_names}
checks[sys.argv[1]]()
print(f'views {sys.argv[1]} static PASS')
