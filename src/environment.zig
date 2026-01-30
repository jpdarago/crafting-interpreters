const std = @import("std");

const Ast = @import("ast.zig");

const Errors = @import("errors.zig");

const Self = @This();

values: std.StringHashMap(Ast.LoxValue),

stores: std.heap.ArenaAllocator,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    return Self {
        .allocator = allocator,
        .stores = std.heap.ArenaAllocator.init(allocator),
        .values = std.StringHashMap(Ast.LoxValue).init(allocator)
    };
}

pub fn deinit(self: *Self) void {
    self.stores.deinit();
    self.values.deinit();
}

pub fn define(self: *Self, name: []const u8, value: Ast.LoxValue) void {
    self.values.put(name, value);
}

pub fn lookup(self: *Self, name: []const u8) !Ast.LoxValue {
    if (self.values.get(name)) |val| {
        return val;
    } else {
        return Errors.EvalError.UndefinedVariable;
    }
}
