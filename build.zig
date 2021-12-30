const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const zbs = std.build;

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

/// While a river release is in development, this string should contain the version in development
/// with the "-dev" suffix.
/// When a release is tagged, the "-dev" suffix should be removed for the commit that gets tagged.
/// Directly after the tagged commit, the version should be bumped and the "-dev" suffix added.
const version = "0.2.0-dev";

pub fn build(b: *zbs.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

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

    const xwayland = b.option(
        bool,
        "xwayland",
        "Set to true to enable xwayland support",
    ) orelse false;

    const full_version = blk: {
        if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.execAllowFail(
                &[_][]const u8{ "git", "-C", b.build_root, "describe", "--long" },
                &ret,
                .Inherit,
            ) catch break :blk version;

            var it = mem.split(u8, mem.trim(u8, git_describe_long, &std.ascii.spaces), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk try std.fmt.allocPrintZ(b.allocator, version ++ ".{s}+{s}", .{
                commit_count,
                commit_hash[1..],
            });
        } else {
            break :blk version;
        }
    };

    const options = b.addOptions();
    options.addOption(bool, "xwayland", xwayland);
    options.addOption([]const u8, "version", full_version);

    const scanner = ScanProtocolsStep.create(b);
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-control-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-status-unstable-v1.xml");
    scanner.addProtocolPath("protocol/river-layout-v3.xml");
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addProtocolPath("protocol/wlr-output-power-management-unstable-v1.xml");

    // These must be manually kept in sync with the versions wlroots supports
    // until wlroots gives the option to request a specific version.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);

    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);

    scanner.generate("zriver_control_v1", 1);
    scanner.generate("zriver_status_manager_v1", 3);
    scanner.generate("river_layout_manager_v3", 2);

    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_output_power_manager_v1", 1);

    {
        const river = b.addExecutable("river", "river/main.zig");
        river.setTarget(target);
        river.setBuildMode(mode);
        river.addOptions("build_options", options);

        addServerDeps(river, scanner);

        river.strip = strip;
        river.pie = pie;
        river.install();
    }

    {
        const riverctl = b.addExecutable("riverctl", "riverctl/main.zig");
        riverctl.setTarget(target);
        riverctl.setBuildMode(mode);
        riverctl.addOptions("build_options", options);

        riverctl.step.dependOn(&scanner.step);
        riverctl.addPackagePath("flags", "common/flags.zig");
        riverctl.addPackage(.{
            .name = "wayland",
            .path = .{ .generated = &scanner.result },
        });
        riverctl.linkLibC();
        riverctl.linkSystemLibrary("wayland-client");

        scanner.addCSource(riverctl);

        riverctl.strip = strip;
        riverctl.pie = pie;
        riverctl.install();
    }

    {
        const rivertile = b.addExecutable("rivertile", "rivertile/main.zig");
        rivertile.setTarget(target);
        rivertile.setBuildMode(mode);
        rivertile.addOptions("build_options", options);

        rivertile.step.dependOn(&scanner.step);
        rivertile.addPackagePath("flags", "common/flags.zig");
        rivertile.addPackage(.{
            .name = "wayland",
            .path = .{ .generated = &scanner.result },
        });
        rivertile.linkLibC();
        rivertile.linkSystemLibrary("wayland-client");

        scanner.addCSource(rivertile);

        rivertile.strip = strip;
        rivertile.pie = pie;
        rivertile.install();
    }

    {
        const file = try fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "river-protocols.pc" });
        const pkgconfig_file = try fs.cwd().createFile(file, .{});

        const writer = pkgconfig_file.writer();
        try writer.print(
            \\prefix={s}
            \\datadir=${{prefix}}/share
            \\pkgdatadir=${{datadir}}/river-protocols
            \\
            \\Name: river-protocols
            \\URL: https://github.com/riverwm/river
            \\Description: protocol files for the river wayland compositor
            \\Version: {s}
        , .{ b.install_prefix, full_version });
        defer pkgconfig_file.close();

        b.installFile("protocol/river-layout-v3.xml", "share/river-protocols/river-layout-v3.xml");
        b.installFile(file, "share/pkgconfig/river-protocols.pc");
    }

    if (man_pages) {
        const scdoc_step = ScdocStep.create(b);
        try scdoc_step.install();
    }

    if (bash_completion) {
        b.installFile("completions/bash/riverctl", "share/bash-completion/completions/riverctl");
    }

    if (zsh_completion) {
        b.installFile("completions/zsh/_riverctl", "share/zsh/site-functions/_riverctl");
    }

    if (fish_completion) {
        b.installFile("completions/fish/riverctl.fish", "share/fish/vendor_completions.d/riverctl.fish");
    }

    {
        const river_test = b.addTest("river/test_main.zig");
        river_test.setTarget(target);
        river_test.setBuildMode(mode);
        river_test.addOptions("build_options", options);

        addServerDeps(river_test, scanner);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&river_test.step);
    }
}

fn addServerDeps(exe: *zbs.LibExeObjStep, scanner: *ScanProtocolsStep) void {
    const wayland = zbs.Pkg{
        .name = "wayland",
        .path = .{ .generated = &scanner.result },
    };
    const xkbcommon = zbs.Pkg{
        .name = "xkbcommon",
        .path = .{ .path = "deps/zig-xkbcommon/src/xkbcommon.zig" },
    };
    const pixman = zbs.Pkg{
        .name = "pixman",
        .path = .{ .path = "deps/zig-pixman/pixman.zig" },
    };
    const wlroots = zbs.Pkg{
        .name = "wlroots",
        .path = .{ .path = "deps/zig-wlroots/src/wlroots.zig" },
        .dependencies = &[_]zbs.Pkg{ wayland, xkbcommon, pixman },
    };

    exe.step.dependOn(&scanner.step);

    exe.linkLibC();
    exe.linkSystemLibrary("libevdev");
    exe.linkSystemLibrary("libinput");

    exe.addPackage(wayland);
    exe.linkSystemLibrary("wayland-server");

    exe.addPackage(xkbcommon);
    exe.linkSystemLibrary("xkbcommon");

    exe.addPackage(pixman);
    exe.linkSystemLibrary("pixman-1");

    exe.addPackage(wlroots);
    exe.linkSystemLibrary("wlroots");

    exe.addPackagePath("flags", "common/flags.zig");
    exe.addCSourceFile("river/wlroots_log_wrapper.c", &[_][]const u8{ "-std=c99", "-O2" });

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
            .step = zbs.Step.init(.custom, "Generate man pages", builder.allocator, make),
        };
    }

    fn make(step: *zbs.Step) !void {
        const self = @fieldParentPtr(ScdocStep, "step", step);
        for (scd_paths) |path| {
            const command = try std.fmt.allocPrint(
                self.builder.allocator,
                "scdoc < {s} > {s}",
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
                "share/man/man{s}/{s}",
                .{ section, basename_no_ext },
            );

            self.builder.installFile(path_no_ext, output);
        }
    }
};
