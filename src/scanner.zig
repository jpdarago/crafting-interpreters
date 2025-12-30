const std = @import("std");

const Interpreter = @import("interpreter.zig");

pub const TokenType = enum {
  // Single-character tokens.
  LEFT_PAREN, RIGHT_PAREN, LEFT_BRACE, RIGHT_BRACE,
  COMMA, DOT, MINUS, PLUS, SEMICOLON, SLASH, STAR,

  // One or two character tokens.
  BANG, BANG_EQUAL,
  EQUAL, EQUAL_EQUAL,
  GREATER, GREATER_EQUAL,
  LESS, LESS_EQUAL,

  // Literals.
  IDENTIFIER, STRING, NUMBER,

  // Keywords.
  AND, CLASS, ELSE, FALSE, FUN, FOR, IF, NIL, OR,
  PRINT, RETURN, SUPER, THIS, TRUE, VAR, WHILE,

  EOF
};

pub const Token = struct {

    type: TokenType,

    lexeme: []const u8,

    line: usize,

    offset: usize
};


fn is_alpha(character: ?u8) bool {
    const c = character orelse return false;
    if (c >= 'a' and c <= 'z') return true;
    if (c >= 'A' and c <= 'Z') return true;
    if (c == '_') return true;
    return false;
}

fn is_digit(character: ?u8) bool {
    const c = character orelse return false;
    return c >= '0' and c <= '9';
}

fn is_alphanumeric(c: ?u8) bool {
    return is_alpha(c) or is_digit(c);
}


const Self = @This();

allocator: std.mem.Allocator,

interpreter: *Interpreter,

code: []const u8,

// TODO: this representation is super inefficient, all the tokens
// share the same pointer to code, allocator, and most of everything else. 
//
// We should just keep offsets + types in a separate array and construct 
// them implicitly.
tokens: std.ArrayList(Token),

current: usize,

start: usize,

line: usize,

pub fn init(
    allocator: std.mem.Allocator, 
    interpreter: *Interpreter, 
    code: []const u8
) Self {
    return Self {
        .allocator = allocator,
        .interpreter = interpreter,
        .code = code,
        .tokens = .empty,
        .current = 0,
        .start = 0,
        .line = 0
    };
}

pub fn scan(self: *Self) ![]Token {

    while (!self.at_end()) {
        self.start = self.current;
        try self.scan_token();
    }

    return self.tokens.items;
}

pub fn deinit(self: *Self) void {
    self.tokens.deinit(self.allocator);
}

fn at_end(self: *Self) bool {
    return self.current >= self.code.len;
}

fn scan_token(self: *Self) !void {
                
    const c = self.consume() orelse return;

    try switch (c) {
        '(' => self.add_token(.LEFT_PAREN),
        ')' => self.add_token(.RIGHT_PAREN),
        '{' => self.add_token(.LEFT_BRACE),
        '}' => self.add_token(.RIGHT_BRACE),
        ',' => self.add_token(.COMMA),
        '.' => self.add_token(.DOT),
        '-' => self.add_token(.MINUS),
        '+' => self.add_token(.PLUS),
        ';' => self.add_token(.SEMICOLON),
        '*' => self.add_token(.STAR),
        '!' => {
            try self.add_token(if (self.match('=')) .BANG_EQUAL else .BANG);
        },
        '<' => {
            try self.add_token(if (self.match('=')) .LESS_EQUAL else .LESS);
        },
        '>' => {
            try self.add_token(if (self.match('=')) .GREATER_EQUAL else .GREATER);
        },
        '=' => {
            try self.add_token(if (self.match('=')) .BANG_EQUAL else .BANG);
        },
        '/' => {
            if (self.match('/')) {

                while (self.peek()) |v| {
                    if (v == '\n') break;
                    self.advance();
                }

            } else {

                try self.add_token(.SLASH);
            }
        },
        '\t', ' ' => {},
        '\n' => self.line += 1,
        '"' => self.handle_string(),
        else => {

            if (is_digit(c)) {

                try self.handle_number();

            } else if (is_alpha(c)) {

                try self.identifier();

            } else {

                try self.report_error("Unknown token");
            }
        }
    };
}

fn advance(self: *Self) void {
    self.current += 1;
}

fn identifier(self: *Self) !void {

    while (is_alphanumeric(self.peek())) {
        self.advance();
    }

    const KEYWORDS = std.StaticStringMap(TokenType).initComptime(&.{
        .{ "and",    .AND },
        .{ "class",  .CLASS },
        .{ "else",   .ELSE },
        .{ "false",  .FALSE },
        .{ "for",    .FOR },
        .{ "fun",    .FUN },
        .{ "if",     .IF },
        .{ "nil",    .NIL },
        .{ "or",     .OR },
        .{ "print",  .PRINT },
        .{ "return", .RETURN },
        .{ "super",  .SUPER },
        .{ "this",   .THIS },
        .{ "true",   .TRUE },
        .{ "var",    .VAR },
        .{ "while",  .WHILE },
    });

    if (KEYWORDS.get(self.current_chunk())) |keyword| {
        try self.add_token(keyword);
    } else {
        try self.add_token(.IDENTIFIER);
    }
}

fn current_chunk(self: *Self) []const u8 {
    return self.code[self.start..self.current];
}

fn handle_number(self: *Self) !void {

    while (is_digit(self.peek())) {
        self.advance();
    }

    if (self.peek() == '.') {

        if (is_digit(self.peek_next())) {

            self.advance();

            while (is_digit(self.peek())) {
                self.advance();
            }
        }
    }

    try self.add_token(.NUMBER);
}

fn handle_string(self: *Self) !void {
    
    while (self.peek() != '"' and !self.at_end()) {
        if (self.peek() == '\n') self.line += 1;
        self.advance();
    }

    if (self.at_end()) {
        try self.report_error("Unterminated string");
        return;
    }

    self.advance();

    try self.add_token_with_lexeme(.STRING, self.code[self.start+1..self.current-1]);
}

fn report_error(self: *Self, message: []const u8) !void {
    try self.interpreter.report_error(self.line, message);
}

fn consume(self: *Self) ?u8 {

    if (self.current >= self.code.len) {
        return null;
    }

    const result = self.code[self.current];
    self.current += 1;
    return result;
}

fn peek(self: *Self) ?u8 {

    if (self.at_end()) return null;
    return self.code[self.current];
}

fn peek_next(self: *Self) ?u8 {
    
    if (self.current + 1 >= self.code.len) {
        return null;
    }

    return self.code[self.current + 1];
}

fn match(self: *Self, expected: u8) bool {

    if (self.at_end()) return false;
    if (self.code[self.current] != expected) {
        return false;
    }

    self.current += 1;
    return true;
}

fn add_token_with_lexeme(self: *Self, token: TokenType, chunk: []const u8) !void {

    try self.tokens.append(self.allocator, Token { 
        .type = token,
        .lexeme = chunk,
        .line = self.line,
        .offset = self.start
    });
}

fn add_token(self: *Self, token: TokenType) !void {

    const chunk = self.code[self.start..self.current];
    try self.add_token_with_lexeme(token, chunk);
}
