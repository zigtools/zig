const std = @import("std");

const Build = std.Build;
pub const Kind = @import("../Step.zig").Kind;

pub const CheckFile = @import("CheckFile.zig");
// pub const CheckObject = @import("CheckObject.zig");
// pub const ConfigHeader = @import("ConfigHeader.zig");
// pub const Fmt = @import("Fmt.zig");
// pub const InstallArtifact = @import("InstallArtifact.zig");
// pub const InstallDir = @import("InstallDir.zig");
// pub const InstallFile = @import("InstallFile.zig");
// pub const ObjCopy = @import("ObjCopy.zig");
// pub const Compile = @import("Compile.zig");
// pub const Options = @import("Options.zig");
// pub const RemoveDir = @import("RemoveDir.zig");
// pub const Run = @import("Run.zig");
// pub const TranslateC = @import("TranslateC.zig");
// pub const WriteFile = @import("WriteFile.zig");

const Step = @This();

pub const Id = enum(u32) { _ };
pub const SerializeFn = *const fn (self: *Step, buffer: *std.ArrayList(u8)) anyerror!void;

id: Id,
kind: Kind,
name: []const u8,
owner: *Build,
serializeFn: SerializeFn = serializeNoOp,
dependencies: std.ArrayList(*Step),
/// Set this field to declare an upper bound on the amount of bytes of memory it will
/// take to run the step. Zero means no limit.
///
/// The idea to annotate steps that might use a high amount of RAM with an
/// upper bound. For example, perhaps a particular set of unit tests require 4
/// GiB of RAM, and those tests will be run under 4 different build
/// configurations at once. This would potentially require 16 GiB of memory on
/// the system if all 4 steps executed simultaneously, which could easily be
/// greater than what is actually available, potentially causing the system to
/// crash when using `zig build` at the default concurrency level.
///
/// This field causes the build runner to do two things:
/// 1. ulimit child processes, so that they will fail if it would exceed this
/// memory limit. This serves to enforce that this upper bound value is
/// correct.
/// 2. Ensure that the set of concurrent steps at any given time have a total
/// max_rss value that does not exceed the `max_total_rss` value of the build
/// runner. This value is configurable on the command line, and defaults to the
/// total system memory available.
max_rss: usize,

pub const StepOptions = struct {
    kind: Kind,
    name: []const u8,
    max_rss: usize = 0,
};

pub fn init(options: StepOptions) Step {
    const arena = options.owner.allocator;

    return .{
        .id = 0,
        .kind = options.kind,
        .name = arena.dupe(u8, options.name) catch @panic("OOM"),
        .max_rss = options.max_rss,
        .dependencies = std.ArrayList(*Step).init(arena),
    };
}

/// Trailing
/// * [name_len]u8
/// * [dependencies_len]Id
pub const Header = extern struct {
    id: Id,
    kind: Kind,
    name_len: u32,
    dependencies_len: u32,
    max_rss: u64,
};

pub fn serialize(step: *Step, buffer: *std.ArrayList(u8)) !void {
    try buffer.ensureUnusedCapacity(@sizeOf(Header) + step.name.len + step.dependencies.items.len * @sizeOf(Id));
    try buffer.appendSliceAssumeCapacity(std.mem.asBytes(&Header{
        .id = step.id,
        .kind = step.kind,
        .name_len = step.name.len,
        .dependencies_len = step.dependencies.items.len,
        .max_rss = step.max_rss,
    }));
    try buffer.appendSliceAssumeCapacity(step.name);
    try buffer.appendSliceAssumeCapacity(std.mem.asBytes(step.dependencies.items));
}

fn serializeNoOp(step: *Step, buffer: *std.ArrayList(u8)) anyerror!void {
    _ = step;
    _ = buffer;
}
