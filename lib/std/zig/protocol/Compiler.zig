const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const protocol = @import("../protocol.zig");

pub const ClientToServer = struct {
    pub const Tag = enum(u32) {
        /// Tells the compiler to shut down cleanly.
        /// No body.
        exit,
        /// Tells the compiler to detect changes in source files and update the
        /// affected output compilation artifacts.
        /// If one of the compilation artifacts is an executable that is
        /// running as a child process, the compiler will wait for it to exit
        /// before performing the update.
        /// The message body is UpdateFlags.
        update,
        /// Tells the compiler to execute the executable as a child process.
        /// No body.
        run,
        /// Tells the compiler to detect changes in source files and update the
        /// affected output compilation artifacts.
        /// If one of the compilation artifacts is an executable that is
        /// running as a child process, the compiler will perform a hot code
        /// swap.
        /// The message body is UpdateFlags.
        hot_update,
        /// Ask the test runner for metadata about all the unit tests that can
        /// be run. Server will respond with a `test_metadata` message.
        /// No body.
        query_test_metadata,
        /// Ask the test runner to run a particular test.
        /// The message body is a u32 test index.
        run_test,

        _,
    };
};

pub const ServerToClient = struct {
    pub const Tag = enum(u32) {
        /// Body is an ErrorBundle.
        error_bundle,
        /// Body is a UTF-8 string.
        progress,
        /// Body is a EmitBinPath.
        emit_bin_path,
        /// Body is a TestMetadata
        test_metadata,
        /// Body is a TestResults
        test_results,

        _,
    };

    /// Trailing:
    /// * extra: [extra_len]u32,
    /// * string_bytes: [string_bytes_len]u8,
    /// See `std.zig.ErrorBundle`.
    pub const ErrorBundle = extern struct {
        extra_len: u32,
        string_bytes_len: u32,
    };

    /// Trailing:
    /// * name: [tests_len]u32
    ///   - null-terminated string_bytes index
    /// * async_frame_len: [tests_len]u32,
    ///   - 0 means not async
    /// * expected_panic_msg: [tests_len]u32,
    ///   - null-terminated string_bytes index
    ///   - 0 means does not expect panic
    /// * string_bytes: [string_bytes_len]u8,
    pub const TestMetadata = extern struct {
        string_bytes_len: u32,
        tests_len: u32,

        pub fn readTrailing
    };

    pub const TestResults = extern struct {
        index: u32,
        flags: Flags,

        pub const Flags = packed struct(u32) {
            fail: bool,
            skip: bool,
            leak: bool,
            log_err_count: u29 = 0,
        };
    };

    /// Trailing:
    /// * the file system path where the emitted binary can be found
    pub const EmitBinPath = extern struct {
        flags: Flags,

        pub const Flags = packed struct(u8) {
            cache_hit: bool,
            reserved: u7 = 0,
        };
    };
};

pub fn Server(comptime Reader: type, comptime Writer: type) type {
    return struct {
        pub const InboundMessage = ClientToServer;
        pub const OutboundMessage = ServerToClient;

        reader: Reader,
        writer: Writer,

        allocator: std.mem.Allocator,
        buffer: std.ArrayListUnmanaged(u8) = .{},

        pub fn handshake(server: *@This()) !void {
            try protocol.serverHandshake(server.reader, server.writer);
        }

        pub fn readTag(server: *@This()) !InboundMessage.Tag {
            return @enumFromInt(server.reader.readInt(u32, .little));
        }

        pub fn readStringArrayList(server: @This(), list: *std.ArrayList(u8)) !void {
            const len = try server.reader.readInt(u32, .little);
            try list.ensureTotalCapacity(len);
            list.items.len = len;
            try server.reader.readAll(list.items);
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
}

pub fn Client(comptime Reader: type, comptime Writer: type) type {
    return struct {
        pub const InboundMessage = ServerToClient;
        pub const OutboundMessage = ClientToServer;

        reader: Reader,
        writer: Writer,

        pub fn handshake(server: @This()) !void {
            try protocol.clientHandshake(server.reader, server.writer);
        }

        pub fn readTag(server: @This()) !InboundMessage.Tag {
            return @enumFromInt(server.reader.readInt(u32, .little));
        }

        pub fn readErrorBundle(server: *@This(), allocator: std.mem.Allocator) !std.zig.ErrorBundle {
            const EbHdr = InboundMessage.ErrorBundle;
            const eb_hdr: EbHdr = @bitCast(try server.reader.readBytesNoEof(@sizeOf(EbHdr)));

            const extra_bytes = try allocator.alloc(u32, eb_hdr.extra_len);
            try server.reader.readAll(std.mem.sliceAsBytes(&extra_bytes));
            const string_bytes = try allocator.alloc(u8, eb_hdr.string_bytes_len);
            try server.reader.readAll(string_bytes);

            return .{
                .string_bytes = string_bytes,
                .extra_bytes = extra_bytes,
            };
        }

        pub fn readStringArrayList(server: @This(), list: *std.ArrayList(u8)) !void {
            const len = try server.reader.readInt(u32, .little);
            try list.ensureTotalCapacity(len);
            list.items.len = len;
            try server.reader.readAll(list.items);
        }

        pub fn readEmitBinPath(server: *@This(), path_buf: *std.ArrayList(u8)) !InboundMessage.EmitBinPath {
            const EbpHdr = InboundMessage.EmitBinPath;
            const ebp_hdr: EbpHdr = @bitCast(try server.reader.readBytesNoEof(@sizeOf(EbpHdr)));
            try server.readStringArrayList(path_buf);
            return ebp_hdr;
        }
    };
}
