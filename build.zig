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

    // ---- clean ----
    const clean_step = b.step("clean", "Remove build artifacts");
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache", "zig-out" });
    clean_step.dependOn(&clean_cmd.step);

    // ---- examples (run all examples/*.lox sequentially) ----
    const examples_step = b.step("examples", "Run all example .lox files");
    {
        var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect filenames so we can sort them for deterministic order.
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next() catch return) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".lox")) {
                names.append(b.graph.arena, b.dupe(entry.name)) catch return;
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn cmp(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.order(u8, a, c) == .lt;
            }
        }.cmp);

        // Chain: echo header -> run example -> echo header -> run example -> ...
        var prev: ?*std.Build.Step = null;
        for (names.items) |name| {
            const print_cmd = b.addSystemCommand(&.{ "echo", b.fmt("\n=== examples/{s} ===", .{name}) });
            const run = b.addRunArtifact(exe);
            run.addArg(b.fmt("examples/{s}", .{name}));

            // Chain sequentially.
            if (prev) |p| print_cmd.step.dependOn(p);
            run.step.dependOn(&print_cmd.step);
            prev = &run.step;
        }
        if (prev) |p| examples_step.dependOn(p);
    }
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
                    .root_module = b.createModule(.{ .root_source_file = b.path(p), .target = target, .optimize = optimize }),
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
