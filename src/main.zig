const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Driver = @import("driver.zig");

const crafting_interpreters = @import("crafting_interpreters");

const TokenType = Ast.TokenType;
const Token = Ast.Token;

const Stdfile = std.fs.File;

const KILOBYTE: usize = 1024;
const MEGABYTE: usize = 1024 * KILOBYTE;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var args = try std.process.argsWithAllocator(arena.allocator());
    defer args.deinit();

    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);

    while (args.next()) |arg| {
        try arguments.append(allocator, std.mem.sliceTo(arg, 0));
    }

    const program_name = if (arguments.items.len > 0) arguments.items[0] else "lox";

    for (arguments.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout_buf: [1024]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            try stdout.print(
                \\Usage: {s} [file]
                \\
                \\A Lox language interpreter.
                \\
                \\Arguments:
                \\  [file]  Path to a Lox script to execute. If omitted, starts an
                \\          interactive REPL.
                \\
                \\Options:
                \\  -h, --help  Show this help message and exit.
                \\
            , .{program_name});
            try stdout.flush();
            std.process.exit(0);
        }
    }

    var diagnostics = Diagnostics.init(allocator);
    var driver = Driver.init(allocator, &diagnostics);

    try switch (arguments.items.len) {
        1 => driver.run_prompt(),
        2 => driver.run_file(arguments.items[1]),
        else => {
            try stderr.print("Usage: {s} [file]\nTry '{s} --help' for more information.\n", .{ program_name, program_name });
            try stderr.flush();
            std.process.exit(64);
        },
    };
}
