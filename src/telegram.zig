//! Real Telegram client backed by the official TDLib td_json_client C API.
//! Compiled only when the build was given -Dtdlib=<dir>; otherwise
//! telegram_stub.zig provides the identical API. The receive thread owns all
//! TDLib receives; the UI thread only calls send-style requests (thread-safe
//! per TDLib) and drains parsed events through poll().

const std = @import("std");
const tj = @import("telegram_json.zig");

const c = struct {
    extern fn td_json_client_create() ?*anyopaque;
    extern fn td_json_client_send(client: *anyopaque, request: [*:0]const u8) void;
    extern fn td_json_client_receive(client: *anyopaque, timeout: f64) ?[*:0]const u8;
    extern fn td_json_client_execute(client: *anyopaque, request: [*:0]const u8) ?[*:0]const u8;
    extern fn td_json_client_destroy(client: *anyopaque) void;
};

pub const enabled = true;

pub const AuthState = tj.AuthState;
pub const MediaKind = tj.MediaKind;
pub const Event = tj.Event;
pub const Msg = tj.Msg;
pub const ChatInfo = tj.ChatInfo;

const max_queued_events = 512;
const max_history_per_chat = 200;
const max_tracked_chats = 128;

pub const Client = struct {
    allocator: std.mem.Allocator,
    client: *anyopaque,
    thread: ?std.Thread = null,
    queue_mutex: std.Thread.Mutex = .{},
    queue: std.ArrayList(Event) = .empty,
    dropped_events: u64 = 0,
    state_mutex: std.Thread.Mutex = .{},
    chats: std.AutoHashMap(i64, ChatInfo) = .empty,
    history: std.AutoHashMap(i64, std.ArrayList(Msg)) = .empty,
    auth: AuthState = .unknown,
    api_id: i32,
    api_hash: []u8,
    database_dir: []u8,
    files_dir: []u8,
    stopping: std.atomic.Value(bool) = .init(false),
    parameters_sent: bool = false,

    pub fn create(allocator: std.mem.Allocator, api_id: i32, api_hash: []const u8, base_dir: []const u8) ?*Client {
        const self = allocator.create(Client) catch return null;
        self.* = .{
            .allocator = allocator,
            .client = undefined,
            .api_id = api_id,
            .api_hash = allocator.dupe(u8, api_hash) catch {
                allocator.destroy(self);
                return null;
            },
            .database_dir = std.fmt.allocPrint(allocator, "{s}\\td", .{base_dir}) catch {
                allocator.free(api_hash);
                allocator.destroy(self);
                return null;
            },
            .files_dir = std.fmt.allocPrint(allocator, "{s}\\files", .{base_dir}) catch {
                allocator.destroy(self);
                return null;
            },
        };
        std.fs.cwd().makePath(self.database_dir) catch {};
        std.fs.cwd().makePath(self.files_dir) catch {};
        const raw = c.td_json_client_create() orelse {
            self.destroy();
            return null;
        };
        self.client = raw;
        self.thread = std.Thread.spawn(.{}, receiveLoop, .{self}) catch null;
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.stopping.store(true, .release);
        self.sendClose();
        if (self.thread) |thread| thread.join();
        self.queue.deinit(self.allocator);
        var chat_iterator = self.chats.iterator();
        while (chat_iterator.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.chats.deinit(self.allocator);
        var history_iterator = self.history.iterator();
        while (history_iterator.next()) |entry| {
            for (entry.value_ptr.items) |*msg| msg.deinit(self.allocator);
            entry.value_ptr.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.api_hash);
        self.allocator.free(self.database_dir);
        self.allocator.free(self.files_dir);
        self.allocator.destroy(self);
    }

    /// Returns one queued event, or null. The caller owns the event and must
    /// call event.deinit(allocator).
    pub fn poll(self: *Client) ?Event {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.queue.items.len == 0) return null;
        const event = self.queue.orderedRemove(0);
        return event;
    }

    pub fn authState(self: *Client) AuthState {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.auth;
    }

    pub fn authPhone(self: *Client, phone: []const u8) void {
        self.sendObject(.{ .type = "setAuthenticationPhoneNumber", .phone_number = phone, .allow_flash_call = false, .is_current_phone_number = true });
    }

    pub fn authCode(self: *Client, code: []const u8) void {
        self.sendObject(.{ .type = "checkAuthenticationCode", .code = code });
    }

    pub fn authPassword(self: *Client, password: []const u8) void {
        self.sendObject(.{ .type = "checkAuthenticationPassword", .password = password });
    }

    pub fn requestChats(self: *Client) void {
        self.sendObject(.{ .type = "getChats", .limit = 100 });
    }

    pub fn requestHistory(self: *Client, chat_id: i64) void {
        self.sendObject(.{ .type = "getChatHistory", .chat_id = chat_id, .limit = max_history_per_chat });
    }

    pub fn sendText(self: *Client, chat_id: i64, text: []const u8) bool {
        // Read-only guard for Telegram groups: the UI disables the composer,
        // but every send path funnels through here as the second gate.
        self.state_mutex.lock();
        const info = self.chats.get(chat_id);
        self.state_mutex.unlock();
        if (info) |chat| {
            if (chat.is_group or chat.is_channel) return false;
        }
        var content = std.json.ObjectMap.init(self.allocator);
        defer content.deinit();
        content.put("@type", .{ .string = "inputMessageText" }) catch return false;
        var formatted = std.json.ObjectMap.init(self.allocator);
        defer formatted.deinit();
        formatted.put("@type", .{ .string = "formattedText" }) catch return false;
        formatted.put("text", .{ .string = text }) catch return false;
        content.put("text", .{ .object = formatted }) catch return false;
        var request = std.json.ObjectMap.init(self.allocator);
        defer request.deinit();
        request.put("@type", .{ .string = "sendMessage" }) catch return false;
        request.put("chat_id", .{ .integer = chat_id }) catch return false;
        request.put("input_message_content", .{ .object = content }) catch return false;
        self.sendJson(.{ .object = request });
        return true;
    }

    pub fn markRead(self: *Client, chat_id: i64, message_id: i64) void {
        var ids = std.json.Array.init(self.allocator);
        defer ids.deinit();
        ids.append(.{ .integer = message_id }) catch return;
        var request = std.json.ObjectMap.init(self.allocator);
        defer request.deinit();
        request.put("@type", .{ .string = "viewMessages" }) catch return;
        request.put("chat_id", .{ .integer = chat_id }) catch return;
        request.put("message_ids", .{ .array = ids }) catch return;
        request.put("force_read", .{ .bool = true }) catch return;
        self.sendJson(.{ .object = request });
    }

    pub fn download(self: *Client, file_id: i32) void {
        if (file_id == 0) return;
        self.sendObject(.{ .type = "downloadFile", .file_id = file_id, .priority = 32, .offset = 0, .limit = 0, .synchronous = false });
    }

    pub fn logOut(self: *Client) void {
        self.sendObject(.{ .type = "logOut" });
    }

    /// Owned copies of the tracked chats. Caller frees with freeChatSnapshot.
    pub fn chatSnapshot(self: *Client, allocator: std.mem.Allocator) []ChatInfo {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        var list = std.ArrayList(ChatInfo).empty;
        var iterator = self.chats.iterator();
        while (iterator.next()) |entry| {
            const copy = entry.value_ptr.*;
            var info = copy;
            info.title = allocator.dupe(u8, entry.value_ptr.title) catch continue;
            list.append(allocator, info) catch {
                allocator.free(info.title);
                continue;
            };
        }
        return list.toOwnedSlice(allocator) catch {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
            return &.{};
        };
    }

    pub fn freeChatSnapshot(self: *Client, allocator: std.mem.Allocator, snapshot: []ChatInfo) void {
        _ = self;
        for (snapshot) |*item| item.deinit(allocator);
        allocator.free(snapshot);
    }

    /// Owned copies of the cached history for one chat, oldest first.
    /// Caller frees with freeHistorySnapshot.
    pub fn historySnapshot(self: *Client, allocator: std.mem.Allocator, chat_id: i64) []Msg {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const stored = self.history.getPtr(chat_id) orelse return &.{};
        var list = std.ArrayList(Msg).empty;
        for (stored.items) |*msg| {
            var copy = msg.*;
            copy.sender_name = allocator.dupe(u8, msg.sender_name) catch continue;
            copy.text = allocator.dupe(u8, msg.text) catch continue;
            copy.timestamp = allocator.dupe(u8, msg.timestamp) catch continue;
            copy.local_path = allocator.dupe(u8, msg.local_path) catch continue;
            copy.mime = allocator.dupe(u8, msg.mime) catch continue;
            list.append(allocator, copy) catch {
                copy.deinit(allocator);
                continue;
            };
        }
        return list.toOwnedSlice(allocator) catch {
            for (list.items) |*item| item.deinit(allocator);
            list.deinit(allocator);
            return &.{};
        };
    }

    pub fn freeHistorySnapshot(self: *Client, allocator: std.mem.Allocator, snapshot: []Msg) void {
        _ = self;
        for (snapshot) |*item| item.deinit(allocator);
        allocator.free(snapshot);
    }

    fn sendFields(self: *Client, fields: anytype) void {
        var object = std.json.ObjectMap.init(self.allocator);
        defer object.deinit();
        inline for (std.meta.fields(@TypeOf(fields))) |field| {
            const value = @field(fields, field.name);
            const key = comptime mapKey(field.name);
            switch (@TypeOf(value)) {
                []const u8, []u8 => object.put(key, .{ .string = value }) catch return,
                i32, i64, u32 => object.put(key, .{ .integer = value }) catch return,
                bool => object.put(key, .{ .bool = value }) catch return,
                else => @compileError("unsupported request field type"),
            }
        }
        self.sendJson(.{ .object = object });
    }

    fn sendJson(self: *Client, value: std.json.Value) void {
        const text = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch return;
        defer self.allocator.free(text);
        const zero_terminated = self.allocator.dupeZ(u8, text) catch return;
        defer self.allocator.free(zero_terminated);
        c.td_json_client_send(self.client, zero_terminated.ptr);
    }

    fn sendTdlibParameters(self: *Client) void {
        self.sendFields(.{
            .type = "setTdlibParameters",
            .database_directory = self.database_dir,
            .files_directory = self.files_dir,
            .database_encryption_key = "",
            .use_message_database = true,
            .use_secret_chats = false,
            .api_id = self.api_id,
            .api_hash = self.api_hash,
            .system_language_code = "en",
            .device_model = "Desktop",
            .application_version = "1.0",
        });
        self.parameters_sent = true;
    }

    fn sendClose(self: *Client) void {
        if (self.client == undefined) return;
        var object = std.json.ObjectMap.init(self.allocator);
        defer object.deinit();
        object.put("@type", .{ .string = "close" }) catch return;
        self.sendJson(.{ .object = object });
    }

    fn receiveLoop(self: *Client) void {
        while (!self.stopping.load(.acquire)) {
            const raw = c.td_json_client_receive(self.client, 0.5) orelse continue;
            const text = std.mem.span(raw);
            self.handleRaw(text);
        }
        c.td_json_client_destroy(self.client);
    }

    fn handleRaw(self: *Client, text: []const u8) void {
        var events = tj.parseEventBatch(self.allocator, text) catch return;
        defer events.deinit(self.allocator);
        for (events.items) |*event| {
            switch (event.*) {
                .auth => |auth| {
                    self.state_mutex.lock();
                    if (auth.state != .unknown) self.auth = auth.state;
                    self.state_mutex.unlock();
                    if (auth.state == .wait_parameters and !self.parameters_sent) self.sendTdlibParameters();
                },
                .chat => |*info| {
                    self.applyChat(info);
                },
                .message => |*msg| {
                    self.storeMessage(msg);
                },
                .file => |update| {
                    if (update.local_path.len > 0) {
                        self.state_mutex.lock();
                        var history_iterator = self.history.iterator();
                        while (history_iterator.next()) |entry| {
                            for (entry.value_ptr.items) |*msg| {
                                if (msg.file_id == update.file_id and msg.local_path.len == 0) {
                                    msg.local_path = self.allocator.dupe(u8, update.local_path) catch &.{};
                                }
                            }
                        }
                        self.state_mutex.unlock();
                    }
                },
                else => {},
            }
        }
        // The events were applied to client state (which made its own copies);
        // the queue hands the same owned events to the UI thread, which frees
        // them after applying them to widgets.
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        for (events.items) |event| {
            if (self.queue.items.len >= max_queued_events) {
                self.dropped_events += 1;
                var dropped = event;
                dropped.deinit(self.allocator);
                continue;
            }
            self.queue.append(self.allocator, event) catch {
                var dropped = event;
                dropped.deinit(self.allocator);
            };
        }
        events.items = &.{};
        events.capacity = 0;
    }

    fn applyChat(self: *Client, info: *ChatInfo) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.chats.count() >= max_tracked_chats and !self.chats.contains(info.id)) return;
        const entry = self.chats.getOrPut(info.id) catch return;
        if (entry.found_existing) {
            const previous = entry.value_ptr.*;
            entry.value_ptr.* = info.*;
            // updateChatReadInbox carries only the id and unread count: keep
            // the title and last-message date we already know.
            if (info.title.len == 0) {
                entry.value_ptr.title = previous.title;
            } else {
                self.allocator.free(previous.title);
            }
            if (info.last_date == 0) entry.value_ptr.last_date = previous.last_date;
        } else {
            entry.value_ptr.* = info.*;
        }
    }

    fn storeMessage(self: *Client, msg: *Msg) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const pointer = self.history.getOrPut(msg.chat_id) catch return;
        if (!pointer.found_existing) pointer.value_ptr.* = .empty;
        const list = pointer.value_ptr;
        // Replace an existing copy (send reconciliation, edited messages);
        // the queued event keeps ownership of the incoming strings, so the
        // stored copy duplicates them.
        for (list.items) |*existing| {
            if (existing.id == msg.id) {
                if (self.dupeMessage(msg)) |copy| {
                    existing.deinit(self.allocator);
                    existing.* = copy;
                }
                return;
            }
        }
        if (self.dupeMessage(msg)) |copy| {
            list.append(self.allocator, copy) catch {
                copy.deinit(self.allocator);
                return;
            };
        }
        // ponytail: history cache is capped per chat and never evicted across
        // chats; upgrade path: LRU over chats if memory becomes measurable.
        while (list.items.len > max_history_per_chat) {
            var oldest = list.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    fn dupeMessage(self: *Client, msg: *const Msg) ?Msg {
        var copy = msg.*;
        copy.sender_name = self.allocator.dupe(u8, msg.sender_name) catch return null;
        copy.text = self.allocator.dupe(u8, msg.text) catch {
            self.allocator.free(copy.sender_name);
            return null;
        };
        copy.timestamp = self.allocator.dupe(u8, msg.timestamp) catch {
            self.allocator.free(copy.sender_name);
            self.allocator.free(copy.text);
            return null;
        };
        copy.local_path = self.allocator.dupe(u8, msg.local_path) catch {
            self.allocator.free(copy.sender_name);
            self.allocator.free(copy.text);
            self.allocator.free(copy.timestamp);
            return null;
        };
        copy.mime = self.allocator.dupe(u8, msg.mime) catch {
            self.allocator.free(copy.sender_name);
            self.allocator.free(copy.text);
            self.allocator.free(copy.timestamp);
            self.allocator.free(copy.local_path);
            return null;
        };
        return copy;
    }
};

fn mapKey(comptime name: []const u8) []const u8 {
    if (comptime std.mem.eql(u8, name, "type")) return "@type";
    return name;
}
