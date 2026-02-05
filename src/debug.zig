const std = @import("std");

const Stdfile = std.fs.File;

pub fn dump(printable: anytype) !void {

    const P = @TypeOf(printable);

    comptime {

        const ti = @typeInfo(P);

        if (ti != .pointer) {
            @compileError("dump_to_stdout expects a pointer (e.g. &value)");
        }

    }

    const T = @TypeOf(printable.*);

    comptime if (!@hasDecl(T, "write")) {
            @compileError("dump_to_stdout expects a type with a .write method");
    };

    var buffer : [1024]u8 = undefined;

    var stdout = Stdfile.stdout().writer(&buffer);

    try printable.write(&stdout.interface);

    _ = try stdout.interface.write("\n");

    try stdout.interface.flush();
}
