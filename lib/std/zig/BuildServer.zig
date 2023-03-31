//! A server built on top of the compile server for build invocations

in: std.fs.File,
out: std.fs.File,
receive_fifo: std.fifo.LinearFifo(u8, .Dynamic),

pub const Message = struct {
    pub const Header = extern struct {
        tag: Tag,
        /// Size of the body only; does not include this Header.
        bytes_len: u32,
    };

    pub const Tag = enum(u32) {
        /// Body is a UTF-8 string.
        zig_version,
        child_message,
        /// u32 length + [length]Child
        /// -> child kind
        /// -> args: u32 len
        ///    -> arg\0
        child_list,
        _,
    };

    pub const ChildKind = enum(u8) {
        exe,
        obj,
        lib,
        @"test",
    };
};

pub const Options = struct {
    gpa: Allocator,
    in: std.fs.File,
    out: std.fs.File,
    zig_version: []const u8,
};

pub fn init(options: Options) !Server {
    var s: Server = .{
        .in = options.in,
        .out = options.out,
        .receive_fifo = std.fifo.LinearFifo(u8, .Dynamic).init(options.gpa),
    };
    try s.serveStringMessage(.zig_version, options.zig_version);
    return s;
}

pub fn deinit(s: *Server) void {
    s.receive_fifo.deinit();
    s.* = undefined;
}

pub fn receiveMessage(s: *Server) !InMessage.Header {
    const Header = InMessage.Header;
    const fifo = &s.receive_fifo;

    while (true) {
        const buf = fifo.readableSlice(0);
        assert(fifo.readableLength() == buf.len);
        if (buf.len >= @sizeOf(Header)) {
            const header = @ptrCast(*align(1) const Header, buf[0..@sizeOf(Header)]);
            // workaround for https://github.com/ziglang/zig/issues/14904
            const bytes_len = bswap_and_workaround_u32(&header.bytes_len);
            // workaround for https://github.com/ziglang/zig/issues/14904
            const tag = bswap_and_workaround_tag(&header.tag);

            if (buf.len - @sizeOf(Header) >= bytes_len) {
                fifo.discard(@sizeOf(Header));
                return .{
                    .tag = tag,
                    .bytes_len = bytes_len,
                };
            } else {
                const needed = bytes_len - (buf.len - @sizeOf(Header));
                const write_buffer = try fifo.writableWithSize(needed);
                const amt = try s.in.read(write_buffer);
                fifo.update(amt);
                continue;
            }
        }

        const write_buffer = try fifo.writableWithSize(256);
        const amt = try s.in.read(write_buffer);
        fifo.update(amt);
    }
}

pub fn receiveBody_u32(s: *Server) !u32 {
    const fifo = &s.receive_fifo;
    const buf = fifo.readableSlice(0);
    const result = @ptrCast(*align(1) const u32, buf[0..4]).*;
    fifo.discard(4);
    return bswap(result);
}

pub fn serveStringMessage(s: *Server, tag: OutMessage.Tag, msg: []const u8) !void {
    return s.serveMessage(.{
        .tag = tag,
        .bytes_len = @intCast(u32, msg.len),
    }, &.{msg});
}

pub fn serveMessage(
    s: *const Server,
    header: OutMessage.Header,
    bufs: []const []const u8,
) !void {
    var iovecs: [10]std.os.iovec_const = undefined;
    const header_le = bswap(header);
    iovecs[0] = .{
        .iov_base = @ptrCast([*]const u8, &header_le),
        .iov_len = @sizeOf(OutMessage.Header),
    };
    for (bufs, iovecs[1 .. bufs.len + 1]) |buf, *iovec| {
        iovec.* = .{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        };
    }
    try s.out.writevAll(iovecs[0 .. bufs.len + 1]);
}

fn bswap(x: anytype) @TypeOf(x) {
    if (!need_bswap) return x;

    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .Enum => return @intToEnum(T, @byteSwap(@enumToInt(x))),
        .Int => return @byteSwap(x),
        .Struct => |info| switch (info.layout) {
            .Extern => {
                var result: T = undefined;
                inline for (info.fields) |field| {
                    @field(result, field.name) = bswap(@field(x, field.name));
                }
                return result;
            },
            .Packed => {
                const I = info.backing_integer.?;
                return @bitCast(T, @byteSwap(@bitCast(I, x)));
            },
            .Auto => @compileError("auto layout struct"),
        },
        else => @compileError("bswap on type " ++ @typeName(T)),
    }
}

fn bswap_u32_array(slice: []u32) void {
    comptime assert(need_bswap);
    for (slice) |*elem| elem.* = @byteSwap(elem.*);
}

/// workaround for https://github.com/ziglang/zig/issues/14904
fn bswap_and_workaround_u32(x: *align(1) const u32) u32 {
    const bytes_ptr = @ptrCast(*const [4]u8, x);
    return std.mem.readIntLittle(u32, bytes_ptr);
}

/// workaround for https://github.com/ziglang/zig/issues/14904
fn bswap_and_workaround_tag(x: *align(1) const InMessage.Tag) InMessage.Tag {
    const bytes_ptr = @ptrCast(*const [4]u8, x);
    const int = std.mem.readIntLittle(u32, bytes_ptr);
    return @intToEnum(InMessage.Tag, int);
}

const OutMessage = std.zig.BuildServer.Message;
const InMessage = std.zig.BuildClient.Message;

const Server = @This();
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const native_endian = builtin.target.cpu.arch.endian();
const need_bswap = native_endian != .Little;
