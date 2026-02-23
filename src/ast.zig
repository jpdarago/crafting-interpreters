const std = @import("std");

const Scanner = @import("scanner.zig");

const Diagnostics = @import("diagnostics.zig");

const EvalError = @import("errors.zig").EvalError;

pub const NativeFunction = struct {
    arity: u8,
    call: *const fn (args: []const LoxValue) EvalError!LoxValue,
    name: []const u8,
};

pub const LoxFunction = struct {
    const Self = @This();

    arity: u8,
    name: Scanner.Token,
    params: []Scanner.Token,
    body: []const *Stmt,

    pub fn call(self: *const Self, diagnostics: *Diagnostics, args: []const LoxValue) EvalError!LoxValue {
        _ = self;
        _ = diagnostics;
        _ = args;

        std.debug.panic("TODO: Not implemented", .{});
    }
};

pub const LoxCallable = union(enum) {
    const Self = @This();

    native: NativeFunction,
    function: LoxFunction,

    pub fn call(self: *const Self, diagnostics: *Diagnostics, args: []const LoxValue) EvalError!LoxValue {
        return switch (self.*) {
            .native => |native| native.call(args),
            .function => |func| func.call(diagnostics, args),
        };
    }

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

const WriteError = error{WriteFailed};

pub const Expr = union(enum) {
    const Ref = @This();

    pub const Binary = struct {
        const Self = @This();

        left: *Ref,

        operator: Scanner.Token,

        right: *Ref,
    };

    pub const Call = struct {
        const Self = @This();

        callee: *Ref,

        paren: Scanner.Token,

        args: std.ArrayList(*Expr),

        allocator: std.mem.Allocator,

        // TODO(jp): Maybe we do not need this and we should instead allocate
        // in the parser the memory for parameters.
        pub fn deinit(self: *Self) void {
            self.args.deinit(self.allocator);
        }
    };

    pub const Grouping = struct {
        const Self = @This();

        expression: *Ref,
    };

    pub const Literal = struct {
        const Self = @This();

        value: LoxValue,
    };

    pub const Unary = struct {
        const Self = @This();

        operator: Scanner.Token,

        expression: *Ref,
    };

    pub const Variable = struct {
        const Self = @This();

        name: Scanner.Token,
    };

    pub const Assign = struct {
        const Self = @This();

        name: Scanner.Token,

        value: *Ref,
    };

    pub const Logical = struct {
        const Self = @This();

        left: *Ref,

        operator: Scanner.Token,

        right: *Ref,
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

    pub fn deinit(self: *Ref) void {
        switch (self.*) {
            .call => |*call| {
                call.deinit();
            },
            else => {},
        }
    }

    pub fn write(self: *const Ref, writer: *std.io.Writer) WriteError!void {
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
            },
            .logical => |logic| {
                _ = try writer.write("(");
                _ = try writer.write(logic.operator.lexeme);
                _ = try writer.write(" ");
                try logic.left.write(writer);
                _ = try writer.write(" ");
                try logic.right.write(writer);
                _ = try writer.write(")");
            },
            .call => |call| {
                _ = try writer.write("(. ");

                try call.callee.write(writer);

                _ = try writer.write("  ");

                const args = call.args;

                for (args.items, 0..) |arg, i| {
                    try arg.write(writer);

                    if (i + 1 < args.items.len) {
                        _ = try writer.write("  ");
                    }
                }
                _ = try writer.write(")");
            },
        }
    }

    binary: Binary,
    call: Call,
    grouping: Grouping,
    literal: Literal,
    unary: Unary,
    variable: Variable,
    assign: Assign,
    logical: Logical,
};

