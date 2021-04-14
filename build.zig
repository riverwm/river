const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
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

    const bash_completion = b.option(
        bool,
        "bash-completion",
        "Set to true to install bash completion for riverctl. Defaults to true.",
    ) orelse true;

    const zsh_completion = b.option(
        bool,
        "zsh-completion",
        "Set to true to install zsh completion for riverctl. Defaults to true.",
    ) orelse true;

    const fish_completion = b.option(
        bool,
        "fish-completion",
        "Set to true to install fish completion for riverctl. Defaults to true.",
    ) orelse true;

    const examples = b.option(bool, "examples", "Set to true to build examples") orelse false;

    // This logic must match std.build.resolveInstallPrefix()
    const prefix = b.install_prefix orelse if (b.dest_dir) |_| "/usr" else b.cache_root;
    const rel_config_path = if (mem.eql(u8, try fs.path.resolve(b.allocator, &[_][]const u8{prefix}), "/usr"))
        "../etc/river/init"
    else
        "etc/river/init";
    b.installFile("example/init", rel_config_path);
    const abs_config_path = try fs.path.resolve(b.allocator, &[_][]const u8{ prefix, rel_config_path });
    assert(fs.path.isAbsolute(abs_config_path));

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-control-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-options-v2.xml");
    scanner.addProtocolPath("protocol/river-status-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-layout-v1.xml");
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-output-power-management-unstable-v1.xml");

    {
        const river = b.addExecutable("river", "river/main.zig");
        river.setTarget(target);
        river.setBuildMode(mode);
        river.addBuildOption(bool, "xwayland", xwayland);
        river.addBuildOption([]const u8, "default_config_path", abs_config_path);

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

        rivertile.step.dependOn(&scanner.step);
        rivertile.addPackage(scanner.getPkg());
        rivertile.linkLibC();
        rivertile.linkSystemLibrary("wayland-client");

        scanner.addCSource(rivertile);

        rivertile.install();
    }

    if (man_pages) {
        const scdoc_step = ScdocStep.create(b);
        try scdoc_step.install();
    }

    if (bash_completion) {
        b.installFile(
            "completions/bash/riverctl",
            "share/bash-completion/completions/riverctl",
        );
    }

    if (zsh_completion) {
        b.installFile(
            "completions/zsh/_riverctl",
            "share/zsh/site-functions/_riverctl",
        );
    }

    if (fish_completion) {
        b.installFile(
            "completions/fish/riverctl.fish",
            "share/fish/vendor_completions.d/riverctl.fish",
        );
    }

    if (examples) {
        inline for (.{ "status", "options" }) |example_name| {
            const example = b.addExecutable(example_name, "example/" ++ example_name ++ ".zig");
            example.setTarget(target);
            example.setBuildMode(mode);

            example.step.dependOn(&scanner.step);
            example.addPackage(scanner.getPkg());
            example.linkLibC();
            example.linkSystemLibrary("wayland-client");

            scanner.addCSource(example);

            example.install();
        }
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
            const basename_no_ext = fs.path.basename(path_no_ext);
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
