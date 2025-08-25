const std = @import("std");
const Io = std.Io;
const Self = @This();
const Deflater = Self;
const Container = std.compress.flate.Container;
const Decompress = std.compress.flate.Decompress;
const zlib = @import("zlib_h");

const CHUNKSIZE = 16 * 1024;

arena: *std.heap.ArenaAllocator,
zstream_initialized: bool,
container: Container,
level: u4,
zstream: zlib.z_stream,
outbuf: []u8,
underlying_writer: *std.io.Writer,
writer: std.io.Writer,

pub const Options = struct {
    allocator: std.mem.Allocator,
    level: u4 = 9,
    writer: *std.io.Writer,
    container: Container,
};

pub fn init(opt: Self.Options) !Self {
    const arena = try opt.allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(opt.allocator);
    return .{
        .arena = arena,
        .zstream_initialized = false,
        .container = opt.container,
        .level = opt.level,
        .zstream = .{
            .zalloc = &zalloc,
            .zfree = &zfree,
            .@"opaque" = null,
            .next_in = zlib.Z_NULL,
            .avail_in = 0,
            .next_out = zlib.Z_NULL,
            .avail_out = 0,
            .data_type = zlib.Z_BINARY,
        },
        .outbuf = try arena.allocator().alloc(u8, CHUNKSIZE),
        .writer = .{
            .buffer = try arena.allocator().alloc(u8, CHUNKSIZE),
            .vtable = &.{
                .drain = drain,
                .flush = flush,
                .sendFile = sendFile,
            },
        },
        .underlying_writer = opt.writer,
    };
}

pub fn deinit(self: *Self) void {
    const alloc = self.arena.child_allocator;
    self.arena.deinit();
    alloc.destroy(self.arena);
}

fn zalloc(ctx: ?*anyopaque, count: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
    const self: *Self = @ptrCast(@alignCast(ctx.?));
    return (self.arena.allocator().alloc(u1, count * size) catch {
        return null;
    }).ptr;
}

