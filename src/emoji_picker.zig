//! Emoji catalog for the picker plus the pure logic behind it: name search,
//! recent-emoji persistence (registry string parsing/validation) and grid
//! hit-testing. No Windows calls here so everything is testable headless.

pub const Entry = struct { name: []const u8, emoji: []const u8 };

const std = @import("std");

pub const grid_columns: usize = 8;
pub const grid_rows: usize = 6;
pub const cell_size: i32 = 44;
pub const grid_row_height: i32 = cell_size;
pub const max_recents: usize = 8;

pub const catalog = [_]Entry{
    // Smileys and people
    .{ .name = "grinning face", .emoji = "😀" },
    .{ .name = "beaming face", .emoji = "😁" },
    .{ .name = "face with tears of joy", .emoji = "😂" },
    .{ .name = "rolling on the floor laughing", .emoji = "🤣" },
    .{ .name = "smiling face with open mouth", .emoji = "😃" },
    .{ .name = "smiling face with open mouth and sweat", .emoji = "😅" },
    .{ .name = "laughing face", .emoji = "😆" },
    .{ .name = "winking face", .emoji = "😉" },
    .{ .name = "smiling face with smiling eyes", .emoji = "😊" },
    .{ .name = "smiling face with halo", .emoji = "😇" },
    .{ .name = "smiling face with horns", .emoji = "😈" },
    .{ .name = "winking face with tongue", .emoji = "😜" },
    .{ .name = "zany face", .emoji = "🤪" },
    .{ .name = "face savoring food", .emoji = "😋" },
    .{ .name = "face blowing a kiss", .emoji = "😘" },
    .{ .name = "face blowing a kiss with heart", .emoji = "😍" },
    .{ .name = "smiling face with heart eyes", .emoji = "🥰" },
    .{ .name = "face with tongue", .emoji = "😛" },
    .{ .name = "squinting face with tongue", .emoji = "😝" },
    .{ .name = "face with raised eyebrow", .emoji = "🤨" },
    .{ .name = "neutral face", .emoji = "😐" },
    .{ .name = "expressionless face", .emoji = "😑" },
    .{ .name = "face without mouth", .emoji = "😶" },
    .{ .name = "face with rolling eyes", .emoji = "🙄" },
    .{ .name = "smirking face", .emoji = "😏" },
    .{ .name = "pensive face", .emoji = "😔" },
    .{ .name = "unamused face", .emoji = "😒" },
    .{ .name = "face with steam from nose", .emoji = "😤" },
    .{ .name = "anguished face", .emoji = "😧" },
    .{ .name = "frowning face", .emoji = "🙁" },
    .{ .name = "slightly frowning face", .emoji = "🙁" },
    .{ .name = "confused face", .emoji = "😕" },
    .{ .name = "persevering face", .emoji = "😣" },
    .{ .name = "disappointed face", .emoji = "😞" },
    .{ .name = "worried face", .emoji = "😟" },
    .{ .name = "face with medical mask", .emoji = "😷" },
    .{ .name = "face with thermometer", .emoji = "🤒" },
    .{ .name = "face with bandage", .emoji = "🤕" },
    .{ .name = "nauseated face", .emoji = "🤢" },
    .{ .name = "face vomiting", .emoji = "🤮" },
    .{ .name = "sneezing face", .emoji = "🤧" },
    .{ .name = "hot face", .emoji = "🥵" },
    .{ .name = "cold face", .emoji = "🥶" },
    .{ .name = "woozy face", .emoji = "🥴" },
    .{ .name = "dizzy face", .emoji = "😵" },
    .{ .name = "exploding head", .emoji = "🤯" },
    .{ .name = "cowboy hat face", .emoji = "🤠" },
    .{ .name = "partying face", .emoji = "🥳" },
    .{ .name = "smiling face with sunglasses", .emoji = "😎" },
    .{ .name = "nerd face", .emoji = "🤓" },
    .{ .name = "face with monocle", .emoji = "🧐" },
    .{ .name = "confounded face", .emoji = "😖" },
    .{ .name = "tired face", .emoji = "😫" },
    .{ .name = "yawning face", .emoji = "🥱" },
    .{ .name = "sleeping face", .emoji = "😴" },
    .{ .name = "relieved face", .emoji = "😌" },
    .{ .name = "face with look of triumph", .emoji = "😤" },
    .{ .name = "crying face", .emoji = "😢" },
    .{ .name = "loudly crying face", .emoji = "😭" },
    .{ .name = "face screaming in fear", .emoji = "😱" },
    .{ .name = "flushed face", .emoji = "😳" },
    .{ .name = "pleading face", .emoji = "🥺" },
    .{ .name = "frowning face with open mouth", .emoji = "😦" },
    .{ .name = "anguished face open mouth", .emoji = "😨" },
    .{ .name = "fearful face", .emoji = "😰" },
    .{ .name = "cold sweat face", .emoji = "😥" },
    .{ .name = "disappointed but relieved face", .emoji = "😥" },
    .{ .name = "weary face", .emoji = "😩" },
    .{ .name = "grimacing face", .emoji = "😬" },
    .{ .name = "lying face", .emoji = "🤥" },
    .{ .name = "shushing face", .emoji = "🤫" },
    .{ .name = "thinking face", .emoji = "🤔" },
    .{ .name = "face with hand over mouth", .emoji = "🤭" },
    .{ .name = "melting face", .emoji = "🫠" },
    .{ .name = "saluting face", .emoji = "🫡" },
    .{ .name = "skull", .emoji = "💀" },
    .{ .name = "poop", .emoji = "💩" },
    .{ .name = "clown face", .emoji = "🤡" },
    .{ .name = "ghost", .emoji = "👻" },
    .{ .name = "alien", .emoji = "👽" },
    .{ .name = "robot", .emoji = "🤖" },
    .{ .name = "smiley cat", .emoji = "😺" },
    .{ .name = "joy cat", .emoji = "😹" },
    .{ .name = "heart eyes cat", .emoji = "😻" },
    .{ .name = "weary cat", .emoji = "🙀" },
    .{ .name = "crying cat", .emoji = "😿" },
    // Gestures
    .{ .name = "thumbs up", .emoji = "👍" },
    .{ .name = "thumbs down", .emoji = "👎" },
    .{ .name = "ok hand", .emoji = "👌" },
    .{ .name = "pinching hand", .emoji = "🤏" },
    .{ .name = "victory hand", .emoji = "✌️" },
    .{ .name = "crossed fingers", .emoji = "🤞" },
    .{ .name = "love you gesture", .emoji = "🤟" },
    .{ .name = "sign of the horns", .emoji = "🤘" },
    .{ .name = "call me hand", .emoji = "🤙" },
    .{ .name = "point left", .emoji = "👈" },
    .{ .name = "point right", .emoji = "👉" },
    .{ .name = "point up", .emoji = "👆" },
    .{ .name = "point down", .emoji = "👇" },
    .{ .name = "raised hand", .emoji = "✋" },
    .{ .name = "raised back of hand", .emoji = "🤚" },
    .{ .name = "hand with fingers splayed", .emoji = "🖐️" },
    .{ .name = "vulcan salute", .emoji = "🖖" },
    .{ .name = "waving hand", .emoji = "👋" },
    .{ .name = "clapping hands", .emoji = "👏" },
    .{ .name = "raising hands", .emoji = "🙌" },
    .{ .name = "open hands", .emoji = "👐" },
    .{ .name = "handshake", .emoji = "🤝" },
    .{ .name = "folded hands", .emoji = "🙏" },
    .{ .name = "writing hand", .emoji = "✍️" },
    .{ .name = "nail polish", .emoji = "💅" },
    .{ .name = "flexed biceps", .emoji = "💪" },
    .{ .name = "thinking hand chin", .emoji = "🤔" },
    .{ .name = "face palm", .emoji = "🤦" },
    .{ .name = "shrug", .emoji = "🤷" },
    .{ .name = "punch", .emoji = "👊" },
    .{ .name = "raised fist", .emoji = "✊" },
    .{ .name = "left facing fist", .emoji = "🤛" },
    .{ .name = "right facing fist", .emoji = "🤜" },
    .{ .name = "hand peace", .emoji = "✌️" },
    // Hearts and symbols
    .{ .name = "red heart", .emoji = "❤️" },
    .{ .name = "orange heart", .emoji = "🧡" },
    .{ .name = "yellow heart", .emoji = "💛" },
    .{ .name = "green heart", .emoji = "💚" },
    .{ .name = "blue heart", .emoji = "💙" },
    .{ .name = "purple heart", .emoji = "💜" },
    .{ .name = "black heart", .emoji = "🖤" },
    .{ .name = "white heart", .emoji = "🤍" },
    .{ .name = "brown heart", .emoji = "🤎" },
    .{ .name = "broken heart", .emoji = "💔" },
    .{ .name = "two hearts", .emoji = "💕" },
    .{ .name = "sparkling heart", .emoji = "💖" },
    .{ .name = "growing heart", .emoji = "💗" },
    .{ .name = "beating heart", .emoji = "💓" },
    .{ .name = "revolving hearts", .emoji = "💞" },
    .{ .name = "heart with arrow", .emoji = "💘" },
    .{ .name = "heart with ribbon", .emoji = "💝" },
    .{ .name = "heart exclamation", .emoji = "❣️" },
    .{ .name = "hundred points", .emoji = "💯" },
    .{ .name = "anger symbol", .emoji = "💢" },
    .{ .name = "collision", .emoji = "💥" },
    .{ .name = "dizzy", .emoji = "💫" },
    .{ .name = "sweat droplets", .emoji = "💦" },
    .{ .name = "dash away", .emoji = "💨" },
    .{ .name = "hole", .emoji = "🕳️" },
    .{ .name = "bomb", .emoji = "💣" },
    .{ .name = "speech balloon", .emoji = "💬" },
    .{ .name = "thought balloon", .emoji = "💭" },
    .{ .name = "zzz", .emoji = "💤" },
    .{ .name = "check mark", .emoji = "✅" },
    .{ .name = "cross mark", .emoji = "❌" },
    .{ .name = "question mark", .emoji = "❓" },
    .{ .name = "exclamation mark", .emoji = "❗" },
    .{ .name = "warning sign", .emoji = "⚠️" },
    .{ .name = "prohibited", .emoji = "🚫" },
    .{ .name = "sparkles", .emoji = "✨" },
    .{ .name = "star", .emoji = "⭐" },
    .{ .name = "glowing star", .emoji = "🌟" },
    .{ .name = "shooting star", .emoji = "🌠" },
    .{ .name = "fire", .emoji = "🔥" },
    .{ .name = "light bulb", .emoji = "💡" },
    .{ .name = "bell", .emoji = "🔔" },
    .{ .name = "key", .emoji = "🔑" },
    .{ .name = "lock", .emoji = "🔒" },
    .{ .name = "link", .emoji = "🔗" },
    .{ .name = "pushpin", .emoji = "📌" },
    .{ .name = "round pushpin", .emoji = "📍" },
    // Objects
    .{ .name = "party popper", .emoji = "🎉" },
    .{ .name = "confetti ball", .emoji = "🎊" },
    .{ .name = "balloon", .emoji = "🎈" },
    .{ .name = "gift", .emoji = "🎁" },
    .{ .name = "birthday cake", .emoji = "🎂" },
    .{ .name = "trophy", .emoji = "🏆" },
    .{ .name = "medal", .emoji = "🏅" },
    .{ .name = "soccer ball", .emoji = "⚽" },
    .{ .name = "basketball", .emoji = "🏀" },
    .{ .name = "football", .emoji = "🏈" },
    .{ .name = "tennis", .emoji = "🎾" },
    .{ .name = "game die", .emoji = "🎲" },
    .{ .name = "jigsaw piece", .emoji = "🧩" },
    .{ .name = "video game", .emoji = "🎮" },
    .{ .name = "musical notes", .emoji = "🎶" },
    .{ .name = "musical note", .emoji = "🎵" },
    .{ .name = "microphone", .emoji = "🎤" },
    .{ .name = "headphone", .emoji = "🎧" },
    .{ .name = "camera", .emoji = "📷" },
    .{ .name = "mobile phone", .emoji = "📱" },
    .{ .name = "laptop", .emoji = "💻" },
    .{ .name = "desktop computer", .emoji = "🖥️" },
    .{ .name = "battery", .emoji = "🔋" },
    .{ .name = "money bag", .emoji = "💰" },
    .{ .name = "dollar banknote", .emoji = "💵" },
    .{ .name = "credit card", .emoji = "💳" },
    .{ .name = "clock", .emoji = "🕐" },
    .{ .name = "alarm clock", .emoji = "⏰" },
    .{ .name = "hourglass", .emoji = "⌛" },
    .{ .name = "stopwatch", .emoji = "⏱️" },
    .{ .name = "calendar", .emoji = "📅" },
    .{ .name = "envelope", .emoji = "✉️" },
    .{ .name = "inbox tray", .emoji = "📥" },
    .{ .name = "outbox tray", .emoji = "📤" },
    .{ .name = "package", .emoji = "📦" },
    .{ .name = "bookmark", .emoji = "🔖" },
    .{ .name = "books", .emoji = "📚" },
    .{ .name = "pencil", .emoji = "✏️" },
    .{ .name = "pen", .emoji = "🖊️" },
    .{ .name = "clipboard", .emoji = "📋" },
    .{ .name = "file folder", .emoji = "📁" },
    .{ .name = "open file folder", .emoji = "📂" },
    .{ .name = "wastebasket", .emoji = "🗑️" },
    .{ .name = "hammer", .emoji = "🔨" },
    .{ .name = "wrench", .emoji = "🔧" },
    .{ .name = "gear", .emoji = "⚙️" },
    .{ .name = "magnifying glass", .emoji = "🔍" },
    .{ .name = "telescope", .emoji = "🔭" },
    .{ .name = "rocket", .emoji = "🚀" },
    .{ .name = "airplane", .emoji = "✈️" },
    .{ .name = "car", .emoji = "🚗" },
    .{ .name = "taxi", .emoji = "🚕" },
    .{ .name = "bus", .emoji = "🚌" },
    .{ .name = "bicycle", .emoji = "🚲" },
    .{ .name = "ship", .emoji = "🚢" },
    .{ .name = "house", .emoji = "🏠" },
    .{ .name = "office building", .emoji = "🏢" },
    .{ .name = "hospital", .emoji = "🏥" },
    .{ .name = "umbrella", .emoji = "☂️" },
    .{ .name = "sun with face", .emoji = "🌞" },
    .{ .name = "full moon", .emoji = "🌕" },
    .{ .name = "crescent moon", .emoji = "🌙" },
    .{ .name = "cloud", .emoji = "☁️" },
    .{ .name = "rainbow", .emoji = "🌈" },
    .{ .name = "snowflake", .emoji = "❄️" },
    .{ .name = "high voltage", .emoji = "⚡" },
    .{ .name = "comet", .emoji = "☄️" },
    .{ .name = "globe showing europe africa", .emoji = "🌍" },
    .{ .name = "cactus", .emoji = "🌵" },
    .{ .name = "christmas tree", .emoji = "🎄" },
    .{ .name = "four leaf clover", .emoji = "🍀" },
    .{ .name = "maple leaf", .emoji = "🍁" },
    .{ .name = "seedling", .emoji = "🌱" },
    .{ .name = "sunflower", .emoji = "🌻" },
    .{ .name = "blossom", .emoji = "🌼" },
    .{ .name = "rose", .emoji = "🌹" },
    .{ .name = "tulip", .emoji = "🌷" },
    .{ .name = "bouquet", .emoji = "💐" },
    // Food and drink
    .{ .name = "coffee", .emoji = "☕" },
    .{ .name = "tea", .emoji = "🍵" },
    .{ .name = "beer mug", .emoji = "🍺" },
    .{ .name = "clinking beer mugs", .emoji = "🍻" },
    .{ .name = "wine glass", .emoji = "🍷" },
    .{ .name = "cocktail", .emoji = "🍸" },
    .{ .name = "tropical drink", .emoji = "🍹" },
    .{ .name = "glass of milk", .emoji = "🥛" },
    .{ .name = "cup with straw", .emoji = "🥤" },
    .{ .name = "pizza", .emoji = "🍕" },
    .{ .name = "hamburger", .emoji = "🍔" },
    .{ .name = "french fries", .emoji = "🍟" },
    .{ .name = "hot dog", .emoji = "🌭" },
    .{ .name = "taco", .emoji = "🌮" },
    .{ .name = "sandwich", .emoji = "🥪" },
    .{ .name = "spaghetti", .emoji = "🍝" },
    .{ .name = "sushi", .emoji = "🍣" },
    .{ .name = "fried rice", .emoji = "🍛" },
    .{ .name = "steaming bowl", .emoji = "🍜" },
    .{ .name = "bread", .emoji = "🍞" },
    .{ .name = "croissant", .emoji = "🥐" },
    .{ .name = "pretzel", .emoji = "🥨" },
    .{ .name = "cheese wedge", .emoji = "🧀" },
    .{ .name = "egg", .emoji = "🥚" },
    .{ .name = "bacon", .emoji = "🥓" },
    .{ .name = "pancakes", .emoji = "🥞" },
    .{ .name = "butter", .emoji = "🧈" },
    .{ .name = "salad", .emoji = "🥗" },
    .{ .name = "avocado", .emoji = "🥑" },
    .{ .name = "carrot", .emoji = "🥕" },
    .{ .name = "corn", .emoji = "🌽" },
    .{ .name = "hot pepper", .emoji = "🌶️" },
    .{ .name = "cucumber", .emoji = "🥒" },
    .{ .name = "mushroom", .emoji = "🍄" },
    .{ .name = "peanuts", .emoji = "🥜" },
    .{ .name = "chestnut", .emoji = "🌰" },
    .{ .name = "apple", .emoji = "🍎" },
    .{ .name = "green apple", .emoji = "🍏" },
    .{ .name = "banana", .emoji = "🍌" },
    .{ .name = "grapes", .emoji = "🍇" },
    .{ .name = "watermelon", .emoji = "🍉" },
    .{ .name = "strawberry", .emoji = "🍓" },
    .{ .name = "cherries", .emoji = "🍒" },
    .{ .name = "peach", .emoji = "🍑" },
    .{ .name = "mango", .emoji = "🥭" },
    .{ .name = "pineapple", .emoji = "🍍" },
    .{ .name = "coconut", .emoji = "🥥" },
    .{ .name = "kiwi fruit", .emoji = "🥝" },
    .{ .name = "lemon", .emoji = "🍋" },
    .{ .name = "orange slice", .emoji = "🍊" },
    .{ .name = "pear", .emoji = "🍐" },
    .{ .name = "donut", .emoji = "🍩" },
    .{ .name = "cookie", .emoji = "🍪" },
    .{ .name = "cake slice", .emoji = "🍰" },
    .{ .name = "chocolate bar", .emoji = "🍫" },
    .{ .name = "candy", .emoji = "🍬" },
    .{ .name = "lollipop", .emoji = "🍭" },
    .{ .name = "custard", .emoji = "🍮" },
    .{ .name = "honey pot", .emoji = "🍯" },
    .{ .name = "ice cream", .emoji = "🍨" },
    .{ .name = "ice cream cone", .emoji = "🍦" },
    .{ .name = "popcorn", .emoji = "🍿" },
    .{ .name = "salt", .emoji = "🧂" },
    // Animals
    .{ .name = "dog face", .emoji = "🐶" },
    .{ .name = "cat face", .emoji = "🐱" },
    .{ .name = "mouse face", .emoji = "🐭" },
    .{ .name = "hamster", .emoji = "🐹" },
    .{ .name = "rabbit face", .emoji = "🐰" },
    .{ .name = "fox", .emoji = "🦊" },
    .{ .name = "bear", .emoji = "🐻" },
    .{ .name = "panda", .emoji = "🐼" },
    .{ .name = "koala", .emoji = "🐨" },
    .{ .name = "tiger face", .emoji = "🐯" },
    .{ .name = "lion", .emoji = "🦁" },
    .{ .name = "cow face", .emoji = "🐮" },
    .{ .name = "pig face", .emoji = "🐷" },
    .{ .name = "frog", .emoji = "🐸" },
    .{ .name = "monkey face", .emoji = "🐵" },
    .{ .name = "chicken", .emoji = "🐔" },
    .{ .name = "penguin", .emoji = "🐧" },
    .{ .name = "bird", .emoji = "🐦" },
    .{ .name = "duck", .emoji = "🦆" },
    .{ .name = "owl", .emoji = "🦉" },
    .{ .name = "unicorn", .emoji = "🦄" },
    .{ .name = "bee", .emoji = "🐝" },
    .{ .name = "butterfly", .emoji = "🦋" },
    .{ .name = "snail", .emoji = "🐌" },
    .{ .name = "lady beetle", .emoji = "🐞" },
    .{ .name = "turtle", .emoji = "🐢" },
    .{ .name = "snake", .emoji = "🐍" },
    .{ .name = "octopus", .emoji = "🐙" },
    .{ .name = "fish", .emoji = "🐟" },
    .{ .name = "whale", .emoji = "🐳" },
    .{ .name = "dolphin", .emoji = "🐬" },
    .{ .name = "shark", .emoji = "🦈" },
    .{ .name = "crocodile", .emoji = "🐊" },
    .{ .name = "zebra", .emoji = "🦓" },
    .{ .name = "horse face", .emoji = "🐴" },
    .{ .name = "pig nose", .emoji = "🐽" },
    .{ .name = "paw prints", .emoji = "🐾" },
    .{ .name = "dragon", .emoji = "🐲" },
    .{ .name = "spider", .emoji = "🕷️" },
};

