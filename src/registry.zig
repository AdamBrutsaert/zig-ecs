const std = @import("std");

const Entity = @import("entity.zig").Entity;
const SparseSet = @import("sparse_set.zig").SparseSet;
const SparseSetEntityIterator = @import("sparse_set.zig").EntityIterator;

/// A view over a set of components.
pub fn View(comptime Types: anytype) type {
    const T = @TypeOf(Types);
    const info = @typeInfo(T);

    comptime var types: [info.@"struct".fields.len]type = undefined;
    inline for (info.@"struct".fields, 0..) |field, i| {
        types[i] = *SparseSet(@field(Types, field.name));
    }

    const Tuple = std.meta.Tuple(&types);

    return struct {
        /// The sparse sets of the components.
        sparse_sets: Tuple,

        /// The view.
        const Self = @This();

        /// An iterator over the entities.
        pub const EntityIterator = struct {
            /// The sparse sets of the components.
            sparse_sets: Tuple,

            /// The entity iterator.
            iterator: SparseSetEntityIterator,

            /// Retrieves the next entity which has all the components.
            pub fn next(self: *EntityIterator) ?Entity {
                while (self.iterator.next()) |entity| {
                    var found = true;

                    inline for (self.sparse_sets) |ss| {
                        if (!ss.has(entity)) {
                            found = false;
                            break;
                        }
                    }

                    if (found) {
                        return entity;
                    }
                }

                return null;
            }
        };

        /// Returns an iterator over the entities that have all the components.
        pub fn entityIterator(self: *Self) EntityIterator {
            var len = self.sparse_sets[0].size();
            var it = self.sparse_sets[0].entityIterator();

            inline for (self.sparse_sets) |ss| {
                if (ss.size() < len) {
                    len = ss.size();
                    it = ss.entityIterator();
                }
            }

            return EntityIterator{
                .sparse_sets = self.sparse_sets,
                .iterator = it,
            };
        }
    };
}

