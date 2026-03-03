const std = @import("std");

const Ast = @import("ast.zig");
const Diagnostics = @import("diagnostics.zig");
const Scanner = @import("scanner.zig");

const ParseError = @import("errors.zig").ParseError;

const Expr = Ast.Expr;
const LoxValue = Ast.LoxValue;
const Program = Ast.Program;
const Stmt = Ast.Stmt;

const Self = @This();

allocator: std.mem.Allocator,

current: usize,

tokens: []const Scanner.Token,

// We use a segmented list to ensure pointer stability.
nodes: std.SegmentedList(Expr, 64),

statements: std.SegmentedList(Stmt, 64),

ast: ?*Expr,

diagnostics: *Diagnostics,

pub fn init(
    allocator: std.mem.Allocator,
    diagnostics: *Diagnostics,
    tokens: []const Scanner.Token,
) Self {
    return Self{
        .allocator = allocator,
        .diagnostics = diagnostics,
        .tokens = tokens,
        .current = 0,
        .nodes = std.SegmentedList(Expr, 64){},
        .statements = std.SegmentedList(Stmt, 64){},
        .ast = null,
    };
}

pub fn deinit(self: *Self) void {
    {
        var it = self.nodes.iterator(0);

        while (it.next()) |node| {
            node.deinit();
        }

        self.nodes.deinit(self.allocator);
    }

    {
        var it = self.statements.iterator(0);

        while (it.next()) |stmt| {
            stmt.deinit();
        }

        self.statements.deinit(self.allocator);
    }
}

pub fn parse(self: *Self) !Program {
    var program = Program.init(self.allocator);

    while (!self.at_end()) {
        const decl = try self.declaration();
        try program.statements.append(self.allocator, decl);
    }

    return program;
}

fn make_node(self: *Self, node: anytype) !*Expr {
    try self.nodes.append(self.allocator, undefined);
    const p = self.nodes.at(self.nodes.len - 1);
    p.* = Expr.make(node);
    return p;
}

fn make_statement(self: *Self, node: anytype) !*Stmt {
    try self.statements.append(self.allocator, undefined);
    const p = self.statements.at(self.statements.len - 1);
    p.* = Stmt.make(node);
    return p;
}

fn declaration(self: *Self) !*Stmt {
    if (self.match(.{.FUNCTION})) {
        return self.function("function");
    }

    if (self.match(.{.VAR})) {
        return self.var_declaration();
    }

    const stmt = self.statement() catch {
        self.synchronize();
        return ParseError.ExpressionExpected;
    };

    return stmt;
}

fn function(self: *Self, kind: []const u8) !*Stmt {
    var buf: [256]u8 = undefined;

    const name = blk: {
        std.fmt.bufPrint(&buf, "Expected {} name.", .{kind});

        break :blk try self.consume(.IDENTIFIER, buf);
    };

    {
        std.fmt.bufPrint(&buf, "Expected '(' after {} name.", .{kind});

        try self.consume(.LEFT_PAREN, buf);
    }

    const parameters = std.SegmentedList(*Stmt, 4){};

    if (!self.check(.LEFT_PAREN)) {
        while (true) {
            if (parameters.len >= 255) {
                self.report_error(self.peek().?, "Too many parameters (> 255).");

                return ParseError.MaximumArgumentsExceeded;
            }

            parameters.append(self.allocator, try self.consume(.IDENTIFIER, "Expected parameter name."));

            if (!self.match(.{.COMMA})) {
                break;
            }
        }
    }

    self.consume(.RIGHT_PAREN, "Expected ')' after parameters.");
}

fn var_declaration(self: *Self) !*Stmt {
    const name = try self.consume(.IDENTIFIER, "Expected variable name");

    var initializer: ?*Ast.Expr = null;

    if (self.match(.{.EQUAL})) {
        initializer = try self.expression();
    }

    _ = try self.consume(.SEMICOLON, "Expect ';' after variable declaration");

    return self.make_statement(Stmt.Var{ .name = name, .initializer = initializer });
}

fn synchronize(self: *Self) void {
    _ = self.advance();

    while (!self.at_end()) {
        if (self.previous().?.type == .SEMICOLON) {
            return;
        }

        switch (self.peek().?.type) {
            .CLASS => return,
            .FUN => return,
            .VAR => return,
            .FOR => return,
            .IF => return,
            .WHILE => return,
            .PRINT => return,
            .RETURN => return,
            else => {},
        }
    }

    _ = self.advance();
}

fn statement(self: *Self) !*Stmt {
    if (self.match(.{.IF})) {
        return self.if_statement();
    }

    if (self.match(.{.FOR})) {
        return self.for_statement();
    }

    if (self.match(.{.WHILE})) {
        return self.loop_statement();
    }

    if (self.match(.{.PRINT})) {
        return self.print_statement();
    }

    if (self.match(.{.LEFT_BRACE})) {
        return self.block();
    }

    return self.expression_statement();
}