/// Case-insensitive substring match of an ASCII query against an ASCII name.
pub fn nameMatches(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > name.len) return false;
    var start: usize = 0;
    while (start + query.len <= name.len) : (start += 1) {
        var matched = true;
        for (query, 0..) |character, index| {
            const candidate = name[start + index];
            if (lowerAscii(candidate) != lowerAscii(character)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn lowerAscii(character: u8) u8 {
    return if (character >= 'A' and character <= 'Z') character + 32 else character;
}

/// Parses the persisted recent-emoji registry string ("3,17,5") into catalog
/// indices. Malformed, out-of-range, and duplicate entries are dropped; the
/// most recent first. Returns the number of valid entries written.
pub fn parseRecents(text: []const u8, out: *[max_recents]u16) usize {
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, ',');
    while (iterator.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0 or trimmed.len > 4) continue;
        const index = std.fmt.parseInt(u16, trimmed, 10) catch continue;
        if (index >= catalog.len) continue;
        var duplicate = false;
        for (out[0..count]) |existing| {
            if (existing == index) duplicate = true;
        }
        if (duplicate) continue;
        out[count] = index;
        count += 1;
        if (count == max_recents) break;
    }
    return count;
}

/// Formats recent indices for the registry: "3,17,5".
pub fn formatRecents(buffer: []u8, recents: []const u16) []const u8 {
    var len: usize = 0;
    for (recents, 0..) |index, position| {
        if (position > 0) {
            if (len >= buffer.len) break;
            buffer[len] = ',';
            len += 1;
        }
        const printed = std.fmt.bufPrint(buffer[len..], "{d}", .{index}) catch break;
        len += printed.len;
    }
    return buffer[0..len];
}

/// Moves an emoji to the front of the recents list (inserting or promoting),
/// keeping at most max_recents entries.
pub fn pushRecent(recents: []u16, count: *usize, index: u16) void {
    for (recents[0..count.*], 0..) |existing, position| {
        if (existing == index) {
            std.mem.copyBackwards(u16, recents[1 .. position + 1], recents[0..position]);
            recents[0] = index;
            return;
        }
    }
    const capped = @min(count.* + 1, max_recents);
    var position = capped;
    while (position > 1) : (position -= 1) {
        recents[position - 1] = recents[position - 2];
    }
    recents[0] = index;
    count.* = capped;
}

/// Maps a click inside a grid row to a column, or null outside the grid.
pub fn cellFromHit(offset_in_row: i32) ?usize {
    if (offset_in_row < 0 or offset_in_row >= cell_size * @as(i32, @intCast(grid_columns))) return null;
    return @intCast(@divTrunc(offset_in_row, cell_size));
}

test "name search matches substrings case-insensitively" {
    try std.testing.expect(nameMatches("thumbs up", "humb"));
    try std.testing.expect(nameMatches("thumbs up", "THUMBS"));
    try std.testing.expect(!nameMatches("thumbs up", "wink"));
    try std.testing.expect(nameMatches("red heart", ""));
}

test "recents parse validates and deduplicates" {
    var recents: [max_recents]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), parseRecents("0, 94,0", &recents));
    try std.testing.expectEqual(@as(u16, 0), recents[0]);
    try std.testing.expectEqual(@as(u16, 94), recents[1]);
    try std.testing.expectEqual(@as(usize, 0), parseRecents("99999", &recents));
    try std.testing.expectEqual(@as(usize, 0), parseRecents("bogus", &recents));
    try std.testing.expectEqual(@as(usize, 0), parseRecents("", &recents));
    // Overflowing entries are capped.
    var full: [max_recents]u16 = undefined;
    try std.testing.expectEqual(@as(usize, max_recents), parseRecents("0,1,2,3,4,5,6,7,8,9", &full));
    try std.testing.expectEqual(@as(u16, 7), full[7]);
}

