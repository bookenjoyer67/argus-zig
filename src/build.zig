const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s3 },
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    // ESP-IDF header paths for @cImport
    const idf_path = b.option([]const u8, "idf_path", "Path to ESP-IDF") orelse
        b.graph.environ_map.get("IDF_PATH") orelse
        @panic("IDF_PATH not set and --idf_path not passed");

    // Create the root module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add ESP-IDF include paths
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "driver", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "esp_common", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "esp_system", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "esp_hw_support", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "esp_wifi", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "freertos", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "hal", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "log", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "newlib", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "nvs_flash", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "soc", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ idf_path, "components", "bt", "include" }) });

    // NimBLE headers
    const nimble_path = b.pathJoin(&.{ idf_path, "components", "bt", "host", "nimble", "nimble" });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nimble_path, "porting", "nimble", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nimble_path, "nimble", "include" }) });
    lib_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nimble_path, "porting", "esp32", "include" }) });

    // Build static library
    const lib = b.addLibrary(.{
        .name = "argus",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);
}
