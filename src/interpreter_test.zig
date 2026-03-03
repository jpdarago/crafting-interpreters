const std = @import("std");

const Ast = @import("ast.zig");
const Values = @import("values.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");
const Parser = @import("parser.zig");
const Interpreter = @import("interpreter.zig");

fn test_interpreter(expression: []const u8, expected: Values.LoxValue) !void {
    const gpa = std.testing.allocator;

    var diagnostics = Diagnostics.init(gpa);

    var scanner = Scanner.init(gpa, &diagnostics, expression);
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(gpa, &diagnostics, tokens);
    defer parser.deinit();

    var interpreter = try Interpreter.init(gpa, &diagnostics);
    defer interpreter.deinit();

    const value = try interpreter.evaluate(&parser);

    try std.testing.expect(!diagnostics.has_errors());

    try std.testing.expectEqualDeep(expected, value);
}

test "evaluates expressions" {
    try test_interpreter("1 + 2;", Values.LoxValue{ .number = 3 });

    try test_interpreter("1 + 2 * 3;", Values.LoxValue{ .number = 7 });

    try test_interpreter("(1 + 2) * 3;", Values.LoxValue{ .number = 9 });

    try test_interpreter("1 == 1;", Values.LoxValue{ .boolean = true });

    try test_interpreter("1 == 2;", Values.LoxValue{ .boolean = false });

    try test_interpreter("1 != 2;", Values.LoxValue{ .boolean = true });

    try test_interpreter("var a = 1; var b = 2; a + b;", Values.LoxValue{ .number = 3 });

    try test_interpreter("var a = 1; var b = 2; a = 3; a + b;", Values.LoxValue{ .number = 5 });
}
