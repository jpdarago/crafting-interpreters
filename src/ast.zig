const std = @import("std");

const Scanner = @import("scanner.zig");

pub const LoxValue = union(enum) {
    const Self = @This();

    number: f64,
    boolean: bool,
    string: []const u8,
    nil,

    pub fn write(self: *const Self, writer: *std.io.Writer) !void {

        switch (self.*) {
            .number => |n| try writer.print("{d}", .{n}),
            .boolean => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
            .string => |s| _ = try writer.write(s),
            .nil => { _ = try writer.write("nil"); },
        }
    }

};

pub const Expr = union(enum) {

    const Ref = @This();

    pub const Binary = struct {
        const Self = @This();

        left: *Ref,

        operator: Scanner.Token,
        
        right: *Ref
    };

    pub const Grouping = struct {
        const Self = @This();
        
        expression: *Ref
    };

    pub const Literal = struct {
        const Self = @This();

        value: LoxValue
    };

    pub const Unary = struct {
        const Self = @This();

        operator: Scanner.Token,

        expression: *Ref
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
                _ = try writer.write("(group ");
                try grp.expression.write(writer);
                _ = try writer.write(")");
            },
            .unary => |un| {
                _ = try writer.write("(");
                _ = try writer.write(un.operator.lexeme);
                _ = try writer.write(" ");
                try un.expression.write(writer);
                _ = try writer.write(")");
            },
            .binary => |bin| {
                _ = try writer.write("(");
                _ = try writer.write(bin.operator.lexeme);
                _ = try writer.write(" ");
                try bin.left.write(writer);
                _ = try writer.write(" ");
                try bin.right.write(writer);
                _ = try writer.write(")");
            }
        }
    }

    binary: Binary,
    grouping: Grouping,
    literal: Literal,
    unary: Unary,
};
