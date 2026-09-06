//! Transport interface shared by every messaging provider. Telegram
//! (telegram.zig) implements the full surface today; the WhatsApp/wacli call
//! sites migrate operation by operation in follow-up PRs so the working
//! WhatsApp path is never churned in the same change that adds Telegram.

const std = @import("std");

/// One chat as the transports present it to the UI.
pub const ChatSummary = struct {
    /// Provider-qualified identity: WhatsApp uses its jid, Telegram its decimal
    /// chat id. The provider tag plus this string is the unique key for
    /// selection, dedup, pending sends, unread state, and cache paths.
    id: []const u8,
    name: []const u8,
    unread_count: i32,
    is_group: bool,
    /// UTC timestamp formatted "YYYY-MM-DD HH:MM:SS" so all providers sort
    /// identically in the sidebar.
    timestamp: []const u8,
};

pub const Provider = enum { whatsapp, telegram };

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Non-blocking signal to refresh the chat list; results are pushed
        /// back as transport-specific events on the next drain.
        refreshChats: *const fn (context: *anyopaque) void,
        refreshMessages: *const fn (context: *anyopaque, chat_id: []const u8) void,
        /// Returns false when the transport refuses the send (for example a
        /// read-only Telegram group): callers must not queue the message.
        sendText: *const fn (context: *anyopaque, chat_id: []const u8, text: []const u8) bool,
        markRead: *const fn (context: *anyopaque, chat_id: []const u8, message_id: []const u8) void,
        downloadMedia: *const fn (context: *anyopaque, chat_id: []const u8, message_id: []const u8) void,
    };

    pub fn refreshChats(self: Transport) void {
        self.vtable.refreshChats(self.context);
    }

    pub fn refreshMessages(self: Transport, chat_id: []const u8) void {
        self.vtable.refreshMessages(self.context, chat_id);
    }

    pub fn sendText(self: Transport, chat_id: []const u8, text: []const u8) bool {
        return self.vtable.sendText(self.context, chat_id, text);
    }

    pub fn markRead(self: Transport, chat_id: []const u8, message_id: []const u8) void {
        self.vtable.markRead(self.context, chat_id, message_id);
    }

    pub fn downloadMedia(self: Transport, chat_id: []const u8, message_id: []const u8) void {
        self.vtable.downloadMedia(self.context, chat_id, message_id);
    }
};
