const std = @import("std");

const Scanner = @import("scanner.zig");

fn Expression(comptime S: type) type {

    const info = @typeInfo(S);
    if (info != .@"struct") @compileError("UnionFromStruct expects a struct type");

    const s = info.@"struct";

    const UnionField = std.builtin.Type.UnionField;
    const EnumField = std.builtin.Type.EnumField;

    const fields = comptime blk: {
        var uf: [s.fields.len]UnionField = undefined;
        for (s.fields, 0..) |sf, i| {
            uf[i] = .{
                .name = sf.name,       // "int", "str"
                .type = sf.type,       // Integer, String
                .alignment = @alignOf(sf.type),
            };
        }
        break :blk uf;
    };

    const tags = comptime blk: {
        var uf: [s.fields.len]EnumField = undefined;
        for (s.fields, 0..) |sf, i| {
            uf[i] = .{
                .name = sf.name,       
                .value = i,
            };
        }
        break :blk uf;
    };

    const tag_type = @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = &tags,
        .decls = &.{},
        .is_exhaustive = false,
    } });

    const ExprImpl = @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = tag_type,
        .fields = &fields,
        .decls = &.{}
    }});

    return struct {
        const Self = @This();

        value: ExprImpl,

        // TODO(jp): This should probably take a writer to write instead.
        pub fn print(self: *const Self) void {
            switch (self.value) {
                inline else => |*payload| payload.print(),
            }
        }

        pub fn make(x: anytype) Self {
            const T = @TypeOf(x);
            inline for (fields) |f| {
                if (T == f.type) {
                    return .{ .value = @unionInit(ExprImpl, f.name, x) };
                }
            }
            @compileError("Expr.make(): type " ++ @typeName(T) ++ " is not a valid variant");
        }
    };
}

pub const Binary = struct {
    const Self = @This();

    left: *Expr,

    operator: Scanner.Token,
    
    right: *Expr,

    pub fn print(self: *const Self) void {
        self.left.print();
        std.debug.print(" {s} ", .{self.operator.lexeme});
        self.right.print();
    }
};

pub const Grouping = struct {
    const Self = @This();
    
    expression: *Expr,

    pub fn print(self: *const Self) void {
        std.debug.print("(");
        self.expression.print();
        std.debug.print(")");
    }
};

const LoxValue = union(enum) {
    const Self = @This();

    number: f64,
    boolean: bool,
    string: []const u8,
    nil,

    pub fn print(self: *const Self) void {
        switch (self) {
            .number => |n| std.debug.print("{d}", .{n}),
            .boolean => |b| std.debug.print("{s}", .{b}),
            .string => |s| std.debug.print("{s}", .{s}),
            .nil => |n| std.debug.print("nil", .{n}),
        }
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

    expression: Expr,

    pub fn print(self: *const Self) void {
        std.debug.print("{s}", .{self.operator.lexeme});
        self.expression.print();
    }
};

pub const Expr = Expression(struct {
    binary: Binary,
    grouping: Grouping,
    literal: Literal,
    unary: Unary,
});
