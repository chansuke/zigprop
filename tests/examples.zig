//! Usage examples, run as tests. These double as a downstream-import
//! smoke test: everything here uses only zigprop's public API.

const std = @import("std");
const zigprop = @import("zigprop");

// A correct unsigned LEB128 codec (the §9 validation target's subject;
// the deliberately broken mutant arrives with milestone 4).
const varint = struct {
    fn encode(x: u32, buf: *[5]u8) []const u8 {
        var v = x;
        var i: usize = 0;
        while (true) {
            var byte: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            buf[i] = byte;
            i += 1;
            if (v == 0) break;
        }
        return buf[0..i];
    }

    fn decode(bytes: []const u8) u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        for (bytes) |byte| {
            result |= @as(u32, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }
};

test "example: varint round-trip (design §5)" {
    const prop = struct {
        fn run(x: u32) bool {
            var buf: [5]u8 = undefined;
            const encoded = varint.encode(x, &buf);
            return varint.decode(encoded) == x;
        }
    };
    var report = try zigprop.check(std.testing.allocator, u32, prop.run, .{});
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .passed);
}

// The README example (design v0.3 §5.5): the property sorts a copy in
// the per-case arena instead of mutating its input.
fn sortsCorrectly(_: void, case: *zigprop.Case, xs: []const u32) !bool {
    const copy = try case.allocator.dupe(u32, xs);
    std.mem.sort(u32, copy, {}, std.sort.asc(u32));
    return std.sort.isSorted(u32, copy, {}, std.sort.asc(u32));
}

test "example: sorting sorts" {
    try zigprop.checkWithOrError(std.testing.allocator, []const u32, void, {}, null, sortsCorrectly, .{ .max_cases = 50 });
}

test "example: a failing property is reported, not hidden" {
    const prop = struct {
        fn run(x: u8) bool {
            return x < 200; // false for boundary values 200..255
        }
    };
    var report = try zigprop.check(std.testing.allocator, u8, prop.run, .{ .seed = 2, .max_cases = 200 });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    const shown = try std.fmt.parseInt(u32, report.failed.original_value, 10);
    try std.testing.expect(shown >= 200 and shown <= 255);
}