pub const Stmt = union(enum) {
    const Ref = @This();

    pub const Expression = struct {
        const Self = @This();

        expression: *Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) WriteError!void {
            try self.expression.write(writer);
        }
    };

    pub const Print = struct {
        const Self = @This();

        expression: *Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) WriteError!void {
            _ = try writer.write("(print ");
            try self.expression.write(writer);
            _ = try writer.write(")");
        }
    };

    pub const Var = struct {
        const Self = @This();

        name: Scanner.Token,

        initializer: ?*Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) WriteError!void {
            _ = try writer.write("(define ");
            _ = try writer.write(self.name.lexeme);
            _ = try writer.write(" ");
            if (self.initializer) |initializer| {
                try initializer.write(writer);
            }
            _ = try writer.write(")");
        }
    };

    pub const Loop = struct {
        const Self = @This();

        condition: *Expr,

        body: *Stmt,

        pub fn write(self: *const Self, writer: *std.io.Writer) WriteError!void {
            _ = try writer.write("(while ");
            try self.condition.write(writer);
            _ = try writer.write(" ");
            try self.body.write(writer);
            _ = try writer.write(")");
        }
    };

    pub const ForLoop = struct {
        const Self = @This();

        initializer: ?*Stmt,

        condition: ?*Expr,

        body: *Stmt,

        increment: ?*Expr,

        pub fn write(self: *const Self, writer: *std.io.Writer) WriteError!void {
            _ = try writer.write("(for ");
            if (self.initializer) |init| {
                try init.write(writer);
                _ = try writer.write(" ");
            }
            if (self.condition) |condition| {
                try condition.write(writer);
                _ = try writer.write(" ");
            }
            try self.body.write(writer);
            if (self.increment) |increment| {
                try increment.write(writer);
            }
            _ = try writer.write(")");
        }
    };

    pub const Conditional = struct {
        const Self = @This();

        condition: *Expr,

        if_branch: *Stmt,

        else_branch: ?*Stmt,

        allocator: std.mem.Allocator,

        pub fn write(self: *const Self, writer: *std.io.Writer) WriteError!void {
            _ = try writer.write("(if ");
            try self.condition.write(writer);
            _ = try writer.write(" ");
            try self.if_branch.write(writer);
            if (self.else_branch) |else_branch| {
                _ = try writer.write(" ");
                try else_branch.write(writer);
            }
            _ = try writer.write(")");
        }
    };

    pub const Block = struct {
        const Self = @This();

        statements: std.SegmentedList(*Ref, 4),

        allocator: std.mem.Allocator,

        pub fn write(self: *const Self, writer: *std.io.Writer) !void {
            var it = self.statements.constIterator(0);

            while (it.next()) |stmt| {
                try stmt.*.write(writer);
            }
        }

        pub fn deinit(self: *Self) void {
            self.statements.deinit(self.allocator);
        }
    };

    expression: Expression,
    print: Print,
    variable: Var,
    block: Block,
    conditional: Conditional,
    loop: Loop,
    for_loop: ForLoop,

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

    pub fn deinit(self: *Ref) void {
        switch (self.*) {
            .block => |*block| {
                block.deinit();
            },
            else => {},
        }
    }

    pub fn write(self: *const Ref, writer: *std.io.Writer) WriteError!void {
        switch (self.*) {
            .expression => |expr| try expr.write(writer),
            .print => |expr| try expr.write(writer),
            .variable => |variable| try variable.write(writer),
            .block => |block| try block.write(writer),
            .conditional => |cond| try cond.write(writer),
            .loop => |loop| try loop.write(writer),
            .for_loop => |loop| try loop.write(writer),
        }
    }
};

const StatementList = std.SegmentedList(*Stmt, 16);

pub const Program = struct {
    allocator: std.mem.Allocator,

    statements: StatementList,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Program {
        return Self{
            .allocator = allocator,
            .statements = StatementList{},
        };
    }

    pub fn deinit(self: *Self) void {

        // The statement pointers themselves are deallocated by the Parser.

        self.statements.deinit(self.allocator);
    }

    pub fn write(self: *const Self, writer: *std.io.Writer) !void {
        var it = self.statements.constIterator(0);

        var i: usize = 0;

        while (it.next()) |stmt| {
            try stmt.*.write(writer);

            if (i + 1 < self.statements.len) {
                _ = try writer.write("\n");
            }

            i += 1;
        }
    }
};