fn zfree(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

inline fn zStreamInit(self: *@This()) !void {
    if (!self.zstream_initialized) {
        self.zstream.@"opaque" = self;
        try zLibError(zlib.deflateInit2(
            &self.zstream,
            self.level,
            zlib.Z_DEFLATED,
            @as(c_int, switch (self.container) {
                .raw => -1 * zlib.MAX_WBITS,
                .gzip => 16 + zlib.MAX_WBITS,
                .zlib => zlib.MAX_WBITS,
            }),
            zlib.MAX_MEM_LEVEL,
            zlib.Z_DEFAULT_STRATEGY,
        ));
        self.zstream_initialized = true;
    }
}

fn drain(wr: *Io.Writer, blobs: []const []const u8, splat: usize) error{WriteFailed}!usize {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zStreamInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    try self.zdrain(wr.buffered(), zlib.Z_NO_FLUSH);
    wr.end = 0;

    var count: usize = 0;
    for (blobs, 1..) |blob, i| {
        var splat_i: usize = 0;
        while ((i != blobs.len and splat_i == 0) or (i == blobs.len and splat_i < splat)) : (splat_i += 1) {
            try self.zdrain(blob, zlib.Z_NO_FLUSH);
            count += blob.len;
        }
    }
    return count;
}

fn zdrain(self: *Self, blob: []const u8, flush_flag: c_int) !void {
    self.zstream.next_in = @constCast(blob.ptr);
    self.zstream.avail_in = @intCast(blob.len);

    self.zstream.avail_out = 0;
    while (self.zstream.avail_out == 0) {
        self.zstream.next_out = self.outbuf.ptr;
        self.zstream.avail_out = @intCast(self.outbuf.len);

        // std.log.warn("zdrain input: {} {x}", .{ self.zstream.avail_in, self.zstream.next_in[0..self.zstream.avail_in] });
        zLibError(zlib.deflate(&self.zstream, flush_flag)) catch |err| {
            if (flush_flag == zlib.Z_FINISH and err == error.Z_STREAM_END) {
                const have = self.outbuf.len - self.zstream.avail_out;
                try self.underlying_writer.writeAll(self.outbuf[0..have]);
                break;
            }
            std.log.err("zstream:\n{any}", .{self.zstream});
            std.log.err("zlib error: {}\n", .{err});
            return error.WriteFailed;
        };
        const have = self.outbuf.len - self.zstream.avail_out;
        try self.underlying_writer.writeAll(self.outbuf[0..have]);
    }
    std.debug.assert(self.zstream.avail_in == 0);
}

fn sendFile(
    wr: *Io.Writer,
    file_reader: *std.fs.File.Reader,
    limit: Io.Limit,
) Io.Writer.FileError!usize {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zStreamInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    try self.zdrain(wr.buffered(), zlib.Z_NO_FLUSH);
    wr.end = 0;
    var transferred: usize = 0;
    while (limit == .unlimited or transferred < @intFromEnum(limit)) {
        const to_read = @min(wr.buffer.len, @intFromEnum(limit) - transferred);
        const just_read = try file_reader.readStreaming(wr.buffer[0..to_read]);
        transferred += just_read;
        try self.zdrain(wr.buffer[0..just_read], zlib.Z_NO_FLUSH);
        if (file_reader.atEnd()) break;
    }
    return transferred;
}

fn flush(wr: *Io.Writer) Io.Writer.Error!void {
    const self: *Self = @fieldParentPtr("writer", wr);
    self.zStreamInit() catch |err| {
        std.log.err("zstream:\n{any}", .{self.zstream});
        std.log.err("zlib error: {}\n", .{err});
        return error.WriteFailed;
    };

    const blob = wr.buffered();
    try self.zdrain(blob, zlib.Z_FULL_FLUSH);
    wr.end = 0;
}

pub fn finish(self: *Self) !void {
    try self.zStreamInit();

    const blob = self.writer.buffered();
    try self.zdrain(blob, zlib.Z_FINISH);
    self.writer.end = 0;
    try zLibError(zlib.deflateEnd(&self.zstream));
}

fn zLibError(ret: c_int) !void {
    return switch (ret) {
        zlib.Z_OK => {},
        zlib.Z_BUF_ERROR => error.Z_BUF_ERROR,
        zlib.Z_DATA_ERROR => error.Z_DATA_ERROR,
        zlib.Z_ERRNO => error.Z_ERRNO,
        zlib.Z_MEM_ERROR => error.Z_MEM_ERROR,
        zlib.Z_NEED_DICT => error.Z_NEED_DICT,
        zlib.Z_STREAM_END => error.Z_STREAM_END,
        zlib.Z_STREAM_ERROR => error.Z_STREAM_ERROR,
        zlib.Z_VERSION_ERROR => error.Z_VERSION_ERROR,
        else => error.ZLibUnknown,
    };
}

test "fuzz compress zlib deflate -> zig stdlib inflate" {
    const FlateFuzz = struct {
        ob: []u8,
        infbuf: []u8,

        const Input = struct {
            container: Container,
            bytes: []const u8,
            fn fromBytes(inbuf: []const u8) Input {
                std.debug.assert(inbuf.len > 0);
                return .{
                    .container = @enumFromInt(inbuf[0] % std.meta.fields(Container).len),
                    .bytes = inbuf[1..],
                };
            }
        };

        fn testOne(ctx: *@This(), inbuf: []const u8) anyerror!void {
            if (inbuf.len < 10 or inbuf.len > 4097) return;
            const input = Input.fromBytes(inbuf);

            var ow = std.Io.Writer.fixed(ctx.ob);
            var deflater: Deflater = try .init(.{
                .allocator = std.testing.allocator,
                .writer = &ow,
                .container = input.container,
            });
            defer deflater.deinit();

            try deflater.writer.writeAll(input.bytes);
            try deflater.finish();

            var infr = std.Io.Reader.fixed(ow.buffered());
            var inf = Decompress.init(
                &infr,
                input.container,
                ctx.infbuf,
            );
            try inf.reader.fillMore();
            const output = inf.reader.buffered();

            std.testing.expect(std.mem.eql(u8, input.bytes, output)) catch |err| {
                for (input.bytes, 0..) |_, it| {
                    if (output.len < it or input.bytes[it] != output[it]) {
                        const inslice = input.bytes[it..];
                        const outslice = output[it..];
                        std.log.err("expected (@offset {}): 0x{x}", .{ it, inslice[0..@max(100, inslice.len)] });
                        std.log.err("actual   (@offset {}): 0x{x}", .{ it, outslice[0..@max(100, outslice.len)] });
                        break;
                    }
                }
                std.log.err("compressed: 0x{x}", .{ow.buffered()});
                std.log.err("container:  {} in_len: {} out_len: {}", .{
                    input.container,
                    input.bytes.len,
                    output.len,
                });
                return err;
            };
        }
    };
    var ctx: FlateFuzz = .{
        .ob = try std.testing.allocator.alloc(u8, std.math.pow(usize, 2, 20)),
        .infbuf = try std.testing.allocator.alloc(u8, std.math.pow(usize, 2, 20)),
    };
    defer {
        std.testing.allocator.free(ctx.ob);
        std.testing.allocator.free(ctx.infbuf);
    }
    {
        var comp_test_buffer: [4097]u8 = @splat(0);
        inline for (comptime std.meta.fields(Container)) |cf| {
            std.log.warn("test compressing container: {s}", .{cf.name});
            comp_test_buffer[0] = cf.value;
            try ctx.testOne(&comp_test_buffer);
        }
    }
    try std.testing.fuzz(&ctx, FlateFuzz.testOne, .{});
}
