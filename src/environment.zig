const std = @import("std");

const Ast = @import("ast.zig");

const Errors = @import("errors.zig");

const EvalError = Errors.EvalError;

const Self = @This();

values: std.StringHashMap(Ast.LoxValue),

stores: std.heap.ArenaAllocator,

allocator: std.mem.Allocator,

enclosing: ?*Self,

pub fn init(allocator: std.mem.Allocator, env: ?*Self) Self {
    return Self {
        .allocator = allocator,
        .stores = std.heap.ArenaAllocator.init(allocator),
        .values = std.StringHashMap(Ast.LoxValue).init(allocator),
        .enclosing = env,
    };
}

pub fn deinit(self: *Self) void {
    self.stores.deinit();
    self.values.deinit();
}

pub fn define(self: *Self, name: []const u8, value: Ast.LoxValue) EvalError!void {
    self.values.put(name, value) catch {
        // TODO(jp): Error reporting.
        return EvalError.InternalFailure;
    };
    if (self.enclosing) |enclosing| {
        try enclosing.define(name, value);
    }
}

pub fn lookup(self: *Self, name: []const u8) !Ast.LoxValue {
    if (self.values.get(name)) |val| {
        return val;
    } else if (self.enclosing) |enclosing| {
        return enclosing.lookup(name);
    } else {
        return EvalError.UndefinedVariable;
    }
}
