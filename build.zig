const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("zlib", .{});
    const lib = b.addLibrary(.{
        .name = "z",
        .root_module = b.createModule(.{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &.{
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

    lib.installHeader(upstream.path("zconf.h"), "zconf.h");
    lib.installHeader(upstream.path("zlib.h"), "zlib.h");

    b.installArtifact(lib);
}