test "format and parse round-trip recents" {
    var buffer: [64]u8 = undefined;
    const text = formatRecents(&buffer, &.{ 3, 17, 5 });
    try std.testing.expectEqualStrings("3,17,5", text);
    var recents: [max_recents]u16 = undefined;
    const count = parseRecents(text, &recents);
    try std.testing.expectEqualSlices(u16, &.{ 3, 17, 5 }, recents[0..count]);
}

test "push recent promotes, inserts, and caps" {
    var recents: [max_recents]u16 = [_]u16{0} ** max_recents;
    var count: usize = 0;
    pushRecent(&recents, &count, 3);
    pushRecent(&recents, &count, 17);
    pushRecent(&recents, &count, 3);
    try std.testing.expectEqualSlices(u16, &.{ 3, 17 }, recents[0..count]);
    try std.testing.expectEqual(@as(usize, 2), count);
    for (0..max_recents + 2) |index| pushRecent(&recents, &count, @intCast(index));
    try std.testing.expectEqual(@as(usize, max_recents), count);
    try std.testing.expectEqual(@as(u16, max_recents + 1), recents[0]);
    try std.testing.expectEqual(@as(u16, 2), recents[7]);
}

test "grid hit test maps offsets to columns" {
    try std.testing.expectEqual(@as(?usize, 0), cellFromHit(0));
    try std.testing.expectEqual(@as(?usize, 3), cellFromHit(3 * cell_size));
    try std.testing.expectEqual(@as(?usize, null), cellFromHit(-1));
    try std.testing.expectEqual(@as(?usize, null), cellFromHit(cell_size * @as(i32, @intCast(grid_columns))));
}
