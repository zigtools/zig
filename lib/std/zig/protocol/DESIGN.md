# compiler server

## What do we want?

- Declarations
  - Identify with FQN or decl index
  - 
- Types
  - builtin.zig
- Values

```zig
pub const UpdateFlags = extern struct {

};

/// Trailing:
/// * [count]Decl
pub const Decls = struct {
    count: u32,
};
```
