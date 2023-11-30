const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Compiler = @import("Compiler.zig");
const protocol = @import("../protocol.zig");
const Step = std.build.Step;

pub const ClientToServer = struct {
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
    pub const CompilerMessage = extern struct {
        step_id: Step.Id,
        tag: Compiler.ClientToServer.Tag,
    };
};

pub const ServerToClient = struct {
    pub const Tag = enum(u32) {
        /// Forwarded compiler protocol message.
        /// Body is a CompilerMessage.
        forwarded_compiler_message,
        /// Body is a CompilerUnit.
        you_control_compiler_server,

        _,
    };

    /// Trailing
    /// * Compiler message body.
    pub const CompilerMessage = extern struct {
        step_id: Step.Id,
        tag: Compiler.ServerToClient.Tag,
    };
};
