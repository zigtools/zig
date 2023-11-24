// must be kept in sync with builtin.zig

const std = @import("std");

// pub const TypeIndex = union(enum) {
//     type: void,
//     void: void,
//     bool: void,
//     no_return: void,
//     int: Int,
//     float: Float,
//     pointer: Pointer,
//     array: Array,
//     @"struct": Struct,
//     comptime_float: void,
//     comptime_int: void,
//     undefined: void,
//     null: void,
//     optional: Optional,
//     error_union: ErrorUnion,
//     error_set: ErrorSet,
//     @"enum": Enum,
//     @"union": Union,
//     @"fn": Fn,
//     @"opaque": Opaque,
//     frame: Frame,
//     any_frame: AnyFrame,
//     vector: Vector,
//     enum_literal: void,

pub const TypeHeader = packed struct(u64) {
    index: TypeIndex,
    kind: TypeKind,

    padding: u27 = undefined,
};

pub const TypeKind = std.builtin.TypeId;

// Header:
// type_len: u32,
// string_len: u32,
// Trailing
// [type_len] types
// [string_len] strings

// typekind
//

pub const TypeIndex = enum(u32) { _ };
pub const OptionalTypeIndex = enum(u32) {
    none,
    _,

    fn unwrap(opt: OptionalTypeIndex) OptionalTypeIndex {
        return if (opt == .none) null else @enumFromInt(@intFromEnum(opt));
    }
};

pub const String = enum(u32) { _ };

pub const Int = packed struct(u32) {
    signedness: std.builtin.Signedness,
    bits: u16,

    padding: u15 = undefined,
};

pub const Float = extern struct {
    bits: u16,
};

pub const Pointer = extern struct {
    pub const Size = enum(u2) {
        one,
        many,
        slice,
        c,
    };

    pub const Flags = packed struct(u32) {
        size: Size,
        is_const: bool,
        is_volatile: bool,
        address_space: std.builtin.AddressSpace,
        is_allowzero: bool,
        alignment: u16,

        padding: u6 = undefined,
    };

    child: TypeIndex,
    flags: Flags,

    // TODO
    // sentinel: ?*const anyopaque,
};

pub const Array = extern struct {
    len: u64,
    child: TypeIndex,

    // sentinel: ?*const anyopaque,
};

pub const ContainerLayout = enum(u2) {
    auto,
    @"extern",
    @"packed",
};

pub const Struct = extern struct {
    layout: ContainerLayout,
    /// Only valid if layout is .Packed
    backing_integer: OptionalTypeIndex = null,
    // fields: []const StructField,
    // decls: []const Declaration,
    is_tuple: bool,

    fields_len: u32,
    decls_len: u32,
};

pub const StructField = extern struct {
    name: String,
    type: TypeIndex,
    // default_value: ?*const anyopaque,
    is_comptime: bool,
    alignment: u16,
};

pub const Optional = extern struct {
    child: TypeIndex,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const ErrorUnion = extern struct {
    error_set: TypeIndex,
    payload: TypeIndex,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Error = extern struct {
    name: String,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const ErrorSet = ?[]const Error;

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const EnumField = extern struct {
    name: String,
    // TODO
    // value: comptime_int,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Enum = extern struct {
    tag_type: TypeIndex,
    fields: []const EnumField,
    decls: []const Declaration,
    is_exhaustive: bool,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const UnionField = extern struct {
    name: String,
    type: TypeIndex,
    alignment: u16,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Union = extern struct {
    layout: ContainerLayout,
    tag_type: OptionalTypeIndex,
    fields: []const UnionField,
    decls: []const Declaration,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Fn = extern struct {
    calling_convention: std.builtin.CallingConvention,
    alignment: u16,
    is_generic: bool,
    is_var_args: bool,
    /// TODO
    /// return_type: OptionalTypeIndex,
    params: []const Param,

    pub const Param = extern struct {
        is_generic: bool,
        is_noalias: bool,
        type: OptionalTypeIndex,
    };
};

pub const Opaque = extern struct {
    decls: []const Declaration,
};

pub const Frame = extern struct {
    // function: *const anyopaque,
};

pub const AnyFrame = extern struct {
    child: OptionalTypeIndex,
};

pub const Vector = extern struct {
    len: usize,
    child: TypeIndex,
};

pub const Declaration = extern struct {
    name: String,
};
// };
