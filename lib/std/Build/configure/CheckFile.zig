//! Fail the build step if a file does not match certain checks.
//! TODO: make this more flexible, supporting more kinds of checks.
//! TODO: generalize the code in std.testing.expectEqualStrings and make this
//! CheckFile step produce those helpful diagnostics when there is not a match.
const CheckFile = @This();
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Step = @import("Step.zig");

step: Step,
expected_matches: []const []const u8,
expected_exact: ?[]const u8,
source: std.Build.LazyPath,
max_bytes: usize = 20 * 1024 * 1024,

pub const base_id = .check_file;

pub const Options = struct {
    expected_matches: []const []const u8 = &.{},
    expected_exact: ?[]const u8 = null,
};

pub fn create(
    owner: *std.Build,
    source: std.Build.LazyPath,
    options: Options,
) *CheckFile {
    const self = owner.allocator.create(CheckFile) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = owner.nextStepId(),
            .kind = .check_file,
            .name = "CheckFile",
            .owner = owner,
        }),
        .source = source.dupe(owner),
        .expected_matches = owner.dupeStrings(options.expected_matches),
        .expected_exact = options.expected_exact,
    };
    self.source.addStepDependencies(&self.step);
    return self;
}

/// Trailing
/// * [name_len]u8
/// * [dependencies_len]Id
pub const Header = extern struct {
    expected_matches: u32,
    expected_exact: u32,
    source: u32,
    max_bytes: u32,
};

pub fn serialize(step: *Step, buffer: *std.ArrayList(u8)) !void {
    const self = @fieldParentPtr(CheckFile, "step", step);

    try buffer.ensureUnusedCapacity(@sizeOf(Header) + self.name.len + self.dependencies.items.len * @sizeOf(Step.Id));
    try buffer.appendSliceAssumeCapacity(std.mem.asBytes(&Header{
        .id = self.id,
        .kind = self.kind,
        .name_len = self.name.len,
        .dependencies_len = self.dependencies.items.len,
        .max_rss = self.max_rss,
    }));
    try buffer.appendSliceAssumeCapacity(self.name);
    try buffer.appendSliceAssumeCapacity(std.mem.asBytes(self.dependencies.items));
}

pub fn deserialize(step: *Step) !void {
    _ = step;
}
