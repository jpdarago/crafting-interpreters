const std = @import("std");

const Self = @This();

const Stdfile = std.fs.File;

allocator: std.mem.Allocator,

had_error: bool,

pub fn init(allocator: std.mem.Allocator) Self {
    return Self {
        .allocator = allocator,
        .had_error = false,
    };
}

pub fn report_error(self: *Self, line: usize, message: []const u8) void {
    self.report("<inline>", line, "{s}", .{message});
}

pub fn report(
    self: *Self, 
    where: []const u8, 
    line: usize, 
    comptime fmt: []const u8, 
    args: anytype
) void {
    var stderr_buffer : [1024]u8 = undefined;
    const buf = std.fmt.bufPrint(&stderr_buffer, "[{s}:{d}] " ++ fmt ++ "\n", .{where, line} ++ args) catch |err| {
        std.debug.panic("Broken bufprint: {s}", .{@errorName(err)});
    };
    _ = Stdfile.stderr().write(buf) catch |err| {
        std.debug.panic("Broken stderr stream: {s}", .{@errorName(err)});
    };
    self.had_error = true;
}

pub fn has_errors(self: *const Self) bool {
    return self.had_error;
}
