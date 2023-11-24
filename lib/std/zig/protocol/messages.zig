const std = @import("std");
const Ast = std.zig.Ast;

pub const ClientToServer = struct {
    pub const Header = extern struct {
        tag: Tag,
        /// Size of the body only; does not include this Header.
        bytes_len: u32,
    };

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

    pub const UpdateFlags = packed struct(u8) {
        want_error_bundle: bool = false,
        want_decls: bool = false,
        want_emit_bin_path: bool = false,

        padding: u5 = undefined,
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
        error_bundle,
        /// Body is a UTF-8 string.
        progress,
        /// Body is a EmitBinPath.
        emit_bin_path,
        /// Body is a TestMetadata
        test_metadata,
        /// Body is a TestResults
        test_results,
        /// Body is a Decl
        decl,

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
    ///   - 0 means does not expect pani
    /// * string_bytes: [string_bytes_len]u8,
    pub const TestMetadata = extern struct {
        string_bytes_len: u32,
        tests_len: u32,
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
    /// * the file system path the emitted binary can be found
    pub const EmitBinPath = extern struct {
        flags: Flags,

        pub const Flags = packed struct(u8) {
            cache_hit: bool,
            reserved: u7 = 0,
        };
    };

    pub const OptionalLength = enum(u32) {
        /// Distinct from a 0 length string;
        /// this indicates the value is null
        none = std.math.maxInt(u32),
        _,
    };

    pub const Alignment = enum(u8) {
        @"1" = 0,
        @"2" = 1,
        @"4" = 2,
        @"8" = 3,
        @"16" = 4,
        @"32" = 5,
        none = std.math.maxInt(u6),
        _,
    };

    /// This data structure is used by the Zig language code generation and
    /// therefore must be kept in sync with the compiler implementation.
    pub const AddressSpace = enum(u8) {
        // CPU address spaces.
        generic,
        gs,
        fs,
        ss,

        // GPU address spaces.
        global,
        constant,
        param,
        shared,
        local,

        // AVR address spaces.
        flash,
        flash1,
        flash2,
        flash3,
        flash4,
        flash5,
    };

    pub const DeclIndex = enum(u32) { _ };
    /// Keep in sync with Module.Decl.
    /// Trailing:
    pub const Decl = extern struct {
        index: DeclIndex,
        type_len: u32,
    };
};
