import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import socket
import shutil
import subprocess
import struct
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlencode, urlsplit
import zlib


spec = importlib.util.spec_from_file_location('bridge_fixture', Path(__file__).with_name('fake-wa-bridge.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
ALPHA = 'fixture-alpha'
BETA = 'fixture-beta'


WORKSPACE_CHATS = [
    ('slack:fixture-amber:channel-alpha', 'Verification Amber', 'slack'),
    ('slack:fixture-cobalt:channel-beta', 'Verification Cobalt', 'slack'),
    ('slack:fixture-empty:channel-gamma', 'Verification Empty', 'slack'),
    ('whatsapp:fixture:contact-delta', 'Verification Delta', 'whatsapp'),
    ('signal:fixture-contact', 'Verification Signal', 'signal'),
]
WORKSPACE_COLOURS = {'fixture-amber': (240, 160, 32), 'fixture-cobalt': (48, 112, 240)}


def workspace_png(team):
    colour = WORKSPACE_COLOURS[team]
    letter = ['01110', '11011', '11011', '11111', '11011', '11011', '11011'] if team == 'fixture-amber' else [
        '01111', '11000', '11000', '11000', '11000', '11000', '01111']
    rows = []
    for y in range(64):
        row = bytearray(b'\x00')
        for x in range(64):
            gx, gy = (x - 22) // 4, (y - 18) // 4
            ink = 0 <= gx < 5 and 0 <= gy < 7 and letter[gy][gx] == '1'
            row.extend((255, 255, 255) if ink else colour)
        rows.append(row)

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


class Handler(bridge.Handler):
    def record(self, status, **extra):
        if 'body' in extra and hasattr(self, 'wire_body'):
            extra['body'] = self.wire_body
        if self.wire_path == '/v1/wazig/react' and 'body' in extra:
            body = extra['body']
            with self.state.lock:
                with self.state.log.with_name('react-requests.jsonl').open('a', encoding='utf-8') as stream:
                    stream.write(json.dumps(body) + '\n')
                if status == 200:
                    self.state.reactions[(body['chat'], body['msg'])] = dict(body)
        super().record(status, wire_path=self.wire_path, **extra)

    def respond(self, status, data, content_type='application/json', **extra):
        if content_type == 'application/json' and isinstance(data, list):
            data = json.loads(json.dumps(data).replace(bridge.ACCOUNT + ':', '').replace(bridge.ALPHA, ALPHA).replace(bridge.BETA, BETA))
            for row in data:
                if 'jid' in row:
                    row['provider'] = 'slack' if row['jid'] == ALPHA else 'whatsapp'
                    if row['jid'] == BETA:
                        stamp = datetime.fromisoformat(row['last_message_ts']) - timedelta(seconds=1)
                        row['last_message_ts'] = stamp.isoformat().replace('+00:00', 'Z')
        super().respond(status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        url = urlsplit(self.path)
        if url.path.startswith('/v1/wazig/workspace-icon/'):
            if not self.authorized():
                return
            self.workspace_icon(url.path)
            return
        if not url.path.startswith('/v1/wazig/'):
            self.respond(400, {'error': 'expected unified API'})
            return
        route = url.path.replace('/v1/wazig/', '/v1/', 1)
        query = parse_qs(url.query, keep_blank_values=True)
        if route in ('/v1/chats', '/v1/messages'):
            if 'account' in query:
                self.respond(400, {'error': 'source account must stay on hub'})
                return
            query['account'] = [bridge.ACCOUNT]
            if 'chat' in query:
                query['chat'] = [{ALPHA: bridge.ALPHA, BETA: bridge.BETA}.get(query['chat'][0], '')]
        if route.startswith('/v1/media/'):
            route = route.replace('/v1/media/', '/v1/media/' + bridge.ACCOUNT + '/', 1)
        if route.startswith('/v1/avatar/'):
            route = route.replace('/v1/avatar/', '/v1/avatar/' + bridge.ACCOUNT + '/', 1)
        route = route.replace(ALPHA, bridge.ALPHA).replace(BETA, bridge.BETA)
        self.path = route + ('?' + urlencode(query, doseq=True) if query else '')
        super().do_GET()

    def workspace_icon(self, path):
        team = unquote(path.removeprefix('/v1/wazig/workspace-icon/'))
        if team in WORKSPACE_COLOURS:
            image = workspace_png(team)
            self.respond(200, image, 'image/png', sha256=hashlib.sha256(image).hexdigest())
        else:
            self.respond(404, {'error': 'workspace icon unavailable'})

    def event(self, event_id, kind, chat):
        handle = chat.removeprefix(bridge.ACCOUNT + ':').replace(bridge.ALPHA, ALPHA).replace(bridge.BETA, BETA)
        data = dict(id=event_id, chat=handle, kind=kind)
        self.wfile.write(f'id: {event_id}\ndata: {json.dumps(data)}\n\n'.encode())
        self.wfile.flush()
        self.state.record(dict(method='SSE', path='/v1/events', wire_path=self.wire_path, id=event_id, kind=kind))

    def do_POST(self):
        self.wire_path = self.path
        if self.path == '/fixture/live':
            super().do_POST()
            return
        if not self.path.startswith('/v1/wazig/'):
            self.respond(400, {'error': 'expected unified API'})
            return
        if not self.authorized():
            return
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = json.loads(data)
        fields = {
            '/v1/wazig/send': {'chat', 'text', 'reply_to', 'client_id'},
            '/v1/wazig/mark-read': {'chat', 'message_id'},
            '/v1/wazig/archive': {'chat', 'archived'},
            '/v1/wazig/react': {'chat', 'msg', 'emoji', 'client_id'},
        }
        if set(body) != fields.get(self.path) or body.get('chat') not in (ALPHA, BETA):
            self.respond(400, {'error': 'invalid unified payload'}, body=body)
            return
        self.wire_body = dict(body)
        body['chat'] = {ALPHA: bridge.ALPHA, BETA: bridge.BETA}[body['chat']]
        body['account'] = bridge.ACCOUNT
        encoded = json.dumps(body).encode()
        self.rfile = io.BytesIO(encoded)
        self.headers.replace_header('Content-Length', str(len(encoded)))
        self.path = self.path.replace('/v1/wazig/', '/v1/', 1)
        super().do_POST()



ARCHIVE_GROUP = 'personal:120363000000000001@g.us'
ARCHIVE_OTHER = 'personal:15550000003@s.whatsapp.net'
PLAIN_REACTED = 'personal:15550000005@s.whatsapp.net'
PLAIN_NEWER = 'personal:15550000006@s.whatsapp.net'
PLAIN_STAMPS = {PLAIN_REACTED: '2026-10-10T11:30:00Z', PLAIN_NEWER: '2026-10-10T11:00:00Z'}
ARCHIVE_TELEGRAM = 'telegram:user:7001'
ARCHIVE_STAMPS = {**PLAIN_STAMPS, ARCHIVE_TELEGRAM: '2026-10-10T10:00:00Z'}


MIXED = '15550000005@s.whatsapp.net'
MIXED_LID = '99990000000001@lid'
MIXED_TEXTS = ['Mixed phone first', 'Mixed lid first', 'Mixed phone second', 'Mixed lid second']
MIXED_TOTAL = 250
MIXED_BASE = datetime(2026, 10, 1, 12, 0, 0, tzinfo=timezone.utc)
MIXED_TIED_INDEX = 79
CURSOR_STAMP = re.compile(r'\d{4}-\d{2}-\d{2}T\S*$')


def mixed_stamp(index):
    shared = index - 1 if index == MIXED_TIED_INDEX else index
    return (MIXED_BASE - timedelta(seconds=shared)).isoformat().replace('+00:00', 'Z')


def mixed_rows():
    rows = []
    for index in range(MIXED_TOTAL):
        text = MIXED_TEXTS[index] if index < len(MIXED_TEXTS) else f'Mixed history {index + 1}'
        rows.append(dict(MsgID=f'MIXED-{index + 1}', ChatJID=MIXED if index % 2 == 0 else MIXED_LID,
                         Timestamp=mixed_stamp(index), Text=text, DisplayText=text, FromMe=False,
                         SenderName='Fixture Sender', SenderJID='15550000005@s.whatsapp.net'))
    return rows


def split_before(before):
    match = CURSOR_STAMP.search(before)
    if match is None:
        raise ValueError(f'before is neither id:timestamp nor a timestamp: {before}')
    msg_id = before[:match.start()].rstrip(':').removeprefix(bridge.ACCOUNT + ':')
    return msg_id, datetime.fromisoformat(match.group(0))


def mixed_page(query):
    limit = int(query.get('limit', ['80'])[0])
    before = query.get('before', [''])[0]
    rows = mixed_rows()
    if before:
        msg_id, cutoff = split_before(before)
        rows = [row for row in rows if datetime.fromisoformat(row['Timestamp']) <= cutoff and row['MsgID'] != msg_id]
    return rows[:limit]


class MixedLidHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        if content_type == 'application/json' and isinstance(data, list) and self.wire_path.startswith('/v1/wazig/chats'):
            archived = getattr(self.state, 'mixed_archived', False)
            if ('archived=true' in self.wire_path) == archived:
                data = data + [dict(jid=MIXED, name='Verification Mixed', provider='whatsapp', kind='direct',
                                    last_message_ts='2025-12-01T00:00:00Z', unread_count=0, archived=archived)]
        super().respond(status, data, content_type, **extra)

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/messages' and query.get('chat') == [MIXED]:
            self.wire_path = self.path
            if self.authorized():
                try:
                    page = mixed_page(query)
                except ValueError as error:
                    self.respond(400, {'error': str(error)})
                    return
                self.respond(200, page, mixed_before=query.get('before', [''])[0], mixed_count=len(page))
            return
        super().do_GET()

    def do_POST(self):
        if self.path in ('/v1/wazig/mark-read', '/v1/wazig/archive'):
            data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.rfile = io.BytesIO(data)
            body = json.loads(data or '{}')
            if body.get('chat') == MIXED:
                self.wire_path = self.path
                if self.authorized():
                    if self.path == '/v1/wazig/archive':
                        self.state.mixed_archived = bool(body.get('archived'))
                    self.path = self.path.replace('/v1/wazig/', '/v1/', 1)
                    self.respond(200, {'status': 'ok'}, body=body)
                return
        super().do_POST()


def plain_stamp(seconds):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ')


class HubArchiveHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            with self.state.lock:
                archived = self.state.archive_group_archived
                stamp = self.state.archive_stamp
            rows = [dict(jid=ARCHIVE_GROUP, name='Verification Group', provider='whatsapp', kind='group',
                         last_message_ts=stamp, archived=archived, unread=True, unread_count=1),
                    dict(jid=ARCHIVE_OTHER, name='Verification Inbox', provider='whatsapp', kind='direct',
                         last_message_ts='2026-10-10T12:00:00Z', archived=self.state.archive_other_archived, unread=False, unread_count=0)]
            with self.state.lock:
                for jid, plain in self.state.plain_dms.items():
                    rows.append(dict(jid=jid, name='Fixture Contact' if jid == PLAIN_REACTED else 'Fixture Contact Two',
                                     provider='telegram' if jid == ARCHIVE_TELEGRAM else 'whatsapp',
                                     account='telegram' if jid == ARCHIVE_TELEGRAM else 'personal',
                                     kind='direct', last_message_ts=plain['after'] or ARCHIVE_STAMPS[jid],
                                     archived=plain['archived'], unread=False, unread_count=0))
            rows = [row for row in rows if row['archived'] == (query.get('archived') == ['true'])]
            self.respond(200, rows, rows=rows,
                         group_archived=archived, group_last_message_ts=stamp, group_unread_count=1)
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            rows = [] if chat != ARCHIVE_GROUP else [dict(MsgID='ARCHIVE-INCOMING', ChatJID=chat,
                    Timestamp=self.state.archive_stamp, Text='Synthetic incoming group message', FromMe=False,
                    SenderName='Fixture Sender', SenderJID='15550000004@s.whatsapp.net')]
            with self.state.lock:
                plain = self.state.plain_dms.get(chat)
                if plain:
                    rows = [dict(MsgID='PLAIN-INCOMING', ChatJID=chat, Timestamp=ARCHIVE_STAMPS[chat],
                                 Text='Synthetic incoming direct message', FromMe=False,
                                 SenderName='Fixture Contact', SenderJID=chat)]
                    if plain['after'] and chat == PLAIN_REACTED:
                        rows.insert(0, dict(MsgID='PLAIN-REACTION', ChatJID=chat, Timestamp=plain['after'], Text='',
                                            FromMe=True, ReactionToID='PLAIN-INCOMING', SenderName='Fixture Owner',
                                            SenderJID='15550000007@s.whatsapp.net'))
                    elif plain['after']:
                        rows.insert(0, dict(MsgID='PLAIN-NEWER', ChatJID=chat, Timestamp=plain['after'],
                                            Text='Synthetic newer direct message', FromMe=False,
                                            SenderName='Fixture Contact Two', SenderJID=chat))
            self.respond(200, rows)
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        else:
            self.respond(404, {'error': 'unknown archive fixture path'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/fixture/archive-incoming' and body == {}:
            with self.state.lock:
                self.state.archive_group_archived = False
                self.state.archive_stamp = '2026-10-10T13:00:00Z'
            self.respond(200, {'archived': False, 'last_message_ts': self.state.archive_stamp, 'unread_count': 1})
        elif self.path == '/fixture/plain-dms' and body == {}:
            with self.state.lock:
                for jid in PLAIN_STAMPS:
                    self.state.plain_dms[jid] = dict(archived=False, after='')
            self.respond(200, {'chats': sorted(PLAIN_STAMPS), 'last_message_ts': PLAIN_STAMPS})
        elif self.path == '/fixture/telegram-dm' and body == {}:
            with self.state.lock:
                self.state.plain_dms[ARCHIVE_TELEGRAM] = dict(archived=False, after='')
            self.respond(200, {'chat': ARCHIVE_TELEGRAM, 'provider': 'telegram', 'account': 'telegram'})
        elif self.path == '/fixture/plain-incoming' and body == {}:
            with self.state.lock:
                stamp = plain_stamp(10)
                self.state.archive_rearchive_enabled = False
                for chat in (PLAIN_NEWER, ARCHIVE_TELEGRAM):
                    self.state.plain_dms[chat].update(archived=False, after=stamp)
            self.respond(200, {'chats': [PLAIN_NEWER, ARCHIVE_TELEGRAM], 'archived': False, 'last_message_ts': stamp})
        elif self.path == '/fixture/rearchive-enable' and body == {}:
            self.state.archive_rearchive_enabled = True
            self.respond(200, {'ok': True})
        elif self.path == '/v1/wazig/archive' and set(body) == {'chat', 'archived'} and body['chat'] == ARCHIVE_OTHER and isinstance(body['archived'], bool):
            self.state.archive_other_archived = body['archived']
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/archive' and body == {'chat': ARCHIVE_GROUP, 'archived': True}:
            with self.state.lock:
                self.state.archive_group_archived = True
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/archive' and body.get('chat') == ARCHIVE_TELEGRAM:
            self.respond(502, {'error': 'Telegram action unsupported'}, body=body)
        elif self.path == '/v1/wazig/archive' and set(body) == {'chat', 'archived'} and body.get('chat') in ARCHIVE_STAMPS and isinstance(body.get('archived'), bool) and body['chat'] in self.state.plain_dms:
            with self.state.lock:
                plain = self.state.plain_dms[body['chat']]
                if body['archived'] and not self.state.archive_rearchive_enabled:
                    self.respond(409, {'error': 'fixture awaiting local archive evidence'}, body=body)
                    return
                plain['archived'] = body['archived']
                if body['archived'] and not plain['after']:
                    plain['after'] = plain_stamp(5)
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/mark-read' and body.get('chat') in (ARCHIVE_GROUP, ARCHIVE_OTHER, PLAIN_REACTED, PLAIN_NEWER, ARCHIVE_TELEGRAM):
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected archive fixture write'}, body=body)

PALETTE_INBOX = [
    ('personal:15550000021@s.whatsapp.net', 'Inbox WhatsApp Epsilon', 'whatsapp', 'direct', '2026-10-10T12:00:00Z'),
    ('personal:15550000022@s.whatsapp.net', 'Inbox WhatsApp Zeta', 'whatsapp', 'direct', '2026-10-10T11:00:00Z'),
    ('slack:T0PALETTE:C0000000001', 'Inbox Slack Delta', 'slack', 'direct', '2026-10-10T10:00:00Z'),
]
PALETTE_ARCHIVED = [
    ('personal:15550000031@s.whatsapp.net', 'Archived Person Alpha', 'whatsapp', 'direct', '2026-09-10T12:00:00Z'),
    ('telegram:user:7001001', 'Archived Telegram Beta', 'telegram', 'direct', '2026-09-09T12:00:00Z'),
    ('slack:T0PALETTE:C0000000002', 'Archived Slack Gamma', 'slack', 'group', '2026-09-08T12:00:00Z'),
]


def palette_rows(archived):
    rows = []
    for jid, name, provider, kind, stamp in PALETTE_ARCHIVED if archived else PALETTE_INBOX:
        row = dict(jid=jid, name=name, provider=provider, kind=kind, archived=archived, last_message_ts=stamp,
                   unread=False, unread_count=0, pinned=False, muted_until='')
        if provider == 'slack':
            row['team_name'] = 'Palette Workspace'
        rows.append(row)
    return rows


class PaletteArchivedHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            self.respond(200, palette_rows(query.get('archived', ['false'])[0] == 'true'))
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            known = {row[0]: row for row in PALETTE_INBOX + PALETTE_ARCHIVED}
            if chat not in known:
                self.respond(404, {'error': 'unknown palette chat'})
                return
            self.respond(200, [dict(MsgID='PALETTE-HISTORY', ChatJID=chat, Timestamp=known[chat][4],
                                    Text='Synthetic palette history', FromMe=False,
                                    SenderName='Fixture Sender', SenderJID='fixture-sender')])
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        else:
            self.respond(404, {'error': 'unknown palette fixture path'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path in ('/v1/wazig/archive', '/v1/wazig/mark-read'):
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected palette fixture write'}, body=body)


SHOW_ARCHIVED_ACCOUNTS = [('whatsapp', 'personal'), ('whatsapp', 'business'),
                          ('slack', 'T0ARCHIVED'), ('telegram', 'telegram'), ('signal', 'signal')]


def show_archived_rows():
    rows = []
    for index, (provider, account) in enumerate(SHOW_ARCHIVED_ACCOUNTS):
        for number, (archived, unread) in enumerate([(False, False), (False, True), (True, True), (True, False)]):
            jid = (f'{account}:1555000{index:02}{number:02}@s.whatsapp.net' if provider == 'whatsapp' else
                   f'slack:{account}:C{number:010}' if provider == 'slack' else
                   f'telegram:user:{7000 + number}' if provider == 'telegram' else f'signal:fixture-{number}')
            rows.append(dict(jid=jid, provider=provider, name=f'{account} row {number}', kind='direct',
                             last_message_ts=f'2026-10-24T12:{30 - number * 5 - index:02}:00Z',
                             unread=unread, unread_count=int(unread), archived=archived,
                             team_name='Archive Workspace' if provider == 'slack' else ''))
    return rows


class ShowArchivedHandler(PaletteArchivedHandler):
    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            rows = getattr(self.state, 'show_archived_rows', None)
            if rows is None:
                self.state.show_archived_rows = rows = show_archived_rows()
            self.respond(200, [row for row in rows if row['archived'] == (query.get('archived') == ['true'])])
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            row = next((row for row in show_archived_rows() if row['jid'] == chat), None)
            if row is None:
                self.respond(404, {'error': 'unknown archived-switch chat'})
                return
            self.respond(200, [dict(MsgID='ARCHIVED-SWITCH', ChatJID=chat, Timestamp=row['last_message_ts'],
                                    Text='Synthetic archive switch probe', FromMe=not row['unread'],
                                    SenderName='Fixture Sender')] if query.get('limit') == ['20'] else [])
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/archive' and isinstance(body.get('archived'), bool):
            row = next((row for row in self.state.show_archived_rows if row['jid'] == body.get('chat')), None)
            if row is None or row['provider'] != 'whatsapp':
                self.respond(400, {'error': 'only WhatsApp archives remotely'}, body=body)
                return
            row['archived'] = body['archived']
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected archive-switch write'}, body=body)


def passage_rows(chat):
    return [dict(MsgID=f'PASSAGE-{n}', ChatJID=chat,
                 Timestamp=f'2026-10-{10 if n <= 3 else 11}T12:{n:02}:00Z',
                 Text='alpha MIDDLE omega' if n != 6 else '\n'.join(['alpha MIDDLE omega'] * 40),
                 FromMe=n == 3, SenderName='Fixture Amber' if n % 2 else 'Fixture Cobalt',
                 SenderJID='fixture-amber' if n % 2 else 'fixture-cobalt') for n in range(1, 8)]


class PassageCopyHandler(Handler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == '/v1/wazig/chats':
            self.wire_path = self.path
            if self.authorized():
                rows = [dict(jid=chat, name=name, provider=provider, kind=kind,
                             last_message_ts='2026-10-11T12:07:00Z', archived=False, unread_count=0)
                        for chat, name, provider, kind in [(ALPHA, 'Verification Alpha', 'slack', 'group'),
                                                           (BETA, 'Verification Beta', 'whatsapp', 'direct')]]
                bridge.Handler.respond(self, 200, [] if parse_qs(url.query).get('archived') == ['true'] else rows)
        elif url.path == '/fixture/passage':
            self.wire_path = self.path
            if self.authorized():
                self.respond(200, {chat: passage_rows(chat) for chat in (ALPHA, BETA)})
        elif url.path == '/v1/wazig/messages':
            self.wire_path = self.path
            if self.authorized():
                chat = parse_qs(url.query).get('chat', [''])[0]
                self.respond(200, list(reversed(passage_rows(chat))) if chat in (ALPHA, BETA) else [])
        else:
            super().do_GET()


class ReactionsHandler(Handler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path != '/v1/wazig/messages':
            super().do_GET()
            return
        self.wire_path = self.path
        if not self.authorized():
            return
        chat = parse_qs(url.query).get('chat', [''])[0]
        if chat not in (ALPHA, BETA):
            self.respond(400, {'error': 'unknown reaction chat'})
            return
        message_id = 'BASELINE' if chat == ALPHA else 'BASELINE_BETA'
        rows = [dict(MsgID=message_id, ChatJID=chat, Timestamp=self.state.stamp,
                     Text='Synthetic reaction verification', DisplayText='Synthetic reaction verification',
                     FromMe=False, SenderName='Fixture Sender', SenderJID='fixture-sender')]
        if chat == BETA:
            rows.extend([
                dict(MsgID='CHIP', ChatJID=chat, Timestamp=self.state.stamp,
                     Text='Chip reaction verification', FromMe=False,
                     SenderName='Fixture Sender', SenderJID='fixture-sender'),
                dict(MsgID='CHIP-FRIEND', ChatJID=chat, Timestamp=self.state.stamp,
                     Text='', FromMe=False, SenderName='Fixture Friend', SenderJID='fixture-friend',
                     ReactionToID='CHIP', ReactionEmoji='❤️'),
            ])
        with self.state.lock:
            for target in (message_id, 'CHIP') if chat == BETA else (message_id,):
                reaction = self.state.reactions.get((chat, target))
                if reaction and reaction['emoji']:
                    rows.append(dict(MsgID='REACTION-' + target, ChatJID=chat, Timestamp=self.state.stamp,
                                     Text='', FromMe=True, ReactionToID=target, ReactionEmoji=reaction['emoji']))
        self.respond(200, rows)


class SlackSortHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            rows = [dict(jid=chat, name=name, provider='slack', kind='direct',
                         last_message_ts=self.state.sort_times[chat], unread_count=0, archived=False)
                    for chat, name in [('fixture-alpha', 'Verification Alpha'),
                                       ('fixture-unknown', 'Verification Aardvark'),
                                       ('fixture-gamma', 'Verification Gamma'),
                                       ('fixture-beta', 'Verification Beta')]]
            self.respond(200, rows if query.get('archived', ['false'])[0] == 'false' else [])
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            stamp = self.state.sort_initial.get(chat, '')
            rows = [] if not stamp else [dict(MsgID='SORT-' + chat, ChatJID=chat, Timestamp=stamp,
                                              Text='Synthetic last message', FromMe=chat == 'fixture-gamma',
                                              SenderName='Fixture Sender')]
            if chat == ALPHA and self.state.live:
                rows.insert(0, dict(MsgID='SORT-LIVE', ChatJID=chat, Timestamp=self.state.sort_times[chat],
                                    Text='Synthetic Slack incoming', FromMe=False, SenderName='Fixture Sender'))
            if chat == 'fixture-gamma' and self.state.sort_times[chat] != stamp:
                rows.insert(0, dict(MsgID='SORT-SENT', ChatJID=chat, Timestamp=self.state.sort_times[chat],
                                    Text='Synthetic Slack outgoing', FromMe=True, SenderName='Fixture Sender'))
            self.respond(200, rows)
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        else:
            self.respond(404, {'error': 'unknown sort path'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/fixture/live':
            with self.state.lock:
                self.state.sort_times[ALPHA] = self.state.stamp
                self.state.live = True
                self.state.lock.notify_all()
            self.respond(200, {'ok': True})
        elif self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/send' and body.get('chat') == 'fixture-gamma':
            stamp = (datetime.fromisoformat(self.state.stamp) + timedelta(seconds=1)).isoformat().replace('+00:00', 'Z')
            self.state.sort_times['fixture-gamma'] = stamp
            self.respond(200, dict(client_id=body['client_id'], msg_id='SORT-SENT', ts=stamp, status='sent'), body=body)
        else:
            self.respond(400, {'error': 'invalid sort request'}, body=body)


THREAD_CHAT = 'slack:fixture-threads:channel'
THREAD_PARENT = '1740000000.000100'


def thread_rows():
    rows = [dict(MsgID=THREAD_PARENT, Text='Synthetic thread parent', reply_count=30,
                 latest_reply='1740000030.000100')]
    rows.extend(dict(MsgID=f'17400000{index:02d}.000100', Text=f'Synthetic thread reply {index}',
                     thread_ts=THREAD_PARENT) for index in range(1, 31))
    rows.extend(dict(MsgID=f'17400000{index}.000100', Text='Synthetic channel message') for index in (31, 32))
    for index, row in enumerate(rows):
        row.update(ChatJID=THREAD_CHAT, Timestamp=f'2025-02-19T21:20:{index:02d}Z',
                   FromMe=False, SenderName='Fixture Sender')
    return list(reversed(rows))


class SlackThreadsHandler(SlackSortHandler):
    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            self.respond(200, [] if query.get('archived') == ['true'] else [
                dict(jid=THREAD_CHAT, name='Verification Threads', provider='slack', account='fixture-threads',
                     kind='group', last_message_ts='2025-02-19T21:20:32Z', unread_count=0, archived=False)])
        elif url.path == '/v1/wazig/messages' and query.get('chat') == [THREAD_CHAT]:
            self.respond(200, thread_rows())
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/v1/wazig/mark-read' and body.get('chat') == THREAD_CHAT:
            self.respond(200, {'status': 'ok'}, body=body)
        elif (self.path == '/v1/wazig/send' and body.get('chat') == THREAD_CHAT
              and body.get('reply_to') == THREAD_PARENT and body.get('text') == 'Synthetic thread reply'
              and body.get('client_id')):
            self.respond(200, dict(client_id=body['client_id'], msg_id='1740000040.000100',
                                   ts=self.state.stamp, status='sent'), body=body)
        else:
            self.respond(400, {'error': 'invalid thread request'}, body=body)


VIEW_ACCOUNTS = [
    ('slack', 'T0ABC123', 'Alpha Workspace'),
    ('whatsapp', 'personal', ''),
    ('slack', 'T0DEF456', 'Beta Workspace'),
    ('whatsapp', 'business', ''),
]


def view_account(row):
    parts = row['jid'].split(':')
    return parts[1] if row['provider'] == 'slack' else parts[0]


def view_rows():
    rows = []
    for index, (provider, account, name) in enumerate(VIEW_ACCOUNTS):
        for contact in range(2):
            stamp = datetime(2026, 1, 1, 0, index * 2 + contact, tzinfo=timezone.utc)
            jid = f'slack:{account}:C{contact:010d}' if provider == 'slack' else f'{account}:{contact:010d}@s.whatsapp.net'
            rows.append(dict(jid=jid, provider=provider, name='Verification Shared' if contact == 0 else 'Verification Other',
                             kind='direct', last_message_ts=stamp.isoformat().replace('+00:00', 'Z'),
                             unread_count=0, archived=False))
            if provider == 'slack':
                rows[-1]['team_name'] = name
    return rows


class ViewsHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            with self.state.lock:
                rows = json.loads(json.dumps(self.state.view_rows))
            self.respond(200, [row for row in rows if row['archived'] == (query.get('archived') == ['true'])])
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            row = next((row for row in self.state.view_rows if row['jid'] == chat), None)
            if row is None:
                self.respond(404, {'error': 'unknown fixture chat'})
                return
            with self.state.lock:
                rows = [dict(MsgID=f'baseline-{chat}', ChatJID=chat, Timestamp=row['last_message_ts'],
                             Text=f'History {view_account(row)}', FromMe=False, SenderName='Verification Shared')]
                rows.extend(dict(MsgID=reply['msg_id'], ChatJID=chat, Timestamp=reply['ts'],
                                 Text=reply['text'], FromMe=True, SenderName='Verification Sender')
                            for reply in self.state.sends.values() if reply['chat'] == chat)
            self.respond(200, rows)
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        else:
            self.respond(404, {'error': 'unknown fixture route'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        row = next((row for row in self.state.view_rows if row['jid'] == body.get('chat')), None)
        if row is None:
            self.respond(400, {'error': 'unknown fixture chat'}, body=body)
            return
        scope = dict(source_provider=row['provider'], source_account=view_account(row))
        if self.path == '/v1/wazig/send':
            if set(body) != {'chat', 'text', 'reply_to', 'client_id'} or not body['client_id']:
                self.respond(400, {'error': 'invalid send'}, body=body)
                return
            with self.state.lock:
                duplicate = body['client_id'] in self.state.sends
                if not duplicate:
                    self.state.sends[body['client_id']] = dict(client_id=body['client_id'], msg_id='views-sent',
                        ts=self.state.stamp, status='sent', chat=body['chat'], text=body['text'])
                    row['last_message_ts'] = self.state.stamp
                reply = dict(self.state.sends[body['client_id']])
            self.respond(200, reply, body=body, accepted=not duplicate, duplicate=duplicate, **scope)
        elif self.path == '/v1/wazig/archive' and set(body) == {'chat', 'archived'} and isinstance(body['archived'], bool) and row['provider'] == 'whatsapp':
            with self.state.lock:
                row['archived'] = body['archived']
            self.respond(200, {'status': 'ok'}, body=body, **scope)
        elif self.path == '/v1/wazig/mark-read' and set(body) == {'chat', 'message_id'}:
            self.respond(200, {'status': 'ok'}, body=body, **scope)
        else:
            self.respond(400, {'error': 'unexpected fixture write'}, body=body, **scope)


class WorkspaceIconsHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            rows = [dict(jid=chat, name=name, provider=provider, kind='direct',
                         last_message_ts=self.state.stamp, unread_count=0, archived=False)
                    for chat, name, provider in WORKSPACE_CHATS]
            self.respond(200, rows if query.get('archived', ['false'])[0] == 'false' else [])
        elif url.path in ('/v1/wazig/messages', '/v1/wazig/groups'):
            self.respond(200, [])
        elif url.path.startswith('/v1/wazig/workspace-icon/'):
            self.workspace_icon(url.path)
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        elif url.path == '/v1/wazig/events':
            self.events()
        else:
            self.respond(404, {'error': 'unknown workspace fixture path'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/v1/wazig/mark-read' and body.get('chat') in [row[0] for row in WORKSPACE_CHATS]:
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected workspace fixture write'}, body=body)


SIGNAL_CHAT = 'signal:fixture-contact'
SIGNAL_LIMITED = 'signal:fixture-limited'
SIGNAL_CAPTCHA = 'signal:fixture-captcha'


class SignalHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def event(self, event_id, kind, chat):
        data = dict(id=event_id, chat=SIGNAL_CHAT if chat else '', ts=self.state.stamp, kind=kind)
        self.wfile.write(f'id: {event_id}\ndata: {json.dumps(data)}\n\n'.encode())
        self.wfile.flush()
        self.state.record(dict(method='SSE', path='/v1/wazig/events', wire_path=self.wire_path, **data))

    def events(self):
        self.record(200)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        last = int(self.headers.get('Last-Event-ID', '0'))
        if last == 0:
            self.event(1, 'reset', '')
            self.close_connection = True
            return
        while True:
            with self.state.lock:
                pending = [(index + 2, event) for index, event in enumerate(self.state.signal_events) if index + 2 > last]
                if not pending:
                    self.state.lock.wait(timeout=2)
            if pending:
                for event_id, (kind, chat) in pending:
                    self.event(event_id, kind, chat)
                self.close_connection = True
                return
            self.wfile.write(b': heartbeat\n\n')
            self.wfile.flush()

    def publish(self, kind, chat=SIGNAL_CHAT):
        with self.state.lock:
            self.state.signal_events.append((kind, chat))
            self.state.lock.notify_all()

    def message(self, chat, message_id, text, **extra):
        return dict(MsgID=message_id, ChatJID=chat, Text=text, DisplayText=text,
                    Timestamp=self.state.stamp, SenderJID='fixture-sender', SenderName='Fixture Sender',
                    FromMe=extra.pop('FromMe', False), **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            rows = []
            if query.get('archived', ['false'])[0] == 'false':
                rows = [dict(provider='signal', jid=chat, name=name, kind=kind,
                             last_message_ts=self.state.stamp, unread_count=0 if chat in self.state.signal_read else 1,
                             unread=chat not in self.state.signal_read, archived=False)
                        for chat, name, kind in [(SIGNAL_CHAT, 'Verification Signal', 'direct'),
                                                 (SIGNAL_LIMITED, 'Verification Limited', 'direct'),
                                                 (SIGNAL_CAPTCHA, 'Verification Captcha', 'direct'),
                                                 ('signal:group:fixture-group', 'Verification Group', 'group')]]
            self.respond(200, rows)
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            rows = [self.message(chat, 'fixture-sender:1000', 'Synthetic Signal history')]
            if chat == SIGNAL_CHAT:
                rows.append(self.message(chat, 'fixture-sender:1001', 'Synthetic Signal attachment',
                                         MediaType='image', MimeType='image/png', Filename='fixture.png'))
                if self.state.live:
                    rows.append(self.message(chat, 'fixture-sender:1002', 'Synthetic Signal live'))
                with self.state.lock:
                    rows.extend(dict(self.message(chat, reply['msg_id'], reply['text']), FromMe=True,
                                     **({'MediaType': 'image', 'Filename': 'fixture.png', 'MimeType': 'image/png'} if reply['file'] else {}))
                                for reply in self.state.sends.values() if reply['chat'] == chat)
                    if self.state.signal_reaction:
                        rows.append(self.message(chat, 'fixture-reaction:1003', '',
                                                 ReactionToID=self.state.signal_reaction['msg'],
                                                 ReactionEmoji=self.state.signal_reaction['emoji']))
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/media/'):
            self.respond(200, self.state.image, 'image/png')
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        else:
            self.respond(404, {'error': 'unknown signal route'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        payload = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        multipart = self.headers.get('Content-Type', '').startswith('multipart/form-data')
        file_bytes = b''
        if multipart:
            envelope = bridge.BytesParser(policy=bridge.policy.default).parsebytes(
                f'Content-Type: {self.headers["Content-Type"]}\r\nMIME-Version: 1.0\r\n\r\n'.encode() + payload)
            body = {}
            for part in envelope.iter_parts():
                name = part.get_param('name', header='content-disposition')
                if part.get_filename() is None:
                    body[name] = part.get_content()
                else:
                    body[name] = part.get_filename()
                    file_bytes = part.get_payload(decode=True)
        else:
            body = json.loads(payload or '{}')
        if self.path == '/fixture/live':
            with self.state.lock:
                self.state.live = True
                self.state.lock.notify_all()
            self.publish('msg')
            self.respond(200, {'ok': True}, body=body)
            return
        chat = body.get('chat', '')
        if not chat.startswith('signal:'):
            self.respond(400, {'error': 'invalid Signal chat'}, body=body)
        elif self.path == '/v1/wazig/send':
            if chat == SIGNAL_LIMITED:
                self.respond(429, {'error': 'signal rate limited', 'retry_after': 30}, body=body)
                return
            if chat == SIGNAL_CAPTCHA:
                self.respond(403, {'error': 'signal captcha required'}, body=body)
                return
            expected = {'chat', 'text', 'reply_to', 'client_id'} if not multipart else {'chat', 'text', 'file', 'client_id'}
            if not expected.issubset(body) or not body['client_id'] or (multipart and not file_bytes):
                self.respond(400, {'error': 'invalid Signal send'}, body=body)
                return
            with self.state.lock:
                duplicate = body['client_id'] in self.state.sends
                if not duplicate:
                    self.state.sends[body['client_id']] = dict(client_id=body['client_id'],
                        msg_id=f'fixture-self:{2000 + len(self.state.sends)}', ts=self.state.stamp,
                        status='sent', chat=chat, text=body['text'], file=multipart)
                reply = self.state.sends[body['client_id']]
            self.respond(200, reply, body=body, multipart=multipart, file_size=len(file_bytes),
                         file_sha256=bridge.hashlib.sha256(file_bytes).hexdigest(), accepted=not duplicate)
        elif self.path == '/v1/wazig/react' and set(body) == {'chat', 'msg', 'emoji', 'client_id'}:
            self.state.signal_reaction = body
            self.publish('reaction', chat)
            self.respond(200, dict(client_id=body['client_id'], msg_id='fixture-reaction:1003',
                                   ts=self.state.stamp, status='sent'), body=body)
        elif self.path == '/v1/wazig/mark-read' and set(body) == {'chat', 'message_id'}:
            self.state.signal_read.add(chat)
            self.publish('read', chat)
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/archive':
            self.respond(502, {'error': 'Signal archive unsupported'}, body=body)
        else:
            self.respond(400, {'error': 'invalid Signal write'}, body=body)


TELEGRAM_CHAT = 'telegram:user:1001'
TELEGRAM_LIMITED = 'telegram:user:1002'
TELEGRAM_SAVED = 'telegram:user:9001'
TELEGRAM_AVATAR_COLOURS = {TELEGRAM_CHAT: (232, 64, 128), 'telegram:chat:2001': (112, 208, 64)}


def telegram_avatar_png(chat):
    colour = bytes(TELEGRAM_AVATAR_COLOURS[chat])
    pixels = (b'\x00' + colour * 64) * 64

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


class TelegramHandler(Handler):
    def end_headers(self):
        if hasattr(self, 'telegram_retry_after'):
            self.send_header('Retry-After', str(self.telegram_retry_after))
        super().end_headers()

    def respond(self, status, data, content_type='application/json', **extra):
        if status == 429:
            self.telegram_retry_after = data['retry_after']
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def event(self, event_id, kind, chat):
        data = dict(id=event_id, chat=chat, ts=self.state.stamp, kind=kind)
        self.wfile.write(f'id: {event_id}\ndata: {json.dumps(data)}\n\n'.encode())
        self.wfile.flush()
        self.state.record(dict(method='SSE', path='/v1/wazig/events', wire_path=self.wire_path, **data))

    def events(self):
        self.record(200)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        last = int(self.headers.get('Last-Event-ID', '0'))
        if last == 0:
            self.event(1, 'reset', '')
            self.close_connection = True
            return
        while True:
            with self.state.lock:
                pending = [(index + 2, event) for index, event in enumerate(self.state.telegram_events) if index + 2 > last]
                if not pending:
                    self.state.lock.wait(timeout=2)
            if pending:
                for event_id, (kind, chat) in pending:
                    self.event(event_id, kind, chat)
                self.close_connection = True
                return
            self.wfile.write(b': heartbeat\n\n')
            self.wfile.flush()

    def publish(self, kind, chat=TELEGRAM_CHAT):
        with self.state.lock:
            self.state.telegram_events.append((kind, chat))
            self.state.lock.notify_all()

    def message(self, chat, message_id, text, **extra):
        return dict(MsgID=message_id, ChatJID=chat, Text=text, DisplayText=text,
                    Timestamp=self.state.stamp, SenderJID='telegram:user:1001', SenderName='Fixture Sender',
                    FromMe=extra.pop('FromMe', False), **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            rows = []
            if query.get('archived', ['false'])[0] == 'false':
                rows = [dict(provider='telegram', jid=chat, name=name, kind=kind,
                             last_message_ts=self.state.stamp, unread_count=0 if chat in self.state.telegram_read else 1,
                             unread=chat not in self.state.telegram_read, archived=False, saved=chat == TELEGRAM_SAVED)
                        for chat, name, kind in [(TELEGRAM_CHAT, 'Verification Telegram', 'direct'),
                                                 (TELEGRAM_LIMITED, 'Verification Limited', 'direct'),
                                                 (TELEGRAM_SAVED, 'Saved Messages', 'direct'),
                                                 ('telegram:chat:2001', 'Verification Group', 'group'),
                                                 ('telegram:channel:3001', 'Verification Channel', 'group')]]
            self.respond(200, rows)
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            rows = [self.message(chat, '1000', 'Synthetic Telegram history')]
            if chat == TELEGRAM_CHAT:
                rows.append(self.message(chat, '1001', 'Synthetic Telegram attachment',
                                         MediaType='image', MimeType='image/png', Filename='fixture.png'))
                if self.state.live:
                    rows.append(self.message(chat, '1002', 'Synthetic Telegram live'))
                with self.state.lock:
                    rows.extend(dict(self.message(chat, reply['msg_id'], reply['text']), FromMe=True,
                                     quoted_msg_id=reply['reply_to'],
                                     **({'MediaType': 'image', 'Filename': 'fixture.png', 'MimeType': 'image/png'} if reply['file'] else {}))
                                for reply in self.state.sends.values() if reply['chat'] == chat)
                    if self.state.telegram_reaction:
                        rows.append(self.message(chat, '1003', '',
                                                 ReactionToID=self.state.telegram_reaction['msg'],
                                                 ReactionEmoji=self.state.telegram_reaction['emoji']))
            before = query.get('before', [''])[0]
            if before:
                message_id = before.split(':', 1)[0]
                rows = [row for row in rows if int(row['MsgID']) < int(message_id)] if message_id.isdecimal() else [row for row in rows if row['Timestamp'] < before]
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/media/'):
            self.respond(200, self.state.image, 'image/png')
        elif url.path.startswith('/v1/wazig/avatar/'):
            chat = unquote(url.path.removeprefix('/v1/wazig/avatar/'))
            if chat in TELEGRAM_AVATAR_COLOURS:
                image = telegram_avatar_png(chat)
                self.respond(200, image, 'image/png', sha256=hashlib.sha256(image).hexdigest())
            else:
                self.respond(404, {'error': 'no avatar'})
        else:
            self.respond(404, {'error': 'unknown telegram route'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        payload = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        multipart = self.headers.get('Content-Type', '').startswith('multipart/form-data')
        file_bytes = b''
        if multipart:
            envelope = bridge.BytesParser(policy=bridge.policy.default).parsebytes(
                f'Content-Type: {self.headers["Content-Type"]}\r\nMIME-Version: 1.0\r\n\r\n'.encode() + payload)
            body = {}
            for part in envelope.iter_parts():
                name = part.get_param('name', header='content-disposition')
                if part.get_filename() is None:
                    body[name] = part.get_content()
                else:
                    body[name] = part.get_filename()
                    file_bytes = part.get_payload(decode=True)
        else:
            body = json.loads(payload or '{}')
        if self.path == '/fixture/live':
            with self.state.lock:
                self.state.live = True
                self.state.lock.notify_all()
            self.publish('message')
            self.respond(200, {'ok': True}, body=body)
            return
        chat = body.get('chat', '')
        if not chat.startswith('telegram:'):
            self.respond(400, {'error': 'invalid Telegram chat'}, body=body)
        elif self.path == '/v1/wazig/send':
            if chat == TELEGRAM_LIMITED:
                self.respond(429, {'error': 'telegram rate limited', 'retry_after': 30}, body=body)
                return
            expected = {'chat', 'text', 'reply_to', 'client_id'} if not multipart else {'chat', 'text', 'file', 'client_id'}
            if not expected.issubset(body) or not body['client_id'] or (multipart and not file_bytes):
                self.respond(400, {'error': 'invalid Telegram send'}, body=body)
                return
            with self.state.lock:
                duplicate = body['client_id'] in self.state.sends
                if not duplicate:
                    self.state.sends[body['client_id']] = dict(client_id=body['client_id'],
                        msg_id=str(2000 + len(self.state.sends)), ts=self.state.stamp,
                        status='sent', chat=chat, text=body['text'], file=multipart, reply_to=body.get('reply_to', ''))
                reply = self.state.sends[body['client_id']]
            self.respond(200, reply, body=body, multipart=multipart, file_size=len(file_bytes),
                         file_sha256=bridge.hashlib.sha256(file_bytes).hexdigest(), accepted=not duplicate)
        elif self.path == '/v1/wazig/react' and set(body) == {'chat', 'msg', 'emoji', 'client_id'}:
            self.state.telegram_reaction = body
            self.publish('reaction', chat)
            self.respond(200, dict(client_id=body['client_id'], msg_id='1003',
                                   ts=self.state.stamp, status='sent'), body=body)
        elif self.path == '/v1/wazig/mark-read' and set(body) == {'chat', 'message_id'}:
            self.state.telegram_read.add(chat)
            self.publish('read', chat)
            self.respond(200, {'status': 'ok'}, body=body)
        elif self.path == '/v1/wazig/archive':
            self.respond(502, {'error': 'Telegram archive unsupported'}, body=body)
        else:
            self.respond(400, {'error': 'invalid Telegram write'}, body=body)


class RepaintHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        state = self.state
        if url.path == '/v1/wazig/chats':
            with state.lock:
                count = state.repaint_count
                stamp = state.repaint_stamp
            rows = [] if parse_qs(url.query).get('archived') == ['true'] else [
                dict(jid=ALPHA, name='Verification Alpha', provider='slack', kind='direct',
                     last_message_ts=state.stamp, unread_count=0, archived=False),
                dict(jid=BETA, name='Verification Beta', provider='whatsapp', kind='direct',
                     last_message_ts=stamp, unread_count=count, archived=False)]
            self.respond(200, rows, incoming=count)
        elif url.path == '/v1/wazig/messages':
            chat = parse_qs(url.query).get('chat', [''])[0]
            with state.lock:
                count = state.repaint_count if chat == BETA else 0
            rows = [dict(MsgID='BASELINE', ChatJID=chat, Timestamp=state.stamp,
                         Text='Synthetic baseline', FromMe=False, SenderName='Fixture Sender')]
            rows.extend(dict(MsgID=f'INCOMING-{n}', ChatJID=chat, Timestamp=(datetime.fromisoformat(state.stamp) + timedelta(seconds=n * 10)).isoformat().replace('+00:00', 'Z'),
                             Text=f'Synthetic incoming {n}', FromMe=False, SenderName='Fixture Sender')
                        for n in range(1, count + 1))
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/fixture/repaint':
            with state.lock:
                self.respond(200, dict(incoming=state.repaint_count, ticks=state.repaint_ticks))
        elif url.path.startswith('/v1/wazig/avatar/'):
            self.respond(404, {'error': 'unavailable'})
        else:
            self.respond(404, {'error': 'unknown repaint fixture route'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/fixture/repaint/start':
            with self.state.lock:
                if self.state.repaint_started:
                    self.respond(409, {'error': 'already started'})
                    return
                self.state.repaint_started = True
            bridge.threading.Thread(target=self.produce_updates, daemon=True).start()
            self.respond(200, {'ok': True})
        elif self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected repaint write'}, body=body)

    def produce_updates(self):
        state = self.state
        started = bridge.time.monotonic()
        for tick in range(1, 31):
            with state.lock:
                state.lock.wait_for(lambda: bridge.time.monotonic() >= started + tick * 2,
                                    timeout=max(0, started + tick * 2 - bridge.time.monotonic()))
                state.repaint_ticks = tick
                if tick % 5 == 0:
                    state.repaint_count += 1
                    state.repaint_stamp = (datetime.fromisoformat(state.stamp) + timedelta(seconds=tick * 2)).isoformat().replace('+00:00', 'Z')
                    state.repaint_events.append(('msg', BETA))
                state.repaint_events.append(('reset', ''))
                state.lock.notify_all()

    def events(self):
        self.record(200)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        last = int(self.headers.get('Last-Event-ID', '0'))
        try:
            if last == 0:
                self.event(1, 'reset', '')
                self.close_connection = True
                return
            while True:
                with self.state.lock:
                    pending = [(i + 1, event) for i, event in enumerate(self.state.repaint_events) if i + 1 > last]
                    if not pending:
                        self.state.lock.wait(timeout=2)
                if pending:
                    for event_id, (kind, chat) in pending:
                        self.event(event_id, kind, chat)
                    self.close_connection = True
                    return
                self.wfile.write(b': heartbeat\n\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True


MEDIA_GROUP = 'fixture-media@g.us'
MEDIA_COLOURS = {'landscape': (32, 176, 208), 'portrait': (176, 64, 208)}


def media_fit_png(width, height, colour):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = (b'\x00' + bytes(colour) * width) * height
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


class MediaFitHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        if url.path == '/v1/wazig/chats':
            self.respond(200, [dict(jid=MEDIA_GROUP, name='Verification Media', provider='whatsapp', kind='group',
                                    last_message_ts=self.state.stamp, unread_count=0, archived=False)])
        elif url.path == '/v1/wazig/messages':
            rows = [dict(MsgID=key, ChatJID=MEDIA_GROUP, Timestamp=self.state.stamp, Text='', FromMe=False,
                         SenderJID='fixture-media-sender', SenderName='Fixture Sender', MediaType=kind,
                         MimeType=mime, Filename=key + extension)
                    for key, (data, mime, extension, kind) in self.state.fit_media.items()]
            rows.append(dict(MsgID='fit-own', ChatJID=MEDIA_GROUP, Timestamp=self.state.stamp,
                             Text=self.state.fit_text, FromMe=True, SenderName='', SenderJID='fixture-own'))
            self.respond(200, list(reversed(rows)))
        elif url.path.startswith('/v1/wazig/media/'):
            chat, message = map(unquote, url.path.removeprefix('/v1/wazig/media/').split('/', 1))
            if chat != MEDIA_GROUP or message not in self.state.fit_media:
                self.respond(404, {'error': 'unknown media'})
                return
            data, mime, extension, kind = self.state.fit_media[message]
            self.respond(200, data, mime, sha256=hashlib.sha256(data).hexdigest())
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        elif url.path == '/v1/wazig/events':
            VoiceHandler.events(self)
        else:
            self.respond(404, {'error': 'unavailable'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/fixture/media-fit-text':
            self.state.fit_text = body['text']
            self.respond(200, {'text': self.state.fit_text}, body=body)
        elif self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected media-fit write'}, body=body)


VOICE_NOTES = 5
VOICE_BYTES = b'OggS' + bytes(range(256)) * 8


class VoiceHandler(Handler):
    def respond(self, status, data, content_type='application/json', **extra):
        bridge.Handler.respond(self, status, data, content_type, **extra)

    def stamp(self, offset):
        return (datetime.fromisoformat(self.state.stamp) + timedelta(seconds=offset)).isoformat().replace('+00:00', 'Z')

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            rows = [] if query.get('archived') == ['true'] else [
                dict(jid=ALPHA, name='Verification Voice', provider='whatsapp', kind='direct',
                     last_message_ts=self.stamp(VOICE_NOTES * 60), unread_count=0, archived=False),
                dict(jid=BETA, name='Verification Beta', provider='whatsapp', kind='direct',
                     last_message_ts=self.stamp(0), unread_count=0, archived=False)]
            self.respond(200, rows)
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            if chat == ALPHA:
                rows = [dict(MsgID=f'VOICE-{n}', ChatJID=chat, Timestamp=self.stamp(n * 60), Text='', FromMe=False,
                             SenderJID='fixture-voice-sender', SenderName='Fixture Voice', MediaType='audio',
                             MimeType='audio/ogg', Filename=f'voice-{n}.ogg')
                        for n in range(1, VOICE_NOTES + 1)]
            else:
                rows = [dict(MsgID='VOICE-BETA', ChatJID=chat, Timestamp=self.stamp(0), Text='Synthetic text',
                             FromMe=False, SenderName='Fixture Sender')]
            self.respond(200, list(reversed(rows)))
        elif url.path.startswith('/v1/wazig/media/'):
            chat, message = map(unquote, url.path.removeprefix('/v1/wazig/media/').split('/', 1))
            if chat == ALPHA and message.startswith('VOICE-'):
                self.respond(200, VOICE_BYTES, 'audio/ogg', sha256=hashlib.sha256(VOICE_BYTES).hexdigest())
            else:
                self.respond(404, {'error': 'unknown voice note'})
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected voice write'}, body=body)

    def events(self):
        self.record(200)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        last = int(self.headers.get('Last-Event-ID', '0'))
        try:
            if last == 0:
                self.event(1, 'reset', '')
                self.close_connection = True
                return
            while True:
                bridge.time.sleep(2)
                self.wfile.write(b': heartbeat\n\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True


class SlackArchiveHandler(SlackSortHandler):
    def stamp(self, incoming):
        return (datetime.fromisoformat(self.state.stamp) + timedelta(seconds=incoming)).isoformat().replace('+00:00', 'Z')

    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        incoming = self.state.archive_incoming
        if url.path == '/v1/wazig/chats':
            archived = query.get('archived', ['false'])[0] == 'true'
            rows = [dict(jid=chat, name=name, provider='slack', kind='group' if chat == ALPHA else 'direct',
                         last_message_ts=self.stamp(incoming if chat == ALPHA else -1),
                         unread_count=incoming if chat == ALPHA else 0, unread=chat == ALPHA and incoming > 0,
                         archived=False)
                    for chat, name in [(ALPHA, 'Verification Alpha'), (BETA, 'Verification Beta')]]
            self.respond(200, [] if archived else rows, incoming=incoming, archived=archived, rows=[] if archived else rows)
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            rows = [dict(MsgID='ARCHIVE-BASELINE', ChatJID=chat, Timestamp=self.stamp(0),
                         Text='Synthetic Slack history', FromMe=False, SenderName='Fixture Sender')]
            if chat == ALPHA:
                rows.extend(dict(MsgID=f'ARCHIVE-INCOMING-{number}', ChatJID=chat, Timestamp=self.stamp(number),
                                 Text=f'Synthetic Slack incoming {number}', FromMe=False, SenderName='Fixture Sender')
                            for number in range(1, incoming + 1))
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})

    def event(self, event_id, kind, incoming):
        data = dict(id=event_id, kind=kind, chat=ALPHA if incoming else '', ts=self.stamp(incoming))
        self.wfile.write(f'id: {event_id}\ndata: {json.dumps(data)}\n\n'.encode())
        self.wfile.flush()
        self.state.record(dict(method='SSE', path='/v1/wazig/events', wire_path=self.wire_path,
                               incoming=incoming, **data))

    def events(self):
        self.record(200)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        last = int(self.headers.get('Last-Event-ID', '0'))
        if last == 0:
            self.event(1, 'reset', 0)
            self.close_connection = True
            return
        while True:
            with self.state.lock:
                incoming = self.state.archive_incoming
                if incoming + 1 <= last:
                    self.state.lock.wait(timeout=2)
            for number in range(max(1, last), incoming + 1):
                self.event(number + 1, 'msg', number)
                last = number + 1
            self.wfile.write(b': heartbeat\n\n')
            self.wfile.flush()

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if self.path == '/fixture/live':
            with self.state.lock:
                self.state.archive_incoming += 1
                incoming = self.state.archive_incoming
                self.state.lock.notify_all()
            self.respond(200, {'ok': True}, body=body, incoming=incoming, chat=ALPHA)
        elif self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        else:
            self.respond(400, {'error': 'unexpected Slack write'}, body=body)


class PasteImageHandler(TelegramHandler):
    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            self.respond(200, [] if query.get('archived') == ['true'] else [
                dict(jid='paste:' + provider, provider=provider, name='Verification Paste ' + provider,
                     kind='direct', last_message_ts=self.state.stamp, unread_count=0, archived=False)
                for provider in ('whatsapp', 'slack', 'signal', 'telegram')])
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            with self.state.lock:
                rows = [self.message(chat, reply['msg_id'], reply['text'], FromMe=True, MediaType='image',
                                     MimeType='image/png', Filename=reply['filename'])
                        for reply in self.state.sends.values() if reply['chat'] == chat]
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path.startswith('/v1/wazig/media/'):
            chat, message = map(unquote, url.path.removeprefix('/v1/wazig/media/').split('/', 1))
            with self.state.lock:
                reply = next((row for row in self.state.sends.values()
                              if row['chat'] == chat and row['msg_id'] == message), None)
            if reply:
                self.respond(200, (self.state.log.parent / reply['upload']).read_bytes(), 'image/png')
            else:
                self.respond(404, {'error': 'unknown image'})
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})

    def do_POST(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        payload = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        multipart = self.headers.get('Content-Type', '').startswith('multipart/form-data')
        body, image = {}, b''
        if multipart:
            envelope = bridge.BytesParser(policy=bridge.policy.default).parsebytes(
                f'Content-Type: {self.headers["Content-Type"]}\r\nMIME-Version: 1.0\r\n\r\n'.encode() + payload)
            for part in envelope.iter_parts():
                name = part.get_param('name', header='content-disposition')
                if part.get_filename() is None:
                    body[name] = part.get_content()
                else:
                    body[name] = part.get_filename()
                    image = part.get_payload(decode=True)
        else:
            body = json.loads(payload or '{}')
        if body.get('chat') not in {'paste:' + provider for provider in ('whatsapp', 'slack', 'signal', 'telegram')}:
            self.respond(400, {'error': 'invalid paste chat'}, body=body)
        elif self.path == '/v1/wazig/mark-read':
            self.respond(200, {'status': 'ok'}, body=body)
        elif (self.path == '/v1/wazig/send' and multipart and image.startswith(b'\x89PNG\r\n\x1a\n')
              and {'chat', 'text', 'file', 'client_id'}.issubset(body) and body['client_id'].isalnum()):
            with self.state.lock:
                duplicate = body['client_id'] in self.state.sends
                if not duplicate:
                    upload = 'paste-uploads/' + body['client_id'] + '.png'
                    target = self.state.log.parent / upload
                    target.parent.mkdir(exist_ok=True)
                    target.write_bytes(image)
                    self.state.sends[body['client_id']] = dict(client_id=body['client_id'],
                        msg_id=f'paste-{len(self.state.sends) + 1}', ts=self.state.stamp, status='sent',
                        chat=body['chat'], text=body['text'], filename=body['file'], upload=upload)
                    self.state.telegram_events.append(('msg', body['chat']))
                    self.state.lock.notify_all()
                reply = dict(self.state.sends[body['client_id']])
            self.respond(200, reply, body=body, multipart=True, accepted=not duplicate,
                         file_size=len(image), file_sha256=hashlib.sha256(image).hexdigest(),
                         upload=reply['upload'], message_id=reply['msg_id'])
        else:
            self.respond(400, {'error': 'paste-image requires an image upload'}, body=body)


LINK_CHATS = [('slack:fixture-links:channel', 'slack'), ('whatsapp:fixture-links', 'whatsapp'),
              ('telegram:user:7004', 'telegram'), ('signal:fixture-links', 'signal')]


class LinkPreviewsHandler(VoiceHandler):
    def do_GET(self):
        self.wire_path = self.path
        url = urlsplit(self.path)
        origin = f'http://127.0.0.1:{self.server.server_port}'
        if url.path in ('/pic.png', '/card.png'):
            team = 'fixture-amber' if url.path == '/pic.png' else 'fixture-cobalt'
            self.respond(200, workspace_png(team), 'image/png')
            return
        if url.path in ('/page', '/plain', '/query'):
            meta = ('<meta property="og:title" content="Synthetic preview">'
                    '<meta property="og:description" content="Synthetic description">'
                    f'<meta property="og:image" content="{origin}/missing.png">'
                    f'<meta property="og:image:secure_url" content="{origin}/card.png">') if url.path == '/page' else ''
            self.respond(200, f'<html><head>{meta}</head><body>Synthetic page</body></html>'.encode(), 'text/html')
            return
        if not self.authorized():
            return
        query = parse_qs(url.query)
        if url.path == '/v1/wazig/chats':
            self.respond(200, [] if query.get('archived') == ['true'] else [
                dict(jid=chat, name='Verification Links ' + provider, provider=provider, kind='direct',
                     last_message_ts=self.state.stamp, unread_count=0, archived=False)
                for chat, provider in LINK_CHATS])
        elif url.path == '/v1/wazig/messages':
            chat = query.get('chat', [''])[0]
            provider = next((provider for jid, provider in LINK_CHATS if jid == chat), '')
            paths = [('IMAGE', '/pic.png', origin.removeprefix('http://') + '/pic.png'),
                     ('PAGE', '/page', 'Synthetic page label'),
                     ('QUERY', '/query?a=1&b=2', ''), ('PLAIN', '/plain', 'Clean page label')]
            rows = []
            for index, (message, path, label) in enumerate(paths):
                link = origin + path
                text = ('<' + link.replace('&', '&amp;') + ('|' + label if label else '') + '>') if provider == 'slack' else link
                rows.append(dict(MsgID='LINK-' + message, ChatJID=chat, Timestamp=self.stamp(index),
                                 Text=text, DisplayText=text, FromMe=False, SenderName='Fixture Sender'))
                if provider == 'slack' and message == 'QUERY':
                    rows[-1].update(DisplayText=f'> <{origin}/plain|Quoted &amp; label>\n{text}',
                                    quoted_msg_id='LINK-PLAIN', quoted_sender_jid='fixture-sender')
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})


SLACK_EMOJI_CHAT = 'slack:fixture-emoji:channel'


def emoji_gif():
    width, height = 96, 48
    result = bytearray(b'GIF89a' + struct.pack('<HH', width, height) + b'\x81\x00\x00')
    result.extend(bytes((240, 160, 32, 48, 112, 240, 0, 0, 0, 255, 255, 255)))
    result.extend(b'!\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00')
    for colour in (0, 1):
        codes = [value for _ in range(width * height) for value in (4, colour)] + [5]
        packed = bytearray()
        bits = count = 0
        for code in codes:
            bits |= code << count
            count += 3
            while count >= 8:
                packed.append(bits & 255)
                bits >>= 8
                count -= 8
        if count:
            packed.append(bits)
        result.extend(b'!\xf9\x04\x04\x0a\x00\x00\x00,')
        result.extend(struct.pack('<HHHH', 0, 0, width, height) + b'\x00\x02')
        for start in range(0, len(packed), 255):
            block = packed[start:start + 255]
            result.extend(bytes((len(block),)) + block)
        result.extend(b'\x00')
    return bytes(result + b';')


class SlackEmojiHandler(VoiceHandler):
    def do_GET(self):
        self.wire_path = self.path
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        origin = f'http://127.0.0.1:{self.server.server_port}'
        if url.path == '/v1/wazig/chats':
            self.respond(200, [] if query.get('archived') == ['true'] else [
                dict(jid=SLACK_EMOJI_CHAT, name='Verification Emoji', provider='slack', kind='channel',
                     account='fixture-emoji', last_message_ts=self.state.stamp, unread_count=0, archived=False),
                dict(jid='slack:fixture-emoji:other', name='Verification Other', provider='slack', kind='channel',
                     account='fixture-emoji', last_message_ts=self.stamp(-1), unread_count=0, archived=False)])
        elif url.path == '/v1/wazig/messages' and query.get('chat') == ['slack:fixture-emoji:other']:
            self.respond(200, [dict(MsgID='PLAIN', ChatJID='slack:fixture-emoji:other', Text='Synthetic plain text',
                                    Timestamp=self.state.stamp, FromMe=False, SenderName='Fixture Sender')])
        elif url.path == '/v1/wazig/messages' and query.get('chat') == [SLACK_EMOJI_CHAT]:
            rows = [
                dict(MsgID='EMOJI-STANDARD', Text=':broken_heart: :timer_clock::billed_cap: :crossed_fingers: :thumbsup::skin-tone-2: :unknown_fixture:',
                     reactions=[dict(name='crycat', count=2), dict(name='smiling_face_with_tear', count=1), dict(name='tea', count=1)]),
                dict(MsgID='EMOJI-CUSTOM', Text='Custom :cat_alone: alias :fixture_cat: :fixture_standard: :cycle_a:'),
                dict(MsgID='GIPHY', Text='Synthetic Giphy', attachments=[dict(service_name='Giphy',
                     image_url=origin + '/fixture/animation.gif', image_mimetype='image/gif')])]
            for index, row in enumerate(rows):
                row.update(ChatJID=SLACK_EMOJI_CHAT, Timestamp=self.stamp(index), FromMe=False, SenderName='Fixture Sender')
            self.respond(200, list(reversed(rows)))
        elif url.path == '/v1/wazig/slack/emoji' and query == {'account': ['fixture-emoji']}:
            self.respond(200, dict(emoji=dict(cat_alone='https://example.invalid/custom.png', crycat='alias:cat_alone',
                                              fixture_cat='alias:crycat', fixture_standard='alias:tea', cycle_a='alias:cycle_b', cycle_b='alias:cycle_a')))
        elif url.path == '/v1/wazig/slack/emoji/media' and query.get('account') == ['fixture-emoji'] and query.get('name') == ['cat_alone']:
            self.respond(200, workspace_png('fixture-amber'), 'image/png')
        elif url.path.startswith('/v1/wazig/media/') and list(map(unquote, url.path.removeprefix('/v1/wazig/media/').split('/', 1))) == [SLACK_EMOJI_CHAT, 'GIPHY']:
            self.respond(200, emoji_gif(), 'image/gif')
        elif url.path == '/v1/wazig/events':
            self.events()
        elif url.path == '/v1/wazig/groups':
            self.respond(200, [])
        else:
            self.respond(404, {'error': 'unavailable'})


def journey_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port-file', type=Path, required=True)
    parser.add_argument('--log', type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    registry = json.loads(Path(__file__).with_name('journeys.json').read_text(encoding='utf-8'))
    journeys = {row['hub']: row for row in registry['journeys'] if row['hub'] and row['hub'] != 'legacy'}
    for mode in journeys:
        modes.add_argument('--' + mode, dest='mode', action='store_const', const=mode)
    return parser, journeys


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise SystemExit('Fake hub runs only on GitHub Actions')
    parser, journeys = journey_parser()
    args = parser.parse_args()
    loopback = socket.inet_ntoa(struct.pack('!I', socket.INADDR_LOOPBACK))
    config = journeys[args.mode]['hub_handler'] if args.mode else {'file': 'fake-hub.py', 'class': 'Handler'}
    namespace = globals()
    if config['file'] != Path(__file__).name:
        import runpy
        namespace = runpy.run_path(str(Path(__file__).with_name(config['file'])), init_globals=namespace)
    handler = namespace[config['class']]
    server = ThreadingHTTPServer((loopback, 0), handler)
    server.daemon_threads = True
    server.state = bridge.State(args.log)
    server.state.archive_incoming = 0
    server.state.archive_group_archived = False
    server.state.archive_other_archived = False
    server.state.archive_rearchive_enabled = True
    server.state.plain_dms = {}
    server.state.view_rows = view_rows()
    server.state.archive_stamp = '2026-10-10T11:00:00Z'
    server.state.repaint_count = 0
    server.state.repaint_ticks = 0
    server.state.repaint_started = False
    server.state.repaint_stamp = (datetime.fromisoformat(server.state.stamp) - timedelta(seconds=1)).isoformat().replace('+00:00', 'Z')
    server.state.repaint_events = [('reset', '')]
    server.state.reactions = {}
    server.state.signal_reaction = None
    server.state.signal_events = []
    server.state.signal_read = set()
    server.state.telegram_reaction = None
    server.state.telegram_events = []
    server.state.telegram_read = set()
    if args.mode == 'media-fit':
        server.state.fit_text = 'M M M M M M M M'
        server.state.fit_media = {
            key: (media_fit_png(w, h, MEDIA_COLOURS[key]), 'image/png', '.png', 'image')
            for key, w, h in [('landscape', 1600, 1000), ('portrait', 700, 1400)]
        }
        ffmpeg = shutil.which('ffmpeg')
        if ffmpeg:
            video = args.log.with_name('media-fit.mp4')
            subprocess.run([ffmpeg, '-y', '-f', 'lavfi', '-i', 'color=c=orange:s=1512x1100:r=1',
                            '-frames:v', '1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(video)], check=True)
            server.state.fit_media['video'] = (video.read_bytes(), 'video/mp4', '.mp4', 'video')
        args.log.with_name('media-fit-fixture.json').write_text(json.dumps(dict(
            landscape=[1600, 1000], portrait=[700, 1400], video=bool(ffmpeg))), encoding='utf-8')
    if args.mode == 'slack-sort':
        stamp = datetime.fromisoformat(server.state.stamp)
        server.state.sort_times = {
            ALPHA: (stamp - timedelta(hours=3)).isoformat().replace('+00:00', 'Z'),
            BETA: (stamp - timedelta(hours=1)).isoformat().replace('+00:00', 'Z'),
            'fixture-gamma': (stamp - timedelta(hours=2)).isoformat().replace('+00:00', 'Z'),
            'fixture-unknown': '',
        }
        server.state.sort_initial = dict(server.state.sort_times)
    args.port_file.write_text(str(server.server_port), encoding='utf-8')
    server.serve_forever()


if __name__ == '__main__':
    main()
