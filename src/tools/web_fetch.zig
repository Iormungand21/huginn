//! Web Fetch Tool — fetch and extract content from web pages.
//!
//! Converts HTML to readable text/markdown. Removes scripts, styles,
//! and navigation. Preserves headings, links, and lists.

const std = @import("std");
const Tool = @import("root.zig").Tool;
const ToolResult = @import("root.zig").ToolResult;
const parseStringField = @import("shell.zig").parseStringField;

/// Default max chars for extracted content.
const DEFAULT_MAX_CHARS: usize = 50_000;

/// Web fetch tool — fetches URLs and extracts readable content.
pub const WebFetchTool = struct {
    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *WebFetchTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args_json: []const u8) anyerror!ToolResult {
        const self: *WebFetchTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args_json);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "web_fetch";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Fetch a web page and extract its text content. Converts HTML to readable text with markdown formatting.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch (http or https)"},"max_chars":{"type":"integer","default":50000,"description":"Maximum characters to return"}},"required":["url"]}
        ;
    }

    fn execute(_: *WebFetchTool, allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
        const url = parseStringField(args_json, "url") orelse
            return ToolResult.fail("Missing required 'url' parameter");

        // Validate URL scheme
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return ToolResult.fail("Only http:// and https:// URLs are allowed");
        }

        // SSRF protection — block local/private hosts
        const host = extractHost(url) orelse
            return ToolResult.fail("Invalid URL: cannot extract host");
        if (isLocalHost(host))
            return ToolResult.fail("Blocked local/private host");

        const max_chars = parseMaxChars(args_json);

        // Fetch URL
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch
            return ToolResult.fail("Invalid URL format");

        var req = client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "nullclaw/0.1 (web_fetch tool)" },
                .{ .name = "Accept", .value = "text/html,application/json,text/plain,*/*" },
            },
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Fetch failed: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer req.deinit();

        req.sendBodiless() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to send request: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to receive response: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        const status_code = @intFromEnum(response.head.status);
        if (status_code < 200 or status_code >= 400) {
            const msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{status_code});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Read body (limit to 2MB)
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.readAlloc(allocator, 2 * 1024 * 1024) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to read response: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(body);

        // Extract text from HTML
        const extracted = try htmlToText(allocator, body);
        defer allocator.free(extracted);

        // Truncate if needed
        if (extracted.len > max_chars) {
            const truncated = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n[Content truncated at {d} chars, total {d} chars]",
                .{ extracted[0..max_chars], max_chars, extracted.len },
            );
            return ToolResult.ok(truncated);
        }

        return ToolResult.ok(try allocator.dupe(u8, extracted));
    }
};

fn parseMaxChars(json: []const u8) usize {
    const s = parseStringField(json, "max_chars") orelse return DEFAULT_MAX_CHARS;
    const val = std.fmt.parseInt(usize, s, 10) catch return DEFAULT_MAX_CHARS;
    if (val < 100) return 100;
    if (val > 200_000) return 200_000;
    return val;
}

fn extractHost(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url[8..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        return null;

    var end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#' or c == ':') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

fn isLocalHost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.startsWith(u8, host, "127.")) return true;
    if (std.mem.eql(u8, host, "0.0.0.0")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.startsWith(u8, host, "10.")) return true;
    if (std.mem.startsWith(u8, host, "192.168.")) return true;
    if (std.mem.startsWith(u8, host, "172.")) {
        // 172.16.0.0 – 172.31.255.255
        if (host.len > 4) {
            const second = std.fmt.parseInt(u8, host[4 .. std.mem.indexOfScalar(u8, host[4..], '.') orelse return false], 10) catch return false;
            if (second >= 16 and second <= 31) return true;
        }
    }
    return false;
}