/// A registry of entities and their components.
///
/// The registry stores an allocator internally.
pub const Registry = struct {
    /// The allocator used to allocate and deallocate memory.
    allocator: std.mem.Allocator,

    /// A map of sparse sets indexed by the type name.
    sparse_sets: std.StringHashMap(AnySparseSet),

    /// The last entity created.
    last_entity: Entity = 0,

    /// An opaque type to store a pointer to a sparse set.
    const AnySparseSet = struct {
        /// The pointer to the sparse set.
        ptr: *anyopaque,

        /// The deinitialization function.
        deinitFn: *const fn (ptr: *anyopaque) void,

        /// The destruction function to deallocate the sparse set.
        destroyFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

        /// Initializes the sparse set pointer.
        fn init(ptr: anytype) AnySparseSet {
            const T = @TypeOf(ptr);
            const ptr_info = @typeInfo(T);

            if (ptr_info != .pointer) @compileError("ptr must be a pointer");
            if (ptr_info.pointer.size != .one) @compileError("ptr must be a pointer to a single value");

            const gen = struct {
                fn deinit(pointer: *anyopaque) void {
                    const self: T = @ptrCast(@alignCast(pointer));
                    return @call(.auto, ptr_info.pointer.child.deinit, .{self});
                }

                fn destroy(pointer: *anyopaque, allocator: std.mem.Allocator) void {
                    const self: T = @ptrCast(@alignCast(pointer));
                    allocator.destroy(self);
                }
            };

            return .{
                .ptr = ptr,
                .deinitFn = gen.deinit,
                .destroyFn = gen.destroy,
            };
        }

        /// Deinitializes the sparse set.
        fn deinit(self: *AnySparseSet) void {
            self.deinitFn(self.ptr);
        }

        /// Destroys the sparse set.
        fn destroy(self: *AnySparseSet, allocator: std.mem.Allocator) void {
            self.destroyFn(self.ptr, allocator);
        }
    };

    /// Retrieve the sparse set of the given type.
    /// Allocates a new sparse set if it doesn't exist.
    fn sparse_set(self: *Registry, comptime T: type) !*SparseSet(T) {
        const name = @typeName(T);

        if (self.sparse_sets.get(name)) |ss| {
            return @ptrCast(@alignCast(ss.ptr));
        }

        const ss = try self.allocator.create(SparseSet(T));
        errdefer self.allocator.destroy(ss);
        ss.initPtr(self.allocator);

        try self.sparse_sets.put(name, AnySparseSet.init(ss));
        return ss;
    }

    /// Initializes the registry with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .sparse_sets = std.StringHashMap(AnySparseSet).init(allocator),
        };
    }

    /// Deinitializes the registry.
    pub fn deinit(self: *Registry) void {
        var iterator = self.sparse_sets.valueIterator();
        while (iterator.next()) |ss| {
            ss.deinit();
            ss.destroy(self.allocator);
        }
        self.sparse_sets.deinit();
    }

    /// Creates a new entity.
    pub fn create(self: *Registry) Entity {
        self.last_entity += 1;
        return self.last_entity;
    }

    /// Returns whether an entity has the given component.
    pub fn has(self: *Registry, comptime T: type, entity: Entity) !bool {
        const name = @typeName(T);
        const maybe_ss = self.sparse_sets.get(name);

        if (maybe_ss) |ss| {
            return @as(*SparseSet(T), @ptrCast(@alignCast(ss.ptr))).has(entity);
        }

        return false;
    }

    /// Retrieves the component of the given entity.
    ///
    /// Undefined behavior if the entity does not have the component.
    pub fn get(self: *Registry, comptime T: type, entity: Entity) *T {
        const name = @typeName(T);
        const ss = self.sparse_sets.get(name).?;

        return @as(*SparseSet(T), @ptrCast(@alignCast(ss.ptr))).get(entity);
    }

    /// Tries to retrieve the component of the given entity.
    ///
    /// Returns an error if the entity does not have the component.
    pub fn try_get(self: *Registry, comptime T: type, entity: Entity) !*T {
        const name = @typeName(T);
        const maybe_ss = self.sparse_sets.get(name);

        if (maybe_ss) |ss| {
            const cast_ss = @as(*SparseSet(T), @ptrCast(@alignCast(ss.ptr)));

            if (cast_ss.has(entity))
                return cast_ss.get(entity);

            return error.ComponentNotFound;
        }

        return error.ComponentNotFound;
    }

    /// Sets the component of the given entity.
    pub fn set(self: *Registry, entity: Entity, component: anytype) !void {
        const ss = try self.sparse_set(@TypeOf(component));
        try ss.set(entity, component);
    }

    /// Creates a view over the given types.
    pub fn view(self: *Registry, comptime Types: anytype) !View(Types) {
        const T = @TypeOf(Types);
        const info = @typeInfo(T);

        if (info != .@"struct") @compileError("Types must be a struct");
        if (!info.@"struct".is_tuple) @compileError("Types must be a tuple");
        inline for (info.@"struct".fields) |field| {
            if (field.type != @TypeOf(type)) @compileError("Types must be a tuple of types");
        }

        comptime var types: [info.@"struct".fields.len]type = undefined;
        inline for (info.@"struct".fields, 0..) |field, i| {
            types[i] = *SparseSet(@field(Types, field.name));
        }

        var view_sparse_sets: std.meta.Tuple(&types) = undefined;
        inline for (info.@"struct".fields, 0..) |field, i| {
            view_sparse_sets[i] = try self.sparse_set(@field(Types, field.name));
        }

        return View(Types){ .sparse_sets = view_sparse_sets };
    }
};

test "view" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const Position = struct {
        x: f32,
        y: f32,
    };

    const Velocity = struct {
        x: f32,
        y: f32,
    };

    const entity1 = registry.create();
    try registry.set(entity1, Position{ .x = 10.0, .y = 10.0 });
    try registry.set(entity1, Velocity{ .x = 5.0, .y = 5.0 });

    const entity2 = registry.create();
    try registry.set(entity2, Position{ .x = 20.0, .y = 20.0 });

    const entity3 = registry.create();
    try registry.set(entity3, Position{ .x = 30.0, .y = 30.0 });
    try registry.set(entity3, Velocity{ .x = 15.0, .y = 15.0 });

    var view = try registry.view(.{ Position, Velocity });
    var it = view.entityIterator();

    var entities = std.ArrayList(Entity).init(std.testing.allocator);
    defer entities.deinit();

    while (it.next()) |entt| {
        try entities.append(entt);
    }

    try std.testing.expectEqual(entities.items.len, 2);
    try std.testing.expectEqual(entities.items[0], entity1);
    try std.testing.expectEqual(entities.items[1], entity3);
}
