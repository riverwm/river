const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const scan_protocols = ScanProtocolsStep.create(b);

    const exe = b.addExecutable("river", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.step.dependOn(&scan_protocols.step);
    exe.addIncludeDir("protocol");

    exe.addCSourceFile("include/render.c", &[_][]const u8{"-std=c99"});
    exe.addIncludeDir(".");

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

    test_exe.step.dependOn(&scan_protocols.step);
    test_exe.addIncludeDir("protocol");

    test_exe.addCSourceFile("include/render.c", &[_][]const u8{"-std=c99"});
    test_exe.addIncludeDir(".");

    test_exe.linkLibC();
    test_exe.linkSystemLibrary("wayland-server");
    test_exe.linkSystemLibrary("wlroots");
    test_exe.linkSystemLibrary("xkbcommon");

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&test_exe.step);
}

const ScanProtocolsStep = struct {
    builder: *std.build.Builder,
    step: std.build.Step,

    fn create(builder: *std.build.Builder) *ScanProtocolsStep {
        const self = builder.allocator.create(ScanProtocolsStep) catch unreachable;
        self.* = init(builder);
        return self;
    }

    fn init(builder: *std.build.Builder) ScanProtocolsStep {
        return ScanProtocolsStep{
            .builder = builder,
            .step = std.build.Step.init("Scan Protocols", builder.allocator, make),
        };
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(ScanProtocolsStep, "step", step);

        const protocol_dir = std.fmt.trim(try self.builder.exec(
            &[_][]const u8{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" },
        ));

        const protocol_dir_paths = [_][]const []const u8{
            &[_][]const u8{ protocol_dir, "stable/xdg-shell/xdg-shell.xml" },
            &[_][]const u8{ "protocol", "wlr-layer-shell-unstable-v1.xml" },
        };

        for (protocol_dir_paths) |dir_path| {
            const xml_in_path = try std.fs.path.join(self.builder.allocator, dir_path);

            // Extension is .xml, so slice off the last 4 characters
            const basename = std.fs.path.basename(xml_in_path);
            const basename_no_ext = basename[0..(basename.len - 4)];

            const header_out_path = try std.mem.concat(
                self.builder.allocator,
                u8,
                &[_][]const u8{ "protocol/", basename_no_ext, "-protocol.h" },
            );
            const code_out_path = try std.mem.concat(
                self.builder.allocator,
                u8,
                &[_][]const u8{ "protocol/", basename_no_ext, "-protocol.c" },
            );

            _ = try self.builder.exec(
                &[_][]const u8{ "wayland-scanner", "server-header", xml_in_path, header_out_path },
            );
            _ = try self.builder.exec(
                &[_][]const u8{ "wayland-scanner", "private-code", xml_in_path, code_out_path },
            );
        }
    }
};
