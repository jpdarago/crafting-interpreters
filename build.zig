const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- main executable ----
    const exe = b.addExecutable(.{
        .name = "crafting_interpreters",
        // Change this if your entrypoint differs:
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // `zig build run -- [args...]`
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the interpreter");
    run_step.dependOn(&run_cmd.step);

    // ---- tests (auto-discover *_test.zig) ----
    const test_step = b.step("test", "Run all *_test.zig files");
    addTestsRecursive(b, test_step, target, optimize, "src");
}

/// Recursively scan `root_dir` for files ending in "_test.zig", add them via addTest(),
/// and wire them into the "test" step.
fn addTestsRecursive(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_dir: []const u8,
) void {
    const cwd = std.fs.cwd();
    var dir = cwd.openDir(root_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, "_test.zig")) continue;

                const p = b.pathJoin(&.{ root_dir, entry.name });
                const t = b.addTest(.{
                    .name = entry.name,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(p),
                        .target = target,
                        .optimize = optimize
                    }),
                });
                test_step.dependOn(&b.addRunArtifact(t).step);
            },
            .directory => {
                if (std.mem.eql(u8, entry.name, "zig-cache") or
                    std.mem.eql(u8, entry.name, "zig-out") or
                    std.mem.eql(u8, entry.name, ".git"))
                continue;

                // Recurse by opening the subdir and iterating it.
                const sub = b.pathJoin(&.{ root_dir, entry.name });
                addTestsRecursive(b, test_step, target, optimize, sub);
            },
            else => {},
        }
    }
}
