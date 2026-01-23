const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");
const Parser = @import("parser.zig");
const Interpreter = @import("interpreter.zig");

fn test_interpreter(expression: []const u8, expected: Ast.LoxValue) !void {

    const gpa = std.testing.allocator;

    var diagnostics = Diagnostics.init(gpa);

    var scanner = Scanner.init(gpa, &diagnostics, expression);
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(gpa, &diagnostics, tokens);
    defer parser.deinit();

    var interpreter = Interpreter.init(gpa, &diagnostics, &parser);

    const value = try interpreter.evaluate();

    try std.testing.expect(!diagnostics.has_errors());

    try std.testing.expectEqualDeep(expected, value);
}


test "evaluates expressions" {

    try test_interpreter("1 + 2", Ast.LoxValue { .number = 3 });

    try test_interpreter("1 + 2 * 3", Ast.LoxValue { .number = 7 });

    try test_interpreter("(1 + 2) * 3", Ast.LoxValue { .number = 9 });

    try test_interpreter("1 == 1", Ast.LoxValue { .boolean = true });

    try test_interpreter("1 == 2", Ast.LoxValue { .boolean = false });

    try test_interpreter("1 != 2", Ast.LoxValue { .boolean = true });
}
