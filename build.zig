const std = @import("std");
const zbs = std.build;

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *zbs.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const xwayland = b.option(
        bool,
        "xwayland",
        "Set to true to enable xwayland support",
    ) orelse false;

    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        _ = b.findProgram(&[_][]const u8{"scdoc"}, &[_][]const u8{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
            else => return err,
        };
        break :scdoc_found true;
    };

    const examples = b.option(bool, "examples", "Set to true to build examples") orelse false;

    // Sigh, why are the conventions inconsistent like this.
    const resolved_prefix = try std.fs.path.resolve(b.allocator, &[_][]const u8{b.install_prefix.?});
    if (std.mem.eql(u8, resolved_prefix, "/usr")) {
        b.installFile("example/init", "../etc/river/init");
    } else {
        b.installFile("example/init", "etc/river/init");
    }

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addProtocolPath("protocol/river-control-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-status-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-output-power-management-unstable-v1.xml");

    {
        const river = b.addExecutable("river", "river/main.zig");
        river.setTarget(target);
        river.setBuildMode(mode);
        river.addBuildOption(bool, "xwayland", xwayland);

        addServerDeps(river, scanner);

        river.install();
    }

    {
        const riverctl = b.addExecutable("riverctl", "riverctl/main.zig");
        riverctl.setTarget(target);
        riverctl.setBuildMode(mode);

        riverctl.step.dependOn(&scanner.step);
        riverctl.addPackage(scanner.getPkg());
        riverctl.linkLibC();
        riverctl.linkSystemLibrary("wayland-client");

        scanner.addCSource(riverctl);

        riverctl.install();
    }

    {
        const rivertile = b.addExecutable("rivertile", "rivertile/main.zig");
        rivertile.setTarget(target);
        rivertile.setBuildMode(mode);
        rivertile.install();
    }

    if (man_pages) {
        const scdoc_step = ScdocStep.create(b);
        try scdoc_step.install();
    }

    if (examples) {
        const status = b.addExecutable("status", "example/status.zig");
        status.setTarget(target);
        status.setBuildMode(mode);

        status.step.dependOn(&scanner.step);
        status.addPackage(scanner.getPkg());
        status.linkLibC();
        status.linkSystemLibrary("wayland-client");

        scanner.addCSource(status);

        status.install();
    }

    {
        const river_test = b.addTest("river/test_main.zig");
        river_test.setTarget(target);
        river_test.setBuildMode(mode);
        river_test.addBuildOption(bool, "xwayland", xwayland);

        addServerDeps(river_test, scanner);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&river_test.step);
    }
}

fn addServerDeps(exe: *zbs.LibExeObjStep, scanner: *ScanProtocolsStep) void {
    const wayland = scanner.getPkg();
    const xkbcommon = zbs.Pkg{ .name = "xkbcommon", .path = "deps/zig-xkbcommon/src/xkbcommon.zig" };
    const pixman = zbs.Pkg{ .name = "pixman", .path = "deps/zig-pixman/pixman.zig" };
    const wlroots = zbs.Pkg{
        .name = "wlroots",
        .path = "deps/zig-wlroots/src/wlroots.zig",
        .dependencies = &[_]zbs.Pkg{ wayland, xkbcommon, pixman },
    };

    exe.step.dependOn(&scanner.step);

    exe.linkLibC();
    exe.linkSystemLibrary("libevdev");

    exe.addPackage(wayland);
    exe.linkSystemLibrary("wayland-server");

    exe.addPackage(xkbcommon);
    exe.linkSystemLibrary("xkbcommon");

    exe.addPackage(pixman);
    exe.linkSystemLibrary("pixman-1");

    exe.addPackage(wlroots);
    exe.linkSystemLibrary("wlroots");

    // TODO: remove when zig issue #131 is implemented
    scanner.addCSource(exe);
}

const ScdocStep = struct {
    const scd_paths = [_][]const u8{
        "doc/river.1.scd",
        "doc/riverctl.1.scd",
        "doc/rivertile.1.scd",
        "doc/river-layouts.7.scd",
    };

    builder: *zbs.Builder,
    step: zbs.Step,

    fn create(builder: *zbs.Builder) *ScdocStep {
        const self = builder.allocator.create(ScdocStep) catch @panic("out of memory");
        self.* = init(builder);
        return self;
    }

    fn init(builder: *zbs.Builder) ScdocStep {
        return ScdocStep{
            .builder = builder,
            .step = zbs.Step.init(.Custom, "Generate man pages", builder.allocator, make),
        };
    }

    fn make(step: *zbs.Step) !void {
        const self = @fieldParentPtr(ScdocStep, "step", step);
        for (scd_paths) |path| {
            const command = try std.fmt.allocPrint(
                self.builder.allocator,
                "scdoc < {} > {}",
                .{ path, path[0..(path.len - 4)] },
            );
            _ = try self.builder.exec(&[_][]const u8{ "sh", "-c", command });
        }
    }

    fn install(self: *ScdocStep) !void {
        self.builder.getInstallStep().dependOn(&self.step);

        for (scd_paths) |path| {
            const path_no_ext = path[0..(path.len - 4)];
            const basename_no_ext = std.fs.path.basename(path_no_ext);
            const section = path_no_ext[(path_no_ext.len - 1)..];

            const output = try std.fmt.allocPrint(
                self.builder.allocator,
                "share/man/man{}/{}",
                .{ section, basename_no_ext },
            );

            self.builder.installFile(path_no_ext, output);
        }
    }
};
