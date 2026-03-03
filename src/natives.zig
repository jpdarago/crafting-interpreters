const std = @import("std");

const Values = @import("values.zig");
const Diagnostics = @import("diagnostics.zig");
const EvalError = @import("errors.zig").EvalError;

pub const builtins = [_]Values.NativeFunction{
    .{ .arity = 0, .name = "clock", .call = clock },
    .{ .arity = 1, .name = "strlen", .call = strlen },
};

fn clock(_: *Diagnostics, _: []const Values.LoxValue) EvalError!Values.LoxValue {
    return Values.LoxValue{
        .number = @floatFromInt(std.time.microTimestamp()),
    };
}

fn strlen(diagnostics: *Diagnostics, args: []const Values.LoxValue) EvalError!Values.LoxValue {
    const val = args[0];

    if (val != .string) {
        diagnostics.report_error(0, "strlen expects a string argument");
        return EvalError.InvalidArguments;
    }

    return Values.LoxValue{
        .number = @floatFromInt(val.string.len),
    };
}