fn for_statement(self: *Self) ParseError!*Stmt {
    _ = try self.consume(.LEFT_PAREN, "Expected '(' after 'for'");

    var initializer: ?*Stmt = undefined;

    if (self.match(.{.SEMICOLON})) {
        initializer = null;
    } else if (self.match(.{.VAR})) {
        initializer = try self.var_declaration();
    } else {
        initializer = try self.expression_statement();
    }

    var condition: ?*Expr = undefined;

    if (!self.check(.SEMICOLON)) {
        condition = try self.expression();
    }
    _ = try self.consume(.SEMICOLON, "Expect ';' after loop condition.");

    var increment: ?*Expr = undefined;

    if (!self.check(.RIGHT_PAREN)) {
        increment = try self.expression();
    }
    _ = try self.consume(.RIGHT_PAREN, "Expect ')' after for clauses.");

    const body = try self.statement();

    return self.make_statement(Stmt.ForLoop{ .initializer = initializer, .condition = condition, .increment = increment, .body = body });
}

fn loop_statement(self: *Self) ParseError!*Stmt {
    _ = try self.consume(.LEFT_PAREN, "Expected '(' after 'while'");
    const cond = try self.expression();
    _ = try self.consume(.RIGHT_PAREN, "Expected ')' after if condition");

    const body = try self.statement();

    return self.make_statement(Stmt.Loop{ .condition = cond, .body = body });
}

fn if_statement(self: *Self) ParseError!*Stmt {
    _ = try self.consume(.LEFT_PAREN, "Expected '(' after 'if'");
    const cond = try self.expression();
    _ = try self.consume(.RIGHT_PAREN, "Expected ')' after if condition");

    const if_branch = try self.statement();
    const else_branch: ?*Stmt = if (self.match(.{.ELSE})) try self.statement() else null;

    return self.make_statement(Stmt.Conditional{ .allocator = self.allocator, .condition = cond, .if_branch = if_branch, .else_branch = else_branch });
}

fn block(self: *Self) ParseError!*Stmt {
    var result = Stmt.Block{
        .allocator = self.allocator,
        .statements = std.SegmentedList(*Stmt, 4){},
    };

    while (!self.check(.RIGHT_BRACE) and !self.at_end()) {
        const stmt = try self.declaration();

        try result.statements.append(self.allocator, stmt);
    }

    _ = try self.consume(.RIGHT_BRACE, "Expected '}' after block.");

    return self.make_statement(result);
}

fn print_statement(self: *Self) ParseError!*Stmt {
    const expr = try self.expression();

    _ = try self.consume(.SEMICOLON, "Expected ';' after value");

    return self.make_statement(Stmt.Print{ .expression = expr });
}

pub fn expression_statement(self: *Self) ParseError!*Stmt {
    const expr = try self.expression();

    _ = try self.consume(.SEMICOLON, "Expected ';' after value");

    return self.make_statement(Stmt.Expression{ .expression = expr });
}

fn expression(self: *Self) ParseError!*Expr {
    return self.assignment();
}

fn assignment(self: *Self) ParseError!*Expr {
    const expr = try self.or_expr();

    if (self.match(.{.EQUAL})) {
        const equals = self.previous().?;
        const value = try self.assignment();

        switch (expr.*) {
            .variable => |variable| {
                return self.make_node(Expr.Assign{ .name = variable.name, .value = value });
            },
            else => {},
        }

        self.diagnostics.report_error(equals.line, "Invalid assignment target.");
    }

    return expr;
}

fn or_expr(self: *Self) ParseError!*Expr {
    var expr = try self.and_expr();

    while (self.match(.{.OR})) {
        const operator = self.previous().?;
        const right = try self.and_expr();

        expr = try self.make_node(Expr.Logical{ .left = expr, .operator = operator, .right = right });
    }

    return expr;
}

fn and_expr(self: *Self) ParseError!*Expr {
    var expr = try self.equality();

    while (self.match(.{.AND})) {
        const operator = self.previous().?;
        const right = try self.equality();

        expr = try self.make_node(Expr.Logical{ .left = expr, .operator = operator, .right = right });
    }

    return expr;
}

fn match(self: *Self, comptime args: anytype) bool {
    inline for (args) |tok| {
        if (self.check(tok)) {
            _ = self.advance();
            return true;
        }
    }

    return false;
}

fn check(self: *Self, tok: Scanner.TokenType) bool {
    if (self.peek()) |token| {
        return token.type == tok;
    } else {
        return false;
    }
}

fn at_end(self: *Self) bool {
    return self.current == self.tokens.len;
}

fn peek(self: *Self) ?Scanner.Token {
    if (self.at_end()) return null;
    return self.tokens[self.current];
}

