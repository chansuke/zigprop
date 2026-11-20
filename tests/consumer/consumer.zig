const std = @import("std");
const zigprop = @import("zigprop");

fn sortsCorrectly(_: void, case: *zigprop.Case, xs: []const u32) !bool {
    const copy = try case.allocator.dupe(u32, xs);
    std.mem.sort(u32, copy, {}, std.sort.asc(u32));
    return std.sort.isSorted(u32, copy, {}, std.sort.asc(u32));
}

test "consumer: sorting sorts" {
    try zigprop.checkWithOrError(std.testing.allocator, []const u32, void, {}, null, sortsCorrectly, .{});
}
