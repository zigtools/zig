const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const native_endian = builtin.target.cpu.arch.endian();
const need_bswap = native_endian != .little;

pub const @"type" = @import("protocol/type.zig");
const messages = @import("protocol/messages.zig");

pub const ClientToServer = messages.ClientToServer;
pub const ServerToClient = messages.ServerToClient;

pub const Server = struct {
    in: std.fs.File,
    out: std.fs.File,
    receive_fifo: std.fifo.LinearFifo(u8, .Dynamic),

    pub const InboundMessage = ClientToServer;
    pub const OutboundMessage = ServerToClient;

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

    pub fn receiveMessage(s: *Server) !InboundMessage.Header {
        const Header = InboundMessage.Header;
        const fifo = &s.receive_fifo;

        while (true) {
            const buf = fifo.readableSlice(0);
            assert(fifo.readableLength() == buf.len);
            if (buf.len >= @sizeOf(Header)) {
                // workaround for https://github.com/ziglang/zig/issues/14904
                const bytes_len = bswap_and_workaround_u32(buf[4..][0..4]);
                const tag = bswap_and_workaround_tag(buf[0..][0..4]);

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
        const result = @as(*align(1) const u32, @ptrCast(buf[0..4])).*;
        fifo.discard(4);
        return bswap(result);
    }

    pub fn serveStringMessage(s: *Server, tag: OutboundMessage.Tag, msg: []const u8) !void {
        return s.serveMessage(.{
            .tag = tag,
            .bytes_len = @as(u32, @intCast(msg.len)),
        }, &.{msg});
    }

    pub fn serveMessage(
        s: *const Server,
        header: OutboundMessage.Header,
        bufs: []const []const u8,
    ) !void {
        var iovecs: [10]std.os.iovec_const = undefined;
        const header_le = bswap(header);
        iovecs[0] = .{
            .iov_base = @as([*]const u8, @ptrCast(&header_le)),
            .iov_len = @sizeOf(OutboundMessage.Header),
        };
        for (bufs, iovecs[1 .. bufs.len + 1]) |buf, *iovec| {
            iovec.* = .{
                .iov_base = buf.ptr,
                .iov_len = buf.len,
            };
        }
        try s.out.writevAll(iovecs[0 .. bufs.len + 1]);
    }

    pub fn serveEmitBinPath(
        s: *Server,
        fs_path: []const u8,
        header: OutboundMessage.EmitBinPath,
    ) !void {
        try s.serveMessage(.{
            .tag = .emit_bin_path,
            .bytes_len = @as(u32, @intCast(fs_path.len + @sizeOf(OutboundMessage.EmitBinPath))),
        }, &.{
            std.mem.asBytes(&header),
            fs_path,
        });
    }

    pub fn serveTestResults(
        s: *Server,
        msg: OutboundMessage.TestResults,
    ) !void {
        const msg_le = bswap(msg);
        try s.serveMessage(.{
            .tag = .test_results,
            .bytes_len = @as(u32, @intCast(@sizeOf(OutboundMessage.TestResults))),
        }, &.{
            std.mem.asBytes(&msg_le),
        });
    }

    pub fn serveErrorBundle(s: *Server, error_bundle: std.zig.ErrorBundle) !void {
        const eb_hdr: OutboundMessage.ErrorBundle = .{
            .extra_len = @as(u32, @intCast(error_bundle.extra.len)),
            .string_bytes_len = @as(u32, @intCast(error_bundle.string_bytes.len)),
        };
        const bytes_len = @sizeOf(OutboundMessage.ErrorBundle) +
            4 * error_bundle.extra.len + error_bundle.string_bytes.len;
        try s.serveMessage(.{
            .tag = .error_bundle,
            .bytes_len = @as(u32, @intCast(bytes_len)),
        }, &.{
            std.mem.asBytes(&eb_hdr),
            // TODO: implement @ptrCast between slices changing the length
            std.mem.sliceAsBytes(error_bundle.extra),
            error_bundle.string_bytes,
        });
    }

    pub const TestMetadata = struct {
        names: []u32,
        async_frame_sizes: []u32,
        expected_panic_msgs: []u32,
        string_bytes: []const u8,
    };

    pub fn serveTestMetadata(s: *Server, test_metadata: TestMetadata) !void {
        const header: OutboundMessage.TestMetadata = .{
            .tests_len = bswap(@as(u32, @intCast(test_metadata.names.len))),
            .string_bytes_len = bswap(@as(u32, @intCast(test_metadata.string_bytes.len))),
        };
        const bytes_len = @sizeOf(OutboundMessage.TestMetadata) +
            3 * 4 * test_metadata.names.len + test_metadata.string_bytes.len;

        if (need_bswap) {
            bswap_u32_array(test_metadata.names);
            bswap_u32_array(test_metadata.async_frame_sizes);
            bswap_u32_array(test_metadata.expected_panic_msgs);
        }
        defer if (need_bswap) {
            bswap_u32_array(test_metadata.names);
            bswap_u32_array(test_metadata.async_frame_sizes);
            bswap_u32_array(test_metadata.expected_panic_msgs);
        };

        return s.serveMessage(.{
            .tag = .test_metadata,
            .bytes_len = @as(u32, @intCast(bytes_len)),
        }, &.{
            std.mem.asBytes(&header),
            // TODO: implement @ptrCast between slices changing the length
            std.mem.sliceAsBytes(test_metadata.names),
            std.mem.sliceAsBytes(test_metadata.async_frame_sizes),
            std.mem.sliceAsBytes(test_metadata.expected_panic_msgs),
            test_metadata.string_bytes,
        });
    }

    /// workaround for https://github.com/ziglang/zig/issues/14904
    fn bswap_and_workaround_u32(bytes_ptr: *const [4]u8) u32 {
        return std.mem.readInt(u32, bytes_ptr, .little);
    }

    /// workaround for https://github.com/ziglang/zig/issues/14904
    fn bswap_and_workaround_tag(bytes_ptr: *const [4]u8) InboundMessage.Tag {
        const int = std.mem.readInt(u32, bytes_ptr, .little);
        return @as(InboundMessage.Tag, @enumFromInt(int));
    }
};

pub const Client = struct {
    pub const InboundMessage = ServerToClient;
    pub const OutboundMessage = ClientToServer;
};

fn bswap(x: anytype) @TypeOf(x) {
    if (!need_bswap) return x;

    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .Enum => return @as(T, @enumFromInt(@byteSwap(@intFromEnum(x)))),
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
                return @as(T, @bitCast(@byteSwap(@as(I, @bitCast(x)))));
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
