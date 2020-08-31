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

    const examples = b.option(
        bool,
        "examples",
        "Set to true to build examples",
    ) orelse false;

    const scan_protocols = ScanProtocolsStep.create(b);

    {
        const river = b.addExecutable("river", "river/main.zig");
        river.setTarget(target);
        river.setBuildMode(mode);
        river.addBuildOption(bool, "xwayland", xwayland);

        addProtocolDeps(river, &scan_protocols.step);
        addServerDeps(river);

        river.install();

        const run_cmd = river.run();
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run", "Run the compositor");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const riverctl = b.addExecutable("riverctl", "riverctl/main.zig");
        riverctl.setTarget(target);
        riverctl.setBuildMode(mode);

        addProtocolDeps(riverctl, &scan_protocols.step);

        riverctl.linkLibC();
        riverctl.linkSystemLibrary("wayland-client");

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

        addProtocolDeps(status, &scan_protocols.step);

        status.linkLibC();
        status.linkSystemLibrary("wayland-client");

        status.install();
    }

    {
        const river_test = b.addTest("river/test_main.zig");
        river_test.setTarget(target);
        river_test.setBuildMode(mode);
        river_test.addBuildOption(bool, "xwayland", xwayland);

        addProtocolDeps(river_test, &scan_protocols.step);
        addServerDeps(river_test);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&river_test.step);
    }
}

fn addServerDeps(exe: *std.build.LibExeObjStep) void {
    exe.addCSourceFile("include/bindings.c", &[_][]const u8{"-std=c99"});
    exe.addIncludeDir(".");

    exe.linkLibC();
    exe.linkSystemLibrary("libevdev");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("wlroots");
    exe.linkSystemLibrary("xkbcommon");
}

fn addProtocolDeps(exe: *std.build.LibExeObjStep, protocol_step: *std.build.Step) void {
    exe.step.dependOn(protocol_step);
    exe.addIncludeDir("protocol");
    exe.addCSourceFile("protocol/river-control-unstable-v1-protocol.c", &[_][]const u8{"-std=c99"});
    exe.addCSourceFile("protocol/river-status-unstable-v1-protocol.c", &[_][]const u8{"-std=c99"});
}

const ScanProtocolsStep = struct {
    builder: *std.build.Builder,
    step: std.build.Step,

    fn create(builder: *std.build.Builder) *ScanProtocolsStep {
        const self = builder.allocator.create(ScanProtocolsStep) catch @panic("out of memory");
        self.* = init(builder);
        return self;
    }

    fn init(builder: *std.build.Builder) ScanProtocolsStep {
        return ScanProtocolsStep{
            .builder = builder,
            .step = std.build.Step.init(.Custom, "Scan Protocols", builder.allocator, make),
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
            &[_][]const u8{ "protocol", "river-control-unstable-v1.xml" },
            &[_][]const u8{ "protocol", "river-status-unstable-v1.xml" },
        };

        const server_protocols = [_][]const u8{
            "xdg-shell",
            "wlr-layer-shell-unstable-v1",
            "river-control-unstable-v1",
            "river-status-unstable-v1",
        };

        const client_protocols = [_][]const u8{
            "river-control-unstable-v1",
            "river-status-unstable-v1",
        };

        for (protocol_dir_paths) |dir_path| {
            const xml_in_path = try std.fs.path.join(self.builder.allocator, dir_path);

            // Extension is .xml, so slice off the last 4 characters
            const basename = std.fs.path.basename(xml_in_path);
            const basename_no_ext = basename[0..(basename.len - 4)];

            const code_out_path = try std.mem.concat(
                self.builder.allocator,
                u8,
                &[_][]const u8{ "protocol/", basename_no_ext, "-protocol.c" },
            );
            _ = try self.builder.exec(
                &[_][]const u8{ "wayland-scanner", "private-code", xml_in_path, code_out_path },
            );

            for (server_protocols) |server_protocol| {
                if (std.mem.eql(u8, basename_no_ext, server_protocol)) {
                    const header_out_path = try std.mem.concat(
                        self.builder.allocator,
                        u8,
                        &[_][]const u8{ "protocol/", basename_no_ext, "-protocol.h" },
                    );
                    _ = try self.builder.exec(
                        &[_][]const u8{ "wayland-scanner", "server-header", xml_in_path, header_out_path },
                    );
                }
            }

            for (client_protocols) |client_protocol| {
                if (std.mem.eql(u8, basename_no_ext, client_protocol)) {
                    const header_out_path = try std.mem.concat(
                        self.builder.allocator,
                        u8,
                        &[_][]const u8{ "protocol/", basename_no_ext, "-client-protocol.h" },
                    );
                    _ = try self.builder.exec(
                        &[_][]const u8{ "wayland-scanner", "client-header", xml_in_path, header_out_path },
                    );
                }
            }
        }
    }
};

const ScdocStep = struct {
    const scd_paths = [_][]const u8{
        "doc/river.1.scd",
        "doc/riverctl.1.scd",
        "doc/rivertile.1.scd",
        "doc/river-layouts.7.scd",
    };

    builder: *std.build.Builder,
    step: std.build.Step,

    fn create(builder: *std.build.Builder) *ScdocStep {
        const self = builder.allocator.create(ScdocStep) catch @panic("out of memory");
        self.* = init(builder);
        return self;
    }

    fn init(builder: *std.build.Builder) ScdocStep {
        return ScdocStep{
            .builder = builder,
            .step = std.build.Step.init(.Custom, "Generate man pages", builder.allocator, make),
        };
    }

    fn make(step: *std.build.Step) !void {
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
