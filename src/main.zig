const std = @import("std");
const crafting_interpreters = @import("crafting_interpreters");

const Stdfile = std.fs.File;

const Token = enum {
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
   
    pub fn reportError(self: *Self, line: i64, message: []const u8) void {
        self.report(line, " ", message);
    }

    pub fn report(self: *Self, line: i64, where: []const u8, message: []const u8) void {
        const stderr = Stdfile.stderr();
        stderr.print("[{s}:{d}] {s}", .{where, line, message});
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