/// Convert HTML to readable text with basic markdown formatting.
pub fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_script = false;
    var in_style = false;
    var last_was_newline = false;
    var consecutive_newlines: u32 = 0;

    while (i < html.len) {
        // Check for tag start
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };

            const tag_content = html[i + 1 .. tag_end];
            const tag_lower = tagName(tag_content);

            // Handle closing script/style
            if (tag_content.len > 0 and tag_content[0] == '/') {
                const close_tag = tagName(tag_content[1..]);
                if (eqlTag(close_tag, "script")) in_script = false;
                if (eqlTag(close_tag, "style")) in_style = false;
                if (eqlTag(close_tag, "noscript")) {} // just skip
                i = tag_end + 1;
                continue;
            }

            // Opening tags
            if (eqlTag(tag_lower, "script")) {
                in_script = true;
                i = tag_end + 1;
                continue;
            }
            if (eqlTag(tag_lower, "style")) {
                in_style = true;
                i = tag_end + 1;
                continue;
            }

            if (in_script or in_style) {
                i = tag_end + 1;
                continue;
            }

            // Block elements → newline
            if (isBlockTag(tag_lower)) {
                if (!last_was_newline and buf.items.len > 0) {
                    try appendNewline(&buf, allocator, &consecutive_newlines);
                    last_was_newline = true;
                }
            }

            // Headings → markdown
            if (tag_lower.len == 2 and tag_lower[0] == 'h' and tag_lower[1] >= '1' and tag_lower[1] <= '6') {
                const level = tag_lower[1] - '0';
                if (!last_was_newline and buf.items.len > 0) {
                    try appendNewline(&buf, allocator, &consecutive_newlines);
                    last_was_newline = true;
                }
                for (0..level) |_| try buf.append(allocator, '#');
                try buf.append(allocator, ' ');
                last_was_newline = false;
                consecutive_newlines = 0;
            }

            // List items → markdown
            if (eqlTag(tag_lower, "li")) {
                if (!last_was_newline and buf.items.len > 0) {
                    try appendNewline(&buf, allocator, &consecutive_newlines);
                }
                try buf.appendSlice(allocator, "- ");
                last_was_newline = false;
                consecutive_newlines = 0;
            }

            // <br> → newline
            if (eqlTag(tag_lower, "br") or eqlTag(tag_lower, "br/") or eqlTag(tag_lower, "br /")) {
                try appendNewline(&buf, allocator, &consecutive_newlines);
                last_was_newline = true;
            }

            // <hr> → separator
            if (eqlTag(tag_lower, "hr") or eqlTag(tag_lower, "hr/") or eqlTag(tag_lower, "hr /")) {
                if (!last_was_newline) try appendNewline(&buf, allocator, &consecutive_newlines);
                try buf.appendSlice(allocator, "---");
                try appendNewline(&buf, allocator, &consecutive_newlines);
                last_was_newline = true;
            }

            // <a href="url">text</a> — extract href for markdown link
            if (eqlTag(tag_lower, "a")) {
                if (extractHref(tag_content)) |href| {
                    // Find closing </a>
                    const close_a = findClosingTag(html, tag_end + 1, "a");
                    if (close_a) |close_pos| {
                        const link_text = std.mem.trim(u8, html[tag_end + 1 .. close_pos.start], " \t\n\r");
                        const clean_text = try stripInnerTags(allocator, link_text);
                        defer allocator.free(clean_text);
                        if (clean_text.len > 0) {
                            try buf.append(allocator, '[');
                            try buf.appendSlice(allocator, clean_text);
                            try buf.appendSlice(allocator, "](");
                            try buf.appendSlice(allocator, href);
                            try buf.append(allocator, ')');
                            last_was_newline = false;
                            consecutive_newlines = 0;
                        }
                        i = close_pos.end;
                        continue;
                    }
                }
            }

            i = tag_end + 1;
            continue;
        }

        // Skip content in script/style
        if (in_script or in_style) {
            i += 1;
            continue;
        }

        // Handle HTML entities
        if (html[i] == '&') {
            const entity_end = std.mem.indexOfScalarPos(u8, html, i + 1, ';');
            if (entity_end) |end| {
                const entity = html[i .. end + 1];
                const decoded = decodeEntity(entity);
                if (decoded) |ch| {
                    try buf.append(allocator, ch);
                    last_was_newline = false;
                    consecutive_newlines = 0;
                    i = end + 1;
                    continue;
                }
            }
        }

        // Regular character
        const c = html[i];
        if (c == '\n' or c == '\r') {
            if (!last_was_newline) {
                try buf.append(allocator, ' ');
            }
        } else if (c == ' ' or c == '\t') {
            // Collapse whitespace
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] != ' ' and !last_was_newline) {
                try buf.append(allocator, ' ');
            }
        } else {
            try buf.append(allocator, c);
            last_was_newline = false;
            consecutive_newlines = 0;
        }

        i += 1;
    }

    // Trim trailing whitespace
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or
        buf.items[buf.items.len - 1] == '\n' or buf.items[buf.items.len - 1] == '\r'))
    {
        _ = buf.pop();
    }

    return buf.toOwnedSlice(allocator);
}

