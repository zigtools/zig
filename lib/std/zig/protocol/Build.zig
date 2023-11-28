const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Compiler = @import("Compiler.zig");
const protocol = @import("../protocol.zig");

pub const Step = enum(u32) { _ };

pub const ClientToServer = struct {
    pub const Header = extern struct {
        tag: Tag,
        /// Size of the body only; does not include this Header.
        bytes_len: u32,
    };

    pub const Tag = enum(u32) {
        /// Tells the build runner to shut down cleanly.
        /// No body.
        exit,
        /// Forward a compiler protocol message.
        /// Body is a CompilerMessage.
        forward_compiler_message,
        /// Asks the build runner for the build graph.
        /// No body.
        get_build_graph,
        /// Asks the build runner to not send any of its own commands
        /// to a certain compiler server instance.
        /// Body is a CompilerUnit.
        take_control_of_compiler_server,

        _,
    };

    /// Trailing
    /// * Compiler message body.
    pub const CompilerMessage = struct {
        step: Step,
        tag: Compiler.ClientToServer.Tag,
    };
};

pub const ServerToClient = struct {
    pub const Header = extern struct {
        tag: Tag,
        /// Size of the body only; does not include this Header.
        bytes_len: u32,
    };

    pub const Tag = enum(u32) {
        /// Body is a UTF-8 string.
        zig_version,
        /// Body is an ErrorBundle.
        run,
        /// Forwarded compiler protocol message.
        /// Body is a CompilerMessage.
        forwarded_compiler_message,
        /// Body is a CompilerUnit.
        you_control_compiler_server,

        _,
    };

    /// Trailing
    /// * Compiler message body.
    pub const CompilerMessage = struct {
        step: Step,
        tag: Compiler.ServerToClient.Tag,
    };
};

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
        return protocol.bswap(result);
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
        const header_le = protocol.bswap(header);
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
        const msg_le = protocol.bswap(msg);
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
            .tests_len = protocol.bswap(@as(u32, @intCast(test_metadata.names.len))),
            .string_bytes_len = protocol.bswap(@as(u32, @intCast(test_metadata.string_bytes.len))),
        };
        const bytes_len = @sizeOf(OutboundMessage.TestMetadata) +
            3 * 4 * test_metadata.names.len + test_metadata.string_bytes.len;

        if (protocol.need_bswap) {
            protocol.bswap_u32_array(test_metadata.names);
            protocol.bswap_u32_array(test_metadata.async_frame_sizes);
            protocol.bswap_u32_array(test_metadata.expected_panic_msgs);
        }
        defer if (protocol.need_bswap) {
            protocol.bswap_u32_array(test_metadata.names);
            protocol.bswap_u32_array(test_metadata.async_frame_sizes);
            protocol.bswap_u32_array(test_metadata.expected_panic_msgs);
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
