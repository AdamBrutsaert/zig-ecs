const std = @import("std");
const Registry = @import("registry.zig").Registry;

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = Registry.init(allocator);
    defer registry.deinit();

    const entity = registry.create();
    try registry.set(entity, Position{ .x = 10.0, .y = 10.0 });
    try registry.set(entity, Velocity{ .x = 5.0, .y = 5.0 });

    var view = try registry.view(.{ Position, Velocity });
    var it = view.entityIterator();

    while (it.next()) |entt| {
        const position = try registry.get(Position, entt);
        const velocity = try registry.get(Velocity, entt);
        std.debug.print("entity: {}, position: ({}, {}), velocity: ({}, {})\n", .{ entt, position.x, position.y, velocity.x, velocity.y });
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
