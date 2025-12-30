const std = @import("std");

const Interpreter = @import("interpreter.zig");

const Scanner = @import("scanner.zig");

const TokenType = Scanner.TokenType;
const Token = Scanner.Token;

fn checkTokens(expected: []const Token, got: []const Token) !void {
    try std.testing.expectEqual(got.len, expected.len);
    for (expected, got) |e, g| {
        try std.testing.expectEqual(e.type, g.type);
        try std.testing.expectEqualStrings(e.lexeme, g.lexeme);
        try std.testing.expectEqual(e.line, g.line);
        try std.testing.expectEqual(e.offset, g.offset);
    }
}

test "expect scanner to handle basic parsing" {
    const gpa = std.testing.allocator;
    var interpreter = Interpreter.init(gpa);
    var scanner = Scanner.init(gpa, &interpreter, "true");
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .TRUE,
            .lexeme = "true",
            .line = 0,
            .offset = 0
        }
    };
    const got = try scanner.scan();
    try checkTokens(&expected, got);
}

test "strings" {
    const gpa = std.testing.allocator;
    var interpreter = Interpreter.init(gpa);
    const code = 
        \\"hola como te va"
    ;
    var scanner = Scanner.init(gpa, &interpreter, code);
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .STRING,
            .lexeme = "hola como te va",
            .line = 0,
            .offset = 0
        }
    };
    const got = try scanner.scan();
    try checkTokens(&expected, got);
}

test "scanning floating point" {
    const gpa = std.testing.allocator;
    
    var interpreter = Interpreter.init(gpa);
    var scanner = Scanner.init(gpa, &interpreter, "12345.993");
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .NUMBER,
            .lexeme = "12345.993",
            .line = 0,
            .offset = 0
        },
    };
    const got = try scanner.scan();
    try checkTokens(&expected, got);
}

test "Loops and stuff" {
    const gpa = std.testing.allocator;
    
    var interpreter = Interpreter.init(gpa);

    const code = 
        \\ while (a < 10) {
        \\   print a;
        \\ }
    ;

    var scanner = Scanner.init(gpa, &interpreter, code);
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .WHILE,
            .lexeme = "while",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .LEFT_PAREN,
            .lexeme = "(",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .IDENTIFIER,
            .lexeme = "a",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .LESS,
            .lexeme = "<",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .NUMBER,
            .lexeme = "10",
            .line = 0,
            .offset = 0
        },
    };
    const got = try scanner.scan();
    try checkTokens(&expected, got);
}

test "scanning numbers and operations" {
    const gpa = std.testing.allocator;
    var interpreter = Interpreter.init(gpa);
    const code = 
        \\(2 + 3 * 5)
    ;
    var scanner = Scanner.init(gpa, &interpreter, code);
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .LEFT_PAREN,
            .lexeme = "(",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .NUMBER,
            .lexeme = "2",
            .line = 0,
            .offset = 1
        },
        .{
            .type = .PLUS,
            .lexeme = "+",
            .line = 0,
            .offset = 3
        },
        .{
            .type = .NUMBER,
            .lexeme = "3",
            .line = 0,
            .offset = 5
        },
        .{
            .type = .STAR,
            .lexeme = "*",
            .line = 0,
            .offset = 7
        },
        .{
            .type = .NUMBER,
            .lexeme = "5",
            .line = 0,
            .offset = 9
        },
        .{
            .type = .RIGHT_PAREN,
            .lexeme = ")",
            .line = 0,
            .offset = 10
        },
    };
    const got = try scanner.scan();
    try checkTokens(&expected, got);
}

test "expect handling multiple lines" {
    const gpa = std.testing.allocator;
    var interpreter = Interpreter.init(gpa);
    var scanner = Scanner.init(gpa, &interpreter, "true and false");
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .TRUE,
            .lexeme = "true",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .AND,
            .lexeme = "and",
            .line = 0,
            .offset = 5
        },
        .{
            .type = .FALSE,
            .lexeme = "false",
            .line = 0,
            .offset = 9
        },
    };
    const got = try scanner.scan();
    try std.testing.expectEqual(got.len, expected.len);
    try checkTokens(&expected, got);
}

test "expect scanner to handle multiple tokens" {
    const gpa = std.testing.allocator;
    var interpreter = Interpreter.init(gpa);
    var scanner = Scanner.init(gpa, &interpreter, "true and false");
    defer scanner.deinit();
    const expected = [_]Token{ 
        .{
            .type = .TRUE,
            .lexeme = "true",
            .line = 0,
            .offset = 0
        },
        .{
            .type = .AND,
            .lexeme = "and",
            .line = 0,
            .offset = 5
        },
        .{
            .type = .FALSE,
            .lexeme = "false",
            .line = 0,
            .offset = 9
        },
    };
    const got = try scanner.scan();
    try checkTokens(&expected, got);
}