fn consume(self: *Self, token: Scanner.TokenType, message: []const u8) ParseError!Scanner.Token {
    if (self.at_end()) {
        self.diagnostics.report_error(0, message);

        return ParseError.ExpressionExpected;
    }

    if (self.check(token)) {
        return self.advance().?;
    }

    const current = self.peek().?;

    self.diagnostics.report_error(current.line, message);

    return ParseError.UnexpectedToken;
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

fn equality(self: *Self) ParseError!*Expr {
    var expr = try self.comparison();

    while (self.match(.{ .BANG_EQUAL, .EQUAL_EQUAL })) {
        const operator = self.previous().?;
        const right = try self.comparison();

        expr = try self.make_node(Expr.Binary{ .left = expr, .operator = operator, .right = right });
    }

    return expr;
}

fn comparison(self: *Self) ParseError!*Expr {
    var expr = try self.term();

    while (self.match(.{ .GREATER, .GREATER_EQUAL, .LESS, .LESS_EQUAL })) {
        const operator = self.previous().?;
        const right = try self.term();

        expr = try self.make_node(Expr.Binary{ .left = expr, .operator = operator, .right = right });
    }

    return expr;
}

fn term(self: *Self) ParseError!*Expr {
    var expr = try self.factor();

    while (self.match(.{ .MINUS, .PLUS })) {
        const operator = self.previous().?;
        const right = try self.factor();

        expr = try self.make_node(Expr.Binary{ .left = expr, .operator = operator, .right = right });
    }

    return expr;
}

fn factor(self: *Self) ParseError!*Expr {
    var expr = try self.unary();

    while (self.match(.{ .SLASH, .STAR })) {
        const operator = self.previous().?;
        const right = try self.unary();

        expr = try self.make_node(Expr.Binary{ .left = expr, .operator = operator, .right = right });
    }

    return expr;
}

fn unary(self: *Self) ParseError!*Expr {
    if (self.match(.{ .BANG, .MINUS })) {
        const operator = self.previous();
        const right = try self.unary();

        return self.make_node(Expr.Unary{ .operator = operator.?, .expression = right });
    }

    return self.call();
}

fn call(self: *Self) ParseError!*Expr {
    var expr = try self.primary();

    while (true) {
        if (self.match(.{.LEFT_PAREN})) {
            expr = try self.finish_call(expr);
        } else {
            break;
        }
    }

    return expr;
}

fn finish_call(self: *Self, callee: *Ast.Expr) ParseError!*Expr {
    var args: std.ArrayList(*Ast.Expr) = .empty;

    if (!self.check(.RIGHT_PAREN)) {
        while (true) {
            if (args.items.len >= 255) {
                self.diagnostics.report_error(self.peek().?.line, "Too many arguments (max supported is 255)");
            }
            try args.append(self.allocator, try self.expression());
            if (!self.match(.{.COMMA})) {
                break;
            }
        }
    }

    const paren = try self.consume(.RIGHT_PAREN, "Expected ')' after arguments");

    return self.make_node(Expr.Call{ .allocator = self.allocator, .args = args, .callee = callee, .paren = paren });
}

fn primary(self: *Self) ParseError!*Expr {
    if (self.match(.{.FALSE})) {
        const value = LoxValue{ .boolean = false };

        return self.make_node(Expr.Literal{ .value = value });
    }

    if (self.match(.{.TRUE})) {
        const value = LoxValue{ .boolean = true };

        return self.make_node(Expr.Literal{ .value = value });
    }

    if (self.match(.{.NIL})) {
        const value: LoxValue = .nil;

        return self.make_node(Expr.Literal{ .value = value });
    }

    if (self.match(.{.NUMBER})) {
        const token = self.previous().?;

        const fp = std.fmt.parseFloat(f64, token.lexeme) catch {
            self.diagnostics.report("<inline>", token.line, "Unparseable float [{s}]", .{token.lexeme});
            return ParseError.FloatError;
        };

        const value = LoxValue{ .number = fp };

        return self.make_node(Expr.Literal{ .value = value });
    }

    if (self.match(.{.STRING})) {
        const token = self.previous().?;

        const value = LoxValue{ .string = token.lexeme };

        return self.make_node(Expr.Literal{ .value = value });
    }

    if (self.match(.{.IDENTIFIER})) {
        const token = self.previous().?;

        return self.make_node(Expr.Variable{ .name = token });
    }

    if (self.match(.{.LEFT_PAREN})) {
        const expr = try self.expression();

        _ = try self.consume(.RIGHT_PAREN, "Expect ')' after expression.");

        return self.make_node(Expr.Grouping{ .expression = expr });
    }

    if (self.previous()) |prev| {
        self.diagnostics.report_error(prev.line, "Expected expression");
    } else {
        self.diagnostics.report("<eof>", 0, "Expected expression", .{});
    }

    return ParseError.ExpressionExpected;
}