fn appendNewline(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, consecutive: *u32) !void {
    if (consecutive.* < 2) {
        try buf.append(allocator, '\n');
        consecutive.* += 1;
    }
}

fn tagName(content: []const u8) []const u8 {
    var end: usize = 0;
    while (end < content.len and content[end] != ' ' and content[end] != '\t' and
        content[end] != '\n' and content[end] != '/' and content[end] != '>')
    {
        end += 1;
    }
    return content[0..end];
}

fn eqlTag(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

fn isBlockTag(tag: []const u8) bool {
    const block_tags = [_][]const u8{
        "p",     "div",        "section", "article", "main", "header",   "footer", "nav",
        "aside", "blockquote", "pre",     "table",   "tr",   "th",       "td",     "ul",
        "ol",    "dl",         "dt",      "dd",      "form", "fieldset", "figure",
    };
    for (block_tags) |bt| {
        if (eqlTag(tag, bt)) return true;
    }
    return false;
}

fn extractHref(tag_content: []const u8) ?[]const u8 {
    // Find href="..." in tag attributes
    const href_pos = std.mem.indexOf(u8, tag_content, "href=\"") orelse
        std.mem.indexOf(u8, tag_content, "href='") orelse return null;
    const start = href_pos + 6;
    const quote = tag_content[href_pos + 5]; // " or '
    const end = std.mem.indexOfScalarPos(u8, tag_content, start, quote) orelse return null;
    return tag_content[start..end];
}

const ClosingTagPos = struct { start: usize, end: usize };

fn findClosingTag(html: []const u8, from: usize, tag: []const u8) ?ClosingTagPos {
    var pos = from;
    while (pos < html.len) {
        const lt = std.mem.indexOfScalarPos(u8, html, pos, '<') orelse return null;
        if (lt + 2 + tag.len >= html.len) return null;
        if (html[lt + 1] == '/') {
            const after_slash = html[lt + 2 ..];
            if (eqlTag(after_slash[0..@min(tag.len, after_slash.len)], tag)) {
                const gt = std.mem.indexOfScalarPos(u8, html, lt + 2, '>') orelse return null;
                return .{ .start = lt, .end = gt + 1 };
            }
        }
        pos = lt + 1;
    }
    return null;
}

fn stripInnerTags(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            i = end + 1;
        } else {
            try buf.append(allocator, html[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn decodeEntity(entity: []const u8) ?u8 {
    if (std.mem.eql(u8, entity, "&amp;")) return '&';
    if (std.mem.eql(u8, entity, "&lt;")) return '<';
    if (std.mem.eql(u8, entity, "&gt;")) return '>';
    if (std.mem.eql(u8, entity, "&quot;")) return '"';
    if (std.mem.eql(u8, entity, "&apos;")) return '\'';
    if (std.mem.eql(u8, entity, "&nbsp;")) return ' ';
    return null;
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "WebFetchTool name and description" {
    var wft = WebFetchTool{};
    const t = wft.tool();
    try testing.expectEqualStrings("web_fetch", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "WebFetchTool missing url fails" {
    var wft = WebFetchTool{};
    const result = try wft.execute(testing.allocator, "{\"max_chars\":1000}");
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'url' parameter", result.error_msg.?);
}

test "WebFetchTool non-http url fails" {
    var wft = WebFetchTool{};
    const result = try wft.execute(testing.allocator, "{\"url\":\"ftp://example.com\"}");
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Only http:// and https:// URLs are allowed", result.error_msg.?);
}

test "WebFetchTool localhost blocked" {
    var wft = WebFetchTool{};
    const result = try wft.execute(testing.allocator, "{\"url\":\"http://localhost:8080/api\"}");
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Blocked local/private host", result.error_msg.?);
}

test "WebFetchTool private IP blocked" {
    var wft = WebFetchTool{};
    const r1 = try wft.execute(testing.allocator, "{\"url\":\"http://192.168.1.1/\"}");
    try testing.expect(!r1.success);
    const r2 = try wft.execute(testing.allocator, "{\"url\":\"http://10.0.0.1/\"}");
    try testing.expect(!r2.success);
    const r3 = try wft.execute(testing.allocator, "{\"url\":\"http://127.0.0.1/\"}");
    try testing.expect(!r3.success);
}

test "htmlToText strips script and style" {
    const html = "<html><head><style>body{color:red}</style></head><body><script>alert(1)</script>Hello</body></html>";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "alert") == null);
    try testing.expect(std.mem.indexOf(u8, text, "color:red") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Hello") != null);
}

test "htmlToText headings become markdown" {
    const html = "<h1>Title</h1><h2>Subtitle</h2><p>Content</p>";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "# Title") != null);
    try testing.expect(std.mem.indexOf(u8, text, "## Subtitle") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Content") != null);
}

test "htmlToText links become markdown" {
    const html = "<a href=\"https://example.com\">Example</a>";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[Example](https://example.com)", text);
}

test "htmlToText list items" {
    const html = "<ul><li>First</li><li>Second</li></ul>";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "- First") != null);
    try testing.expect(std.mem.indexOf(u8, text, "- Second") != null);
}

test "htmlToText entities decoded" {
    const html = "A &amp; B &lt; C &gt; D";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("A & B < C > D", text);
}

test "htmlToText whitespace normalization" {
    const html = "hello   \n\n\n   world";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    // Multiple whitespace collapsed, newlines become spaces
    try testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "htmlToText br becomes newline" {
    const html = "line1<br>line2<br/>line3";
    const text = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "line1\nline2") != null);
}

test "htmlToText empty input" {
    const text = try htmlToText(testing.allocator, "");
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 0), text.len);
}

test "htmlToText plain text passthrough" {
    const text = try htmlToText(testing.allocator, "Just plain text");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Just plain text", text);
}

test "extractHost parses correctly" {
    try testing.expectEqualStrings("example.com", extractHost("https://example.com/path").?);
    try testing.expectEqualStrings("sub.domain.org", extractHost("http://sub.domain.org?q=1").?);
    try testing.expectEqualStrings("host", extractHost("https://host:8080/").?);
    try testing.expect(extractHost("ftp://nope") == null);
}

test "isLocalHost detects private ranges" {
    try testing.expect(isLocalHost("localhost"));
    try testing.expect(isLocalHost("127.0.0.1"));
    try testing.expect(isLocalHost("10.0.0.1"));
    try testing.expect(isLocalHost("192.168.1.1"));
    try testing.expect(isLocalHost("0.0.0.0"));
    try testing.expect(!isLocalHost("example.com"));
    try testing.expect(!isLocalHost("8.8.8.8"));
}

test "parseMaxChars" {
    try testing.expectEqual(DEFAULT_MAX_CHARS, parseMaxChars("{}"));
    try testing.expectEqual(@as(usize, 1000), parseMaxChars("{\"max_chars\":\"1000\"}"));
    try testing.expectEqual(@as(usize, 100), parseMaxChars("{\"max_chars\":\"10\"}")); // clamped
    try testing.expectEqual(@as(usize, 200_000), parseMaxChars("{\"max_chars\":\"999999\"}")); // clamped
}

test "decodeEntity" {
    try testing.expectEqual(@as(u8, '&'), decodeEntity("&amp;").?);
    try testing.expectEqual(@as(u8, '<'), decodeEntity("&lt;").?);
    try testing.expectEqual(@as(u8, '>'), decodeEntity("&gt;").?);
    try testing.expect(decodeEntity("&unknown;") == null);
}
