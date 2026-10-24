import copy
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'tools/verify-wazig'
spec = importlib.util.spec_from_file_location('show_archived_hub', TOOLS / 'fake-hub.py')
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)


class ShowArchivedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.views = [dict(provider=p, account=a, label=a, inbox=False) for p, a in hub.SHOW_ARCHIVED_ACCOUNTS]
        self.requests = [dict(method='GET', status=200, authorized=True, wire_path='/v1/wazig/chats?archived=true')]
        self.write('session.json', dict(feature='show-archived', sha256='hash', commit='commit', pid=2, startTicks='new', root='isolated', id='id'))
        self.write('result.json', dict(feature='show-archived', status='passed'))
        self.write('show-archived-views.json', self.views)
        self.write('show-archived-tooltip.json', dict(text='Show archived  Alt+A', control='1146', pid=1))
        self.write('show-archived-restart.json', dict(old_pid=1, old_start='old', new_pid=2, new_start='new', root='isolated', id='id', sha256='hash'))
        for name, enabled in [('inbox-off', False), ('inbox-on', True), ('inbox-kept', True), ('inbox-return', True), ('restart-inbox', True), ('after', True)]:
            self.capture(name, enabled)
        for position, view in enumerate(self.views, 1):
            for phase, enabled in [('off', False), ('on', True), ('archived', True), ('unarchived', True)]:
                self.capture(f'view-{position}-{phase}', enabled, view, phase == 'archived')
            if position != 1:
                self.capture(f'view-{position}-disabled', False, view)
            if view['provider'] == 'whatsapp':
                chat = self.read(f'view-{position}-archived.state.json')['selected']['id']
                self.requests.extend(dict(method='POST', status=200, authorized=True, wire_path='/v1/wazig/archive', body=dict(chat=chat, archived=value)) for value in (True, False))
        for name, enabled, view in [('palette-off', False, self.views[0]), ('palette-on', True, self.views[0]), ('account-one-kept', True, self.views[0]),
                                    ('account-two-off', False, self.views[1]), ('restart-one', True, self.views[0]), ('restart-two', False, self.views[1])]:
            self.capture(name, enabled, view)
        archived = [self.control(row) for row in hub.show_archived_rows() if row['archived']]
        self.write('archived-only.state.json', dict(show_archived=True, chat_count=len(archived)))
        self.write('archived-only.chats.json', dict(chats=archived))
        (self.folder / 'tooltip.png').write_bytes(b'\x89PNG' + b'x' * 11000)
        self.write('side-effects.json', dict(pending_sends=0, pending_archives=0, sync='stopped', include_archived=True, show_archived=False, current_view=dict(inbox=True), production_preferences_absent=True, whatsapp_store_absent=True, telegram_store_absent=True))
        (self.folder / 'preferences.txt').write_text('ShowArchived:all : 1\nShowArchived:whatsapp:personal : 1')
        (self.folder / 'actions.log').write_text('\n'.join('keys: ' + key for key in ('%i', '%1', '%2', '%3', '%4', '%5', '%a', '^e', '^k', '{ENTER}')))
        (self.folder / 'hub-proof.log').write_text('show-archived show-archived-all PASS')
        (self.folder / 'result.txt').write_text('JOURNEY PASSED: show-archived')
        (self.folder / 'cleanup.txt').write_text('CLEANUP PASSED: synthetic evidence')
        self.save_requests()

    def control(self, row):
        account = next(account for provider, account in hub.SHOW_ARCHIVED_ACCOUNTS if provider == row['provider'] and
                       (row['jid'].startswith(account + ':') or provider != 'whatsapp'))
        return dict(id=row['jid'], name=row['name'], provider=row['provider'], account='hub-cache', view_account=account,
                    archived=row['archived'], unread=row['unread'], archive_label='Archived' if row['archived'] else '', last_message_time=row['last_message_ts'])

    def capture(self, name, enabled, view=None, changed=False):
        rows = [self.control(row) for row in hub.show_archived_rows()]
        rows = [row for row in rows if (row['unread'] if view is None else row['provider'] == view['provider'] and row['view_account'] == view['account'])]
        rows = [row for row in rows if enabled or not row['archived']]
        rows.sort(key=lambda row: row['last_message_time'], reverse=True)
        if changed:
            rows[0].update(archived=True, archive_label='Archived')
        self.write(f'{name}.chats.json', dict(chats=rows))
        self.write(f'{name}.state.json', dict(include_archived=enabled, show_archived=False, unread_only=view is None,
                                             chat_count=len(rows), current_view=view or dict(inbox=True), selected=rows[0]))
        (self.folder / f'{name}.png').write_bytes(b'\x89PNG\r\n\x1a\n' + b'x' * 11000)
        (self.folder / f'{name}.uia.txt').write_text('MessagesZig | Combined inbox - Wazig v0.0.526\n1146 | Button | Show archived: ' + ('On' if enabled else 'Off'))

    def write(self, name, data):
        (self.folder / name).write_text(json.dumps(data), encoding='utf-8')

    def read(self, name):
        return json.loads((self.folder / name).read_text())

    def save_requests(self):
        (self.folder / 'bridge-requests.jsonl').write_text('\n'.join(json.dumps(row) for row in self.requests))

    def validate(self):
        return subprocess.run([sys.executable, str(TOOLS / 'check-evidence.py'), str(self.folder)], capture_output=True, text=True)

    def test_complete_evidence_dispatch(self):
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('SHOW ARCHIVED EVIDENCE VERIFIED', result.stdout)

    def test_rejects_filter_marking_isolation_restart_and_tooltip_regressions(self):
        mutations = [('inbox-off.chats.json', lambda value: value['chats'][0].update(archived=True)),
                     ('inbox-on.chats.json', lambda value: value['chats'][0].update(unread=False)),
                     ('view-4-on.chats.json', lambda value: value['chats'][-1].update(archive_label='')),
                     ('view-2-off.state.json', lambda value: value.update(include_archived=True)),
                     ('restart-two.state.json', lambda value: value.update(include_archived=True)),
                     ('restart-one.state.json', lambda value: value.update(include_archived=False)),
                     ('show-archived-tooltip.json', lambda value: value.update(text='Show archived')),
                     ('show-archived-restart.json', lambda value: value.update(root='another-profile')),
                     ('view-3-unarchived.state.json', lambda value: value['selected'].update(archived=True)),
                     ('inbox-on.chats.json', lambda value: value['chats'].reverse())]
        for name, mutate in mutations:
            with self.subTest(name=name, mutation=mutate):
                original = self.read(name)
                broken = copy.deepcopy(original)
                mutate(broken)
                self.write(name, broken)
                self.assertNotEqual(self.validate().returncode, 0)
                self.write(name, original)
        self.assertEqual(self.validate().returncode, 0)

    def test_rejects_local_provider_network_archive_and_missing_whatsapp_write(self):
        original = copy.deepcopy(self.requests)
        for provider in ('slack', 'telegram', 'signal'):
            chat = next(row['jid'] for row in hub.show_archived_rows() if row['provider'] == provider)
            self.requests = original + [dict(method='POST', authorized=True, status=200, wire_path='/v1/wazig/archive', body=dict(chat=chat, archived=True))]
            self.save_requests()
            self.assertNotEqual(self.validate().returncode, 0)
        self.requests = original[:-1]
        self.save_requests()
        self.assertNotEqual(self.validate().returncode, 0)

    def test_fixture_filters_and_only_whatsapp_remote_archive(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), hub.ShowArchivedHandler)
        server.daemon_threads = True
        server.state = hub.bridge.State(self.folder / 'fixture.jsonl')
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)

        def call(method, path, body=None):
            connection = HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            try:
                connection.request(method, path, json.dumps(body) if body is not None else None,
                                   {'Authorization': f'Bearer {hub.bridge.KEY}', 'Connection': 'close'})
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()

        status, normal = call('GET', '/v1/wazig/chats')
        status2, archived = call('GET', '/v1/wazig/chats?archived=true')
        self.assertEqual((status, status2, len(normal), len(archived)), (200, 200, 10, 10))
        self.assertEqual({row['provider'] for row in archived}, {'whatsapp', 'slack', 'telegram', 'signal'})
        self.assertEqual(sum(row['unread'] for row in archived), 5)
        chat = normal[0]['jid']
        self.assertEqual(call('POST', '/v1/wazig/archive', dict(chat=chat, archived=True))[0], 200)
        self.assertEqual(len(call('GET', '/v1/wazig/chats?archived=true')[1]), 11)
        self.assertEqual(call('POST', '/v1/wazig/archive', dict(chat=chat, archived=False))[0], 200)
        for provider in ('slack', 'signal', 'telegram'):
            chat = next(row['jid'] for row in normal if row['provider'] == provider)
            self.assertEqual(call('POST', '/v1/wazig/archive', dict(chat=chat, archived=True))[0], 400)
        self.assertEqual(call('GET', '/v1/wazig/messages?chat=' + normal[1]['jid'] + '&limit=20')[1][0]['FromMe'], False)

    def test_app_exposes_journey_switch_and_marker_contract(self):
        source = (ROOT / 'src/main.zig').read_text()
        for required in ('const id_include_archived = 1146;', 'command_include_archived',
                         '"Show archived  Alt+A"', '"Toggle archived chats in this view", "Alt+A"',
                         '\\"include_archived\\"', '\\"archive_label\\"'):
            self.assertIn(required, source)
        shortcut = source.split('fn handleKeyboard(', 1)[1].split('fn jumpToLatestMessage(', 1)[0]
        self.assertIn("alt and !control and !shift and key == 'A'", shortcut)

    def test_shortcut_was_free_at_journey_commit_with_occupied_control(self):
        baseline = subprocess.check_output(['git', 'show', '4520a77:src/main.zig'], cwd=ROOT, text=True)
        import re
        def occupied(key):
            return bool(re.search(r"if \(alt and !control and !shift and key == '" + key + r"'\)", baseline))
        self.assertTrue(occupied('I'))
        self.assertFalse(occupied('A'))
        self.assertNotIn('Alt+A', baseline)
        self.assertIn("if (control and !alt and !shift and key == 'A')", baseline)

    def test_changed_feature_code_has_no_comments(self):
        result = subprocess.run(['node', str(ROOT / 'tools/strip-comments.mjs'), '--check', str(ROOT)], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('No code comments found.', result.stdout)

    def test_registry_wires_pr_matrix_map_and_keyboard_journey(self):
        registry = json.loads((TOOLS / 'journeys.json').read_text())
        entry = next(row for row in registry['journeys'] if row['name'] == 'show-archived')
        self.assertTrue(entry['pr'] and entry['evidence'])
        self.assertEqual(entry['validator'], dict(file='check-show-archived-evidence.py', function='check_show_archived'))
        self.assertEqual(entry['hub_handler']['class'], 'ShowArchivedHandler')
        self.assertIn('Invoke-ShowArchivedJourney $session $start', (TOOLS / entry['script']).read_text())
        journey = (TOOLS / 'show-archived.ps1').read_text()
        for required in ("'%i'", "'%a'", "'^e'", "'1146'", 'WAZIG_VERIFY_RESTART', 'Read-ArchivedSwitchTooltip', 'Show archived chats'):
            self.assertIn(required, journey)
        for forbidden in ('WM_COMMAND', 'SendMessage', 'PostMessage', '.SetValue(', '/fixture/'):
            self.assertNotIn(forbidden, journey)
        workflow = (ROOT / '.github/workflows/verify.yml').read_text()
        self.assertIn("row['pr']", workflow)
        self.assertIn('matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}', workflow)
        self.assertIn('feature=show-archived', (ROOT / '.claude/skills/verify-wazig/features/show-archived.md').read_text())


if __name__ == '__main__':
    unittest.main()
