//! Compile-time stand-in for telegram.zig used whenever the build was not
//! given -Dtdlib=<dir>. Exposes the identical Client API; create() succeeds
//! but every client reports a disabled state and no events ever arrive.

const std = @import("std");
const tj = @import("telegram_json.zig");

pub const enabled = false;
pub const AuthState = tj.AuthState;
pub const MediaKind = tj.MediaKind;
pub const Event = tj.Event;
pub const Msg = tj.Msg;
pub const ChatInfo = tj.ChatInfo;

pub const Client = struct {
    pub fn create(allocator: std.mem.Allocator, api_id: i32, api_hash: []const u8, base_dir: []const u8) ?*Client {
        _ = allocator;
        _ = api_id;
        _ = api_hash;
        _ = base_dir;
        return null;
    }

    pub fn destroy(self: *Client) void {
        _ = self;
    }

    pub fn poll(self: *Client) ?Event {
        _ = self;
        return null;
    }

    pub fn authState(self: *Client) AuthState {
        _ = self;
        return .unknown;
    }

    pub fn authPhone(self: *Client, phone: []const u8) void {
        _ = self;
        _ = phone;
    }

    pub fn authCode(self: *Client, code: []const u8) void {
        _ = self;
        _ = code;
    }

    pub fn authPassword(self: *Client, password: []const u8) void {
        _ = self;
        _ = password;
    }

    pub fn requestChats(self: *Client) void {
        _ = self;
    }

    pub fn requestHistory(self: *Client, chat_id: i64) void {
        _ = self;
        _ = chat_id;
    }

    pub fn sendText(self: *Client, chat_id: i64, text: []const u8) bool {
        _ = self;
        _ = chat_id;
        _ = text;
        return false;
    }

    pub fn markRead(self: *Client, chat_id: i64, message_id: i64) void {
        _ = self;
        _ = chat_id;
        _ = message_id;
    }

    pub fn download(self: *Client, file_id: i32) void {
        _ = self;
        _ = file_id;
    }

    pub fn logOut(self: *Client) void {
        _ = self;
    }

    pub fn chatSnapshot(self: *Client, allocator: std.mem.Allocator) []ChatInfo {
        _ = self;
        _ = allocator;
        return &.{};
    }

    pub fn freeChatSnapshot(self: *Client, allocator: std.mem.Allocator, snapshot: []ChatInfo) void {
        _ = self;
        _ = allocator;
        _ = snapshot;
    }

    pub fn historySnapshot(self: *Client, allocator: std.mem.Allocator, chat_id: i64) []Msg {
        _ = self;
        _ = allocator;
        _ = chat_id;
        return &.{};
    }

    pub fn freeHistorySnapshot(self: *Client, allocator: std.mem.Allocator, snapshot: []Msg) void {
        _ = self;
        _ = allocator;
        _ = snapshot;
    }
};
