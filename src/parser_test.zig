
const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");
const Parser = @import("parser.zig");

fn test_parser(expression: []const u8, expected: []const u8) !void {

    const gpa = std.testing.allocator;

    var diagnostics = Diagnostics.init(gpa);

    var scanner = Scanner.init(gpa, &diagnostics, expression);
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(gpa, &diagnostics, tokens);
    defer parser.deinit();

    const expr = try parser.parse();

    var buffer : [256]u8 = undefined;
    var writer : std.Io.Writer = .fixed(&buffer);

    try expr.write(&writer);

    const end = writer.end;

    try writer.flush();

    try std.testing.expectEqualStrings(buffer[0..end], expected);
}

test "parses expressions" {

    try test_parser("1 + (2 * 3);", "(+ 1 (group (* 2 3)))");

    try test_parser("1 + 2 + 3;", "(+ (+ 1 2) 3)");

    try test_parser("(1 + 4) + (2 * 3);", "(+ (group (+ 1 4)) (group (* 2 3)))");
}
