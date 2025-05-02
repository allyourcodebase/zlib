const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Build artifacts that run in single threaded mode");

    const upstream = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = single_threaded,
    });
    lib_mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &[_][]const u8{
            "adler32.c",
            "crc32.c",
            "deflate.c",
            "infback.c",
            "inffast.c",
            "inflate.c",
            "inftrees.c",
            "trees.c",
            "zutil.c",
            "compress.c",
            "uncompr.c",
            "gzclose.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
        },
        .flags = &.{
            "-DHAVE_SYS_TYPES_H",
            "-DHAVE_STDINT_H",
            "-DHAVE_STDDEF_H",
            "-DZ_HAVE_UNISTD_H",
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "z",
        .root_module = lib_mod,
    });
    lib.installHeadersDirectory(upstream.path(""), "", .{
        .include_extensions = &.{
            "zconf.h",
            "zlib.h",
        },
    });
    b.installArtifact(lib);

    const dynamic_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "z",
        .root_module = lib_mod,
    });
    // Install with no version extension
    b.installArtifact(dynamic_lib);
    // Install with version extension
    const output_name = b.fmt("libz{s}.{s}", .{
        dynamic_lib.root_module.resolved_target.?.result.dynamicLibSuffix(),
        "1.3.1",
    });
    const install_step = b.addInstallArtifact(dynamic_lib, .{
        .dest_dir = .{
            .override = .lib,
        },
        .dest_sub_path = output_name,
    });
    b.getInstallStep().dependOn(&install_step.step);
}
