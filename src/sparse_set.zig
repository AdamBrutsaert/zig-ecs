const std = @import("std");
const Entity = @import("entity.zig").Entity;

/// An entity iterator.
pub const EntityIterator = struct {
    entities: []Entity,
    index: usize,

    pub fn next(self: *EntityIterator) ?Entity {
        if (self.index >= self.entities.len) {
            return null;
        }

        defer self.index += 1;
        return self.entities[self.index];
    }
};

/// A sparse set.
///
/// Stores a `std.mem.Allocator` for memory management.
pub fn SparseSet(comptime T: type) type {
    return struct {
        /// An allocator.
        allocator: std.mem.Allocator,

        /// A sparse array of entities.
        sparse: std.ArrayList(Entity),

        /// A dense array of entities and components.
        dense: std.MultiArrayList(Dense),

        /// Sparse set.
        const Self = @This();

        /// A dense item.
        const Dense = struct {
            entity: Entity,
            component: T,
        };

        /// Initializes a new sparse set.
        pub fn init(allocator: std.mem.Allocator) Self {
            var self: Self = undefined;
            self.initPtr(allocator);
            return self;
        }

        /// Initializes a sparse set from a pointer.
        pub fn initPtr(self: *Self, allocator: std.mem.Allocator) void {
            self.allocator = allocator;
            self.sparse = std.ArrayList(Entity).init(allocator);
            self.dense = std.MultiArrayList(Dense){};
        }

        /// Deinitializes the sparse set.
        pub fn deinit(self: *Self) void {
            self.sparse.deinit();
            self.dense.deinit(self.allocator);
        }

        /// Returns whether the entity has a component.
        pub fn has(self: *const Self, entity: Entity) bool {
            return self.sparse.items.len > entity and
                self.sparse.items[entity] < self.dense.len and
                self.dense.items(.entity)[self.sparse.items[entity]] == entity;
        }

        /// Returns the component of the entity.
        ///
        /// Undefined behavior if the entity does not have a component.
        pub fn get(self: *const Self, entity: Entity) *T {
            return &self.dense.items(.component)[self.sparse.items[entity]];
        }

        /// Sets the component of the entity.
        pub fn set(self: *Self, entity: Entity, component: T) !void {
            if (self.has(entity)) {
                self.dense.items(.component)[self.sparse.items[entity]] = component;
                return;
            }

            const len = self.sparse.items.len;
            try self.sparse.resize(entity + 1);
            @memset(self.sparse.items[len..self.sparse.items.len], 0);

            try self.dense.append(self.allocator, .{ .entity = entity, .component = component });
            self.sparse.items[entity] = self.dense.len - 1;
        }

        /// Removes the component of the entity.
        pub fn remove(self: *Self, entity: Entity) void {
            if (!self.has(entity)) {
                return;
            }

            const dense_index = self.sparse.items[entity];
            const last_entity = self.dense.items(.entity)[self.dense.len - 1];

            self.dense.swapRemove(dense_index);
            self.sparse.items[last_entity] = dense_index;
        }

        /// Clears the sparse set.
        pub fn clear(self: *Self) void {
            self.sparse.clearAndFree();
            self.dense.clearAndFree(self.allocator);
        }

        /// Returns the size of the sparse sets.
        pub fn size(self: *const Self) usize {
            return self.dense.len;
        }

        /// Returns a component iterator.
        pub fn entityIterator(self: *const Self) EntityIterator {
            return .{ .entities = self.dense.items(.entity), .index = 0 };
        }
    };
}

test "sparse_set" {
    const Position = struct {
        x: f32,
        y: f32,
    };

    var ss = SparseSet(Position).init(std.testing.allocator);
    defer ss.deinit();

    try ss.set(1, .{ .x = 1.0, .y = 2.0 });

    try std.testing.expect(ss.has(1));
    try std.testing.expect(!ss.has(2));
    try std.testing.expectEqual(Position{ .x = 1.0, .y = 2.0 }, ss.get(1).*);

    ss.remove(1);

    try std.testing.expect(!ss.has(1));

    try ss.set(1, .{ .x = 3.0, .y = 4.0 });
    try ss.set(2, .{ .x = 5.0, .y = 6.0 });
    try ss.set(3, .{ .x = 7.0, .y = 8.0 });

    var entities = std.ArrayList(Entity).init(std.testing.allocator);
    defer entities.deinit();

    var iter = ss.entityIterator();
    while (iter.next()) |entity| {
        try entities.append(entity);
    }

    try std.testing.expectEqual(3, entities.items.len);
    try std.testing.expect(entities.items[0] == 1);
    try std.testing.expect(entities.items[1] == 2);
    try std.testing.expect(entities.items[2] == 3);
}
