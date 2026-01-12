const std = @import("std");

const Scanner = @import("scanner.zig");

pub const LoxValue = union(enum) {
    const Self = @This();

    number: f64,
    boolean: bool,
    string: []const u8,
    nil,

    pub fn write(self: *const Self, writer: *std.io.Writer) void {

        switch (self.*) {
            .number => |n| writer.print("{d}", .{n}),
            .boolean => |b| writer.print("{b}", .{b}),
            .string => |s| writer.print("{s}", .{s}),
            .nil => |_| writer.print("nil"),
        }
    }

};

pub const Expr = union(enum) {

    const Ref = @This();

    pub const Binary = struct {
        const Self = @This();

        left: *Ref,

        operator: Scanner.Token,
        
        right: *Ref,

        pub fn print(self: *const Self) void {
            self.left.print();
            std.debug.print(" {s} ", .{self.operator.lexeme});
            self.right.print();
        }
    };

    pub const Grouping = struct {
        const Self = @This();
        
        expression: *Ref,

        pub fn print(self: *const Self) void {
            std.debug.print("(");
            self.expression.print();
            std.debug.print(")");
        }
    };

    pub const Literal = struct {
        const Self = @This();

        value: LoxValue,

        pub fn print(self: *const Self) void {
            self.value.print();
        }
    };

    pub const Unary = struct {
        const Self = @This();

        operator: Scanner.Token,

        expression: *Ref,

        pub fn print(self: *const Self) void {
            std.debug.print("{s}", .{self.operator.lexeme});
            self.expression.print();
        }
    };

    pub fn make(value: anytype) Ref {
        const T = @TypeOf(value);

        const ui = @typeInfo(Ref);

        inline for (ui.@"union".fields) |f| {
            if (T == f.type) {
                return @unionInit(Ref, f.name, value);
            }
        }

        @compileError("Expr.make: type " ++ @typeName(T) ++ " is not a valid Expr variant");
    }

    pub fn write(self: *const Ref, writer: *std.io.Writer) !void {

        switch (self.*) {
            .literal => |lit| {
                try lit.value.write(writer);
            },
            .grouping => |grp| {
                try writer.write("(");
                try grp.expression.write(writer);
                try writer.write(")");
            },
            .unary => |un| {
                try writer.write(un.operator.lexeme);
                try un.expression.write(un.expression);
            },
            .binary => |bin| {
                try bin.left.write(writer);
                try writer.write(bin.operator);
                try bin.right.write(writer);
            }
        }
    }

    binary: Binary,
    grouping: Grouping,
    literal: Literal,
    unary: Unary,
};

