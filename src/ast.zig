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

    pub const Variable = struct {
        const Self = @This();

        name: Scanner.Token,
    };
    
    pub const Assign = struct {
        const Self = @This();

        name: Scanner.Token,
        
        value: *Ref
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
            },
            .variable => |variable| {
                _ = try writer.write(variable.name.lexeme);
            },
            .assign => |assign| {
                _ = try writer.write("(set ");
                _ = try writer.write(assign.name.lexeme);
                _ = try writer.write(" ");
                try assign.value.write(writer);
                _ = try writer.write(")");
            }
        }
    }

    binary: Binary,
    grouping: Grouping,
    literal: Literal,
    unary: Unary,
    variable: Variable,
    assign: Assign
};

pub const Stmt = union(enum) {
       
    const Ref = @This();

    pub const Expression = struct {
        const Self = @This();

        expression: *Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) !void {
            try self.expression.write(writer);
        }
    };

    pub const Print = struct {
        const Self = @This();

        expression: *Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) !void {
            _ = try writer.write("(print ");
            try self.expression.write(writer);
            _ = try writer.write(")");
        }
    };

    pub const Var = struct {
        const Self = @This();

        name: Scanner.Token,

        initializer: ?*Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) !void {
            _ = try writer.write("(define ");
            _ = try writer.write(self.name.lexeme);
            _ = try writer.write(" ");
            if (self.initializer) |initializer| {
                try initializer.write(writer);
            }
            _ = try writer.write(")");
        }
    };

    expression: Expression,
    print: Print,
    variable: Var,

    pub fn write(self: *const Ref, writer: *std.io.Writer) !void {
        switch (self.*) {
            .expression => |expr| try expr.write(writer),
            .print => |expr| try expr.write(writer),
            .variable => |variable| try variable.write(writer)
        }
    }
};

const StatementList = std.SegmentedList(Stmt, 16);

pub const Program = struct {

    allocator: std.mem.Allocator,

    statements: StatementList,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Program {

        return Self {
            .allocator = allocator,
            .statements = StatementList {},
        };
    }

    pub fn deinit(self: *Self) void {
        self.statements.deinit(self.allocator);
    }

    pub fn write(self: *const Self, writer: *std.io.Writer) !void {

        var it = self.statements.constIterator(0);

        var i : usize = 0;

        while (it.next())  |stmt| {
            try stmt.write(writer);

            if (i + 1 < self.statements.len) {
                _ = try writer.write("\n");
            }

            i += 1;
        }
    }
};
