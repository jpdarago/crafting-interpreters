const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const EvalError = @import("errors.zig").EvalError;

const Token = Ast.Token;
const Stmt = Ast.Stmt;

pub const NativeFunction = struct {
    arity: u8,
    call: *const fn (*Diagnostics, []const LoxValue) EvalError!LoxValue,
    name: []const u8,
};

pub const LoxFunction = struct {
    arity: u8,
    name: Token,
    params: []Token,
    body: []const *Stmt,
};

pub const LoxCallable = union(enum) {
    const Self = @This();

    native: NativeFunction,
    function: LoxFunction,

    pub fn arity(self: *const Self) u8 {
        return switch (self.*) {
            .native => |native| native.arity,
            .function => |func| func.arity,
        };
    }

    pub fn name(self: *const Self) []const u8 {
        return switch (self.*) {
            .native => |native| native.name,
            .function => |func| func.name.lexeme,
        };
    }
};

pub const LoxValue = union(enum) {
    const Self = @This();

    number: f64,
    boolean: bool,
    string: []const u8,
    callable: LoxCallable,
    nil,

    pub fn write(self: *const Self, writer: *std.io.Writer) !void {
        switch (self.*) {
            .callable => |c| _ = try writer.write(c.name()),
            .number => |n| try writer.print("{d}", .{n}),
            .boolean => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
            .string => |s| _ = try writer.write(s),
            .nil => {
                _ = try writer.write("nil");
            },
        }
    }
};
