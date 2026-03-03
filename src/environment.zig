const std = @import("std");

const Ast = @import("ast.zig");
const Values = @import("values.zig");

const Errors = @import("errors.zig");

const EvalError = Errors.EvalError;

const Self = @This();

values: std.StringHashMap(Values.LoxValue),

stores: std.heap.ArenaAllocator,

allocator: std.mem.Allocator,

enclosing: ?*Self,

pub fn init(allocator: std.mem.Allocator, env: ?*Self) Self {
    return Self{
        .allocator = allocator,
        .stores = std.heap.ArenaAllocator.init(allocator),
        .values = std.StringHashMap(Values.LoxValue).init(allocator),
        .enclosing = env,
    };
}

pub fn deinit(self: *Self) void {
    self.stores.deinit();
    self.values.deinit();
}

pub fn define(self: *Self, name: []const u8, value: Values.LoxValue) EvalError!void {
    const owned_name = self.stores.allocator().dupe(u8, name) catch {
        return EvalError.InternalFailure;
    };
    self.values.put(owned_name, value) catch {
        return EvalError.InternalFailure;
    };
}

pub fn assign(self: *Self, name: []const u8, value: Values.LoxValue) EvalError!void {
    if (self.values.getEntry(name)) |entry| {
        entry.value_ptr.* = value;
        return;
    }
    if (self.enclosing) |enclosing| {
        try enclosing.assign(name, value);
        return;
    }
    return EvalError.UndefinedVariable;
}

pub fn lookup(self: *Self, name: []const u8) !Values.LoxValue {
    if (self.values.get(name)) |val| {
        return val;
    } else if (self.enclosing) |enclosing| {
        return enclosing.lookup(name);
    } else {
        return EvalError.UndefinedVariable;
    }
}
