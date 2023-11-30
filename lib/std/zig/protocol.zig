const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();
const need_bswap = native_endian != .little;

pub const Build = @import("protocol/Build.zig");
pub const Compiler = @import("protocol/Compiler.zig");

pub fn bswap(x: anytype) @TypeOf(x) {
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

pub fn bswap_u32_array(slice: []u32) void {
    comptime std.debug.assert(need_bswap);
    for (slice) |*elem| elem.* = @byteSwap(elem.*);
}

pub const HandshakeResponse = enum(u8) {
    ok,
    version_mismatch,
};

pub fn clientHandshake(reader: anytype, writer: anytype) (@TypeOf(reader).Error || @TypeOf(writer).Error)!void {
    try writer.writeByte(@intCast(builtin.zig_version_string.len));
    try writer.writeAll(builtin.zig_version_string);

    const response: HandshakeResponse = @enumFromInt(try reader.readByte());
    switch (response) {
        .ok => {},
        .version_mismatch => return error.VersionMismatch,
    }
}

pub fn serverHandshake(reader: anytype, writer: anytype) (@TypeOf(reader).Error || @TypeOf(writer).Error)!void {
    var buf: [@sizeOf(u8)]u8 = undefined;
    const version_len = try reader.readByte();
    try reader.readAll(buf[0..version_len]);

    if (!std.mem.eql(u8, buf[0..version_len], builtin.zig_version_string)) {
        try writer.writeByte(@intFromEnum(HandshakeResponse.version_mismatch));
        return error.VersionMismatch;
    }

    try writer.writeByte(@intFromEnum(HandshakeResponse.ok));
}
