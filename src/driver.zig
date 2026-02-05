const std = @import("std");

const Ast = @import("ast.zig");

const Diagnostics = @import("diagnostics.zig");

const Scanner = @import("scanner.zig");

const Parser = @import("parser.zig");

const Interpreter = @import("interpreter.zig");

const Self = @This();

const Stdfile = std.fs.File;

allocator: std.mem.Allocator,

diagnostics: *Diagnostics,

pub fn init(allocator: std.mem.Allocator, diagnostics: *Diagnostics) Self {
    return Self {
        .allocator = allocator,
        .diagnostics = diagnostics
    };
}

pub fn run(self: *Self, code: []const u8) !Ast.LoxValue {

    var scanner = Scanner.init(self.allocator, self.diagnostics, code);
    defer scanner.deinit();

    const tokens = try scanner.scan();

    var parser = Parser.init(self.allocator, self.diagnostics, tokens);
    defer parser.deinit();

    var interpreter = Interpreter.init(self.allocator, self.diagnostics, &parser);
    defer interpreter.deinit();

    return try interpreter.evaluate();
}

pub fn run_and_print(self: *Self, code: []const u8) !void {

    const value = try self.run(code);

    var buffer : [1024]u8 = undefined;

    var stdout = Stdfile.stdout().writer(&buffer);

    try value.write(&stdout.interface);
    _ = try stdout.interface.write("\n");

    try stdout.interface.flush();
}

pub fn run_prompt(self: *Self) !void {
    const stdin = Stdfile.stdin();
    const stdout = Stdfile.stdout();

    var buffer : [1024]u8 = undefined;
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

         self.run_and_print(line.written()) catch |err| blk: {
            if (!self.diagnostics.has_errors()) {
                break :blk err;
            }
        } catch |err| return err;
    }

    if (line.written().len > 0) {
        try self.run_and_print(line.written());
    }
}


pub fn run_file(self: *Self, file : []const u8) !void {
    const MAX_SIZE_IN_BYTES = 256 * 1024 * 1024;
    const data = try std.fs.cwd().readFileAlloc(self.allocator, file, MAX_SIZE_IN_BYTES); 
    defer self.allocator.free(data);
    _ = try self.run(data);
    if (self.diagnostics.has_errors()) {
        std.process.exit(65);
    }
}
