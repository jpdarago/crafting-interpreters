const std = @import("std");
const crafting_interpreters = @import("crafting_interpreters");

const Stdfile = std.fs.File;

const TokenType = enum {
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

const Token = struct {

    type: TokenType,

    lexeme: []const u8,

    line: i64,

    offset: i64
};

const Scanner = struct {

    const Self = @This();
    
    allocator: std.Allocator,

    interpreter: *Interpreter,

    code: []const u8,

    // TODO: this representation is super inefficient, all the tokens
    // share the same pointer to code, allocator, and most of everything else. 
    //
    // We should just keep offsets + types in a separate array and construct 
    // them implicitly.
    tokens: std.ArrayList(Token),

    current: i64,

    start: i64,

    line: i64,

    pub fn init(
        allocator: std.Allocator, 
        interpreter: *Interpreter, 
        code: []const u8
    ) Scanner {
        return Scanner {
            .allocator = allocator,
            .interpreter = interpreter,
            .code = code,
            .tokens = .empty,
            .current = 0,
            .start = 0,
            .line = 0
        };
    }

    pub fn scan(self: *Self) []Token {

        while (!self.at_end()) {
            self.start = self.current;
            self.scan_token();
        }

        return self.tokens.items;
    }

    fn at_end(self: *Self) bool {
        return self.current >= self.code.len;
    }

    fn scan_token(self: *Self) void {
                    
        const c = self.consume();

        switch (c) {
            '(' => self.add_token(.LEFT_PAREN),
            ')' => self.add_token(.RIGHT_PAREN),
            '{' => self.add_token(.LEFT_BRACE),
            '}' => self.add_token(.RIGHT_BRACE),
            ',' => self.add_token(.COMMA),
            '.' => self.add_token(.DOT),
            '-' => self.add_token(.MINUS),
            '+' => self.add_token(.PLUS),
            ';' => self.add_token(.SEMICOLON),
            '*' => self.add_token(.START),
            '!' => {
                self.add_token(if (self.match('=')) .BANG_EQUAL else .BANG);
            },
            '<' => {
                self.add_token(if (self.match('=')) .LESS_EQUAL else .LESS);
            },
            '>' => {
                self.add_token(if (self.match('=')) .GREATER_EQUAL else .GREATER);
            },
            '=' => {
                self.add_token(if (self.match('=')) .BANG_EQUAL else .BANG);
            },
            '/' => {
                if (self.match('/')) {

                    while (self.peek()) |v| {
                        if (v == '\n') break;
                        self.advance();
                    }

                } else {

                    self.add_token(.SLASH);
                }
            },
            '\t', ' ' => {},
            '\n' => self.line += 1,
            '"' => self.handle_string(),
            else => {

                if (self.is_digit(c)) {

                    self.handle_number();

                } else if (self.is_alpha(c)) {

                    self.identifier();

                } else {

                    self.report_error("Unknown token");
                }
            }
        }
    }

    fn identifier(self: *Self) void {

        while (self.is_alphanumeric(self.peek())) {
            self.consume();
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
            self.add_token(keyword);
        } else {
            self.add_token(.IDENTIFIER);
        }
    }

    fn current_chunk(self: *Self) []const u8 {
        return self.code[self.start..self.current];
    }

    fn is_alpha(c: u8) bool {
        if (c >= 'a' and c <= 'z') return true;
        if (c >= 'A' and c <= 'Z') return true;
        if (c == '_') return true;
        return false;
    }

    fn is_alphanumeric(c: u8) bool {
        return is_alpha(c) or is_digit(c);
    }

    fn is_digit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn handle_number(self: *Self) void {

        while (true) {
            const c = self.peek();

            if (c < '0' or c > '9') {
                break;
            }

            self.consume();
        }

        if (self.peek() == '.' and self.is_digit(self.peek_next())) {

            self.consume();

            while (self.is_digit(self.peek())) {
                self.advance();
            }
        }

        self.add_token(.NUMBER);
    }

    fn handle_string(self: *Self) void {
        
        while (self.peek() != '"' and !self.at_end()) {
            if (self.peek() == '\n') self.line += 1;
            self.consume();
        }

        if (self.at_end()) {
            self.report_error("Unterminated string");
            return;
        }
    
        self.advance();

        self.add_token(.STRING, self.chunk[self.start+1..self.current-1]);
    }

    fn report_error(self: *Self, message: []const u8) void {
        self.interpreter.report_error(self.line, message);
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

    fn add_token_with_lexeme(self: *Self, token: TokenType, chunk: []const u8) void {

        self.tokens.append(self.allocator, Token { 
            .type = token,
            .lexeme = chunk,
            .line = self.line,
            .offset = self.current
        });
    }

    fn add_token(self: *Self, token: TokenType) void {

        const chunk = self.code[self.start..self.current];
        self.add_token(token, chunk);
    }

    pub fn deinit(self: *Self) void {
        self.tokens.deinit(self.allocator);
    }
};

const Interpreter = struct {

    const Self = @This();

    allocator: std.mem.Allocator,

    had_error: bool,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self {
            .allocator = allocator,
            .had_error = false,
        };
    }
   
    pub fn report_error(self: *Self, line: i64, message: []const u8) void {
        self.report("<inline>", line, "{s}", .{message});
    }

    pub fn report(
        self: *Self, 
        where: []const u8, 
        line: i64, 
        comptime fmt: []const u8, 
        args: anytype
    ) void {
        const writer = Stdfile.stderr().writer();
        try std.fmt.format(writer, "[{s}:{d}]", .{where, line});
        try std.fmt.format(writer, fmt, args);
        self.had_error = true;
    }

    pub fn run(self: *Self, code: []const u8) !void {
        _ = self;
        _ = code;
    }

    pub fn run_prompt(self: *Self) !void {
        const stdin = Stdfile.stdin();
        const stdout = Stdfile.stdout();

        var buffer : [4096]u8 = undefined;
        var in = stdin.reader(&buffer);

        var line = std.Io.Writer.Allocating.init(self.allocator);
        defer line.deinit();

        while (true) {

            try stdout.writeAll("> ");

            line.clearRetainingCapacity();

            _ = in.interface.streamDelimiter(&line.writer, '\n') catch |err| {
                if (err == error.EndOfStream) break else return err;
            };
            _ = in.interface.toss(1);

            try self.run(line.written());
            
            self.had_error = false;
        }

        if (line.written().len > 0) {
            try self.run(line.written());
        }
    }


    fn run_file(self: *Self, file : []const u8) !void {
        const MAX_SIZE_IN_BYTES = 256 * 1024 * 1024;
        const data = try std.fs.cwd().readFileAlloc(self.allocator, file, MAX_SIZE_IN_BYTES); 
        defer self.allocator.free(data);
        try self.run(data);
        if (self.had_error) {
            std.process.exit(65);
        }
    }
};


const KILOBYTE : usize = 1024;
const MEGABYTE : usize = 1024 * KILOBYTE;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var stderr_buf : [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var args = try std.process.argsWithAllocator(arena.allocator());
    defer args.deinit();

    var arguments : std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);

    while (args.next()) |arg| {
        try arguments.append(allocator, std.mem.sliceTo(arg, 0));
    }

    var interpreter = Interpreter.init(allocator);

    try switch (arguments.items.len) {
        1 => interpreter.run_prompt(),
        2 => interpreter.run_file(arguments.items[1]),
        else => {
            try stderr.print("Usage {s} [file]?", .{arguments.items[0]});
            try stderr.flush();
            std.process.exit(64);
        }
    };
}
