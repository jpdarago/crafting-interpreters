const std = @import("std");

const Ast = @import("ast.zig");
const Values = @import("values.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");
const Parser = @import("parser.zig");
const Interpreter = @import("interpreter.zig");
const Resolver = @import("resolver.zig");
const Errors = @import("errors.zig");

fn test_interpreter(expression: []const u8, expected: Values.LoxValue) !void {
    const gpa = std.testing.allocator;

    var diagnostics = Diagnostics.init(gpa);

    var scanner = Scanner.init(gpa, &diagnostics, expression);
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(gpa, &diagnostics, tokens);
    defer parser.deinit();

    var program = try parser.parse();
    defer program.deinit();

    var resolver = try Resolver.init(gpa, &diagnostics);
    defer resolver.deinit();

    try resolver.resolve(&program);

    var interpreter = try Interpreter.init(gpa, &diagnostics);
    defer interpreter.deinit();

    const value = try interpreter.evaluate(&program);

    try std.testing.expect(!diagnostics.has_errors());

    try std.testing.expectEqualDeep(expected, value);
}

fn test_resolver_error(source: []const u8, expected_error: Errors.EvalError) !void {
    const gpa = std.testing.allocator;

    var diagnostics = Diagnostics.init(gpa);

    var scanner = Scanner.init(gpa, &diagnostics, source);
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(gpa, &diagnostics, tokens);
    defer parser.deinit();

    var program = try parser.parse();
    defer program.deinit();

    var resolver = try Resolver.init(gpa, &diagnostics);
    defer resolver.deinit();

    const result = resolver.resolve(&program);

    try std.testing.expectError(expected_error, result);
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

test "resolver: cannot read variable in its own initializer" {
    try test_resolver_error("{ var a = a; }", Errors.EvalError.InvalidExpression);
}

test "resolver: duplicate variable in same scope" {
    try test_resolver_error("{ var a = 1; var a = 2; }", Errors.EvalError.InvalidExpression);
}

test "resolver: cannot return from top-level code" {
    try test_resolver_error("return 1;", Errors.EvalError.InvalidExpression);
}

test "resolver: return inside function is ok" {
    try test_interpreter("fun f() { return 1; } f();", Values.LoxValue{ .number = 1 });
}
