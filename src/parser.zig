const std = @import("std");

const Scanner = @import("scanner.zig");

const Ast = @import("ast.zig");

const Self = @This();

allocator: std.mem.Allocator,

current: usize,

tokens: []const Scanner.Token,

nodes: std.ArrayList(Ast.Expr),

ast: *Ast.Expr,

pub fn init(
    allocator: std.mem.Allocator, 
    tokens: []const Scanner.Token
) void {
    return Self {
        .allocator = allocator,
        .tokens = tokens,
        .current = 0,
        .nodes = .empty,
        .ast = null,
    };
}

pub fn expression(self: *Self) !Ast.Expr {
    return self.equality();
}

fn equality(self: *Self) !Ast.Expr {
    var expr = self.comparison();

    while (self.match(.{.BANG_EQUAL, .EQUAL_EQUAL})) {
        const operator = self.previous();
        const right = self.comparison();
        try self.nodes.append(self.allocator, Ast.Expr.make( Ast.Binary {
            expr, operator, right 
        }));
        expr = &self.nodes.getLast();
    }
    return expr;
}

fn match(self: *Self, args: []const Scanner.Token) bool {
    for (args) |tok| {
        if (self.check(tok)) {
            self.advance();
            return true;
        }
    } 

    return false;
}

fn at_end(self: *Self) bool {
    return self.current == self.tokens.len;
}

fn peek(self: *Self) ?Scanner.Token {
    if (self.at_end()) return null;
    return self.tokens[self.current];
}

fn previous(self: *Self) ?Scanner.Token {
    if (self.current == 0) return null;
    return self.tokens[self.current - 1];
}

fn advance(self: *Self) ?Scanner.Token {
    if (!self.at_end()) {
        self.current += 1;
    }
    return self.previous();
}
