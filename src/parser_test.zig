
const std = @import("std");

const Ast = @import("ast.zig");
const Interpreter = @import("interpreter.zig");
const Scanner = @import("scanner.zig");
const Parser = @import("parser.zig");

test "parses comparisons" {
    const gpa = std.testing.allocator;

    var interpreter = Interpreter.init(gpa);

    var scanner = Scanner.init(gpa, &interpreter, "");
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(gpa, &interpreter, tokens);
    defer parser.deinit();

    const expr = try parser.expression();

    var stderr_buffer : [1024]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer).interface;

    try expr.write(&writer);
}
