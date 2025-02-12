pub const Entity = @import("entity.zig").Entity;
pub const Registry = @import("registry.zig").Registry;
pub const View = @import("registry.zig").View;

test {
    @import("std").testing.refAllDecls(@This());
}
