const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("river", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.addIncludeDir(".");
    exe.addIncludeDir("protocol");
    exe.addCSourceFile("include/render.c", &[_][]const u8{"-std=c99"});

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("wlroots");
    exe.linkSystemLibrary("xkbcommon");

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the compositor");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest("src/test_main.zig");
    test_exe.setTarget(target);
    test_exe.setBuildMode(mode);

    test_exe.addIncludeDir(".");
    test_exe.addIncludeDir("protocol");
    test_exe.addCSourceFile("include/render.c", &[_][]const u8{"-std=c99"});

    test_exe.linkLibC();
    test_exe.linkSystemLibrary("wayland-server");
    test_exe.linkSystemLibrary("wlroots");
    test_exe.linkSystemLibrary("xkbcommon");

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&test_exe.step);
}
