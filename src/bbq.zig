//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT
//!
//! This implementation is motivated by and based upon the algorithm described in:
//! "BBQ: A Block-based Bounded Queue for Exchanging Data and Profiling" 
//! by Jiawei Wang et al., USENIX ATC 2022
//! https://www.usenix.org/system/files/atc22-wang-jiawei.pdf
//!
//! No claim is made to the research paper or the algorithm described therein.
//! All rights to the original research paper and algorithm remain with the
//! original authors and publishers.
//! 
//! Citations from the paper appear in comments in the format `// <section> - "<quote>"`.

const std = @import("std");
const assert = std.debug.assert;

/// Used in typical lossless producer-consumer scenarios such as message passing and work distribution.
/// Implements a threadsafe circular buffer with first-in-first-out (FIFO) semantics where producers are
/// blocked from inserting into the queue when the queue is full.
pub fn RetryNewQueue(comptime T: type) type {
    return BBQ(T, .retry_new);
}

/// Used in lossy producer-consumer scenarios such as profiling, tracing and debugging.
/// Implements a threadsafe circular buffer with first-in-first-out (FIFO) semantics where producers are
/// allowed to overwrite unconsumed data if the buffer is full.
pub fn DropOldQueue(comptime T: type) type {
    return BBQ(T, .drop_old);
}

pub const BlockOptions = struct {
    // 3.1 - "BBQ splits the ringbuffer into blocks, [...]. Each block contains one or more entries, usually multiple,
    //       depending on the configuration."
    block_number: u32,
    block_size: u32,
};

fn BBQ(comptime T: type, comptime mode: FullHandlingMode) type {
    return struct {
        const Self = @This();

        // 4.1 - "BBQ has two queue-level Head variables"
        // 3.3 - "Queue-level control variables point to blocks (C.head and P.head)"
        // 3.3 - "In principle, phantom heads allow us to eliminate the C.head and P.head variables altogether.
        //       Unfortunately, phantom heads are costly: To infer them, one needs to compare the cursors of every block.
        //       Instead of eliminating C.head and P.head, we consider them to be cached heads, i.e., potentially stale
        //       values of the phantom heads. Cached heads only exist for performance reasons; their staleness does not
        //       affect correctness."
        // 3.3 contains other important discussion including phantom heads. I will not reproduce it all here.
        p_head: Head = 0,
        c_head: Head = 0,

        alloc: std.mem.Allocator,
        qvar: QVar,
        options: BlockOptions,

        data: []T,
        blocks: []Block,

        const EntryDesc = struct {
            version: u64,
            offset: u64,
            block: *Block,
        };

        const Block = struct {
            index: u32,
            consumed: Cursor,
            reserved: Cursor,
            committed: Cursor,
            allocated: Cursor,
            entries: []T,
        };

        pub fn init(alloc: std.mem.Allocator, options: BlockOptions) !Self {
            assert(options.block_number > 1);
            assert(options.block_size > 1);

            const data = try alloc.alloc(T, options.block_number * options.block_size);
            const blocks = try alloc.alloc(Block, options.block_number);
            for (0..options.block_number) |i| {
                const initial_cursor: Cursor = if (i == 0) 0 else options.block_size;
                blocks[i] = .{
                    .index = @intCast(i),
                    .consumed = initial_cursor,
                    .reserved = initial_cursor,
                    .committed = initial_cursor,
                    .allocated = initial_cursor,
                    .entries = data[i * options.block_size .. (i + 1) * options.block_size],
                };
            }

            return .{
                .alloc = alloc,
                .qvar = QVar.init(options),
                .options = options,

                .data = data,
                .blocks = blocks,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.blocks);
            self.alloc.free(self.data);
            self.* = undefined;
        }

        pub fn enqueue(self: *Self, data: T) error{ Full, Busy }!void {
            while (true) {
                const head, const block = self.getProducerHead();

                if (self.allocateEntry(block)) |entry_descriptor| {
                    commitEntry(entry_descriptor, data);
                    return;
                } else {
                    self.advanceProducerHead(head) catch |e| switch (e) {
                        error.NoEntry => return error.Full,
                        error.NotAvailable => return error.Busy,
                    };
                    continue;
                }
            }
        }

        pub fn dequeue(self: *Self) error{ Empty, Busy }!T {
            var reserved_version: u64 = 0;
            while (true) {
                const head, const block = self.getConsumerHead();

                const entry_description = self.reserveEntry(block, &reserved_version) catch |e| switch (e) {
                    error.NoEntry => return error.Empty,
                    error.NotAvailable => return error.Busy,
                    error.BlockDone => {
                        if (self.advanceConsumerHead(head, reserved_version)) continue else return error.Empty;
                    },
                };

                if (self.consumeEntry(entry_description)) |data| {
                    return data;
                } else {
                    continue;
                }
            }
        }

        fn getProducerHead(self: *Self) struct { Head, *Block } {
            const head = @atomicLoad(Head, &self.p_head, .seq_cst);
            const block = &self.blocks[self.qvar.getHeadIndex(head)];
            return .{ head, block };
        }

        fn allocateEntry(self: *Self, block: *Block) ?EntryDesc {
            const allocated = @atomicLoad(Cursor, &block.allocated, .seq_cst);
            const allocated_offset = self.qvar.getCursorOffset(allocated);
            if (allocated_offset >= self.options.block_size) {
                return null;
            }

            const old = @atomicRmw(Cursor, &block.allocated, .Add, 1, .seq_cst);
            assert(self.qvar.getCursorVersion(old) == self.qvar.getCursorVersion(old + 1)); // ERROR: Version overflow detected. You may have too many producers and too small of a block size. If #producers exceeds `log2_ceil(block_size)` then you may hit this issue.
            const old_offset = self.qvar.getCursorOffset(old);
            if (old_offset >= self.options.block_size) {
                return null;
            }

            // The paper does NOT indicate that the version should be set. Previously, I had always set this to 0,
            // as per the paper's description of unspecified fields being set to zero.
            const old_version = self.qvar.getCursorVersion(old);

            return .{
                .version = old_version,
                .offset = old_offset,
                .block = block,
            };
        }

        fn commitEntry(entry_descriptor: EntryDesc, data: T) void {
            entry_descriptor.block.entries[entry_descriptor.offset] = data;

            _ = @atomicRmw(Cursor, &entry_descriptor.block.committed, .Add, 1, .seq_cst);
        }

        fn advanceProducerHead(self: *Self, head: Head) error{ NoEntry, NotAvailable }!void {
            const head_version = self.qvar.getHeadVersion(head);

            var next_block = &self.blocks[(self.qvar.getHeadIndex(head) + 1) % self.blocks.len];

            switch (mode) {
                .retry_new => self.advanceProducerHeadRetryNew(head, next_block) catch |e| return e,
                .drop_old => self.advanceProducerHeadDropOld(head, next_block) catch |e| return e,
            }

            const new_cursor = self.qvar.newCursor(head_version + 1, 0);
            _ = @atomicRmw(Cursor, &next_block.committed, .Max, new_cursor, .seq_cst);
            _ = @atomicRmw(Cursor, &next_block.allocated, .Max, new_cursor, .seq_cst);

            // 4.2.2 Order Matters - "updating cached heads (...) must happen after updating block-level variables (...), otherwise blocks may be fully skipped."
            _ = @atomicRmw(Head, &self.p_head, .Max, self.qvar.nextHead(head), .seq_cst);
        }

        fn advanceProducerHeadRetryNew(self: *Self, head: Head, next_block: *Block) error{ NoEntry, NotAvailable }!void {
            const head_version = self.qvar.getHeadVersion(head);
            const consumed = @atomicLoad(Cursor, &next_block.consumed, .seq_cst);

            const consumed_version = self.qvar.getCursorVersion(consumed);
            const consumed_offset = self.qvar.getCursorOffset(consumed);

            if (consumed_version < head_version or (consumed_version == head_version and consumed_offset != self.options.block_size)) {
                const reserved = @atomicLoad(Cursor, &next_block.reserved, .seq_cst);

                const reserved_offset = self.qvar.getCursorOffset(reserved);
                if (reserved_offset == consumed_offset) {
                    return error.NoEntry;
                } else {
                    return error.NotAvailable;
                }
            }
        }

        fn advanceProducerHeadDropOld(self: *Self, head: Head, next_block: *Block) error{ NoEntry, NotAvailable }!void {
            const head_version = self.qvar.getHeadVersion(head);

            const committed = @atomicLoad(Cursor, &next_block.committed, .seq_cst);

            const committed_version = self.qvar.getCursorVersion(committed);
            const committed_offset = self.qvar.getCursorOffset(committed);

            if (committed_version == head_version and committed_offset != self.options.block_size) {
                return error.NotAvailable;
            }
        }

        fn getConsumerHead(self: *Self) struct { Head, *Block } {
            const head = @atomicLoad(Head, &self.c_head, .seq_cst);
            const block = &self.blocks[self.qvar.getHeadIndex(head)];
            return .{ head, block };
        }

        fn reserveEntry(self: *Self, block: *Block, out_reserved_version: *u64) error{ NoEntry, NotAvailable, BlockDone }!EntryDesc {
            while (true) {
                const reserved = @atomicLoad(Cursor, &block.reserved, .seq_cst);
                const reserved_version = self.qvar.getCursorVersion(reserved);
                const reserved_offset = self.qvar.getCursorOffset(reserved);
                if (reserved_offset < self.options.block_size) {
                    assert(self.qvar.getCursorVersion(reserved + 1) == reserved_version); // ERROR: Version overflow detected. You may have too many producers and too small of a block size. If #producers exceeds `log2_ceil(block_size)` then you may hit this issue.

                    const committed = @atomicLoad(Cursor, &block.committed, .seq_cst);
                    const committed_offset = self.qvar.getCursorOffset(committed);
                    if (reserved_offset == committed_offset) {
                        return error.NoEntry;
                    }

                    if (committed_offset != self.options.block_size) {
                        const allocated = @atomicLoad(Cursor, &block.allocated, .seq_cst);
                        const allocated_offset = self.qvar.getCursorOffset(allocated);
                        if (allocated_offset != committed_offset) {
                            return error.NotAvailable;
                        }
                    }

                    if (@atomicRmw(Cursor, &block.reserved, .Max, reserved + 1, .seq_cst) == reserved) {
                        return .{
                            .block = block,
                            .offset = reserved_offset,
                            .version = reserved_version,
                        };
                    } else {
                        continue;
                    }
                }

                out_reserved_version.* = reserved_version;
                return error.BlockDone;
            }
        }

        fn consumeEntry(self: *Self, entry_descriptor: EntryDesc) ?T {
            const data = entry_descriptor.block.entries[entry_descriptor.offset];

            switch (mode) {
                .retry_new => {
                    const prev = @atomicRmw(Cursor, &entry_descriptor.block.consumed, .Add, 1, .seq_cst);
                    assert(self.qvar.getCursorVersion(prev + 1) == self.qvar.getCursorVersion(prev)); // ERROR: Version overflow detected. You may have too many producers and too small of a block size. If #producers exceeds `log2_ceil(block_size)` then you may hit this issue.
                    return data;
                },
                .drop_old => {
                    const allocated = @atomicLoad(Cursor, &entry_descriptor.block.allocated, .seq_cst);
                    const allocated_version = self.qvar.getCursorVersion(allocated);

                    // In the drop-old mode, the producer may have overwritten the entry after we started to handle it, in this case
                    // we return null to indicate that the entry is no longer valid and the consumer will move on.
                    return if (allocated_version != entry_descriptor.version) null else data;
                },
            }
        }

        fn advanceConsumerHead(self: *Self, head: Head, reserved_version: u64) bool {
            const head_version = self.qvar.getHeadVersion(head);
            const next_block = &self.blocks[(self.qvar.getHeadIndex(head) + 1) % self.blocks.len];

            const committed = @atomicLoad(Cursor, &next_block.committed, .seq_cst);
            const committed_version = self.qvar.getCursorVersion(committed);

            switch (mode) {
                .retry_new => {
                    if (committed_version != head_version + 1) {
                        return false;
                    }

                    const next_cursor = self.qvar.newCursor(head_version + 1, 0);
                    _ = @atomicRmw(Cursor, &next_block.consumed, .Max, next_cursor, .seq_cst);
                    _ = @atomicRmw(Cursor, &next_block.reserved, .Max, next_cursor, .seq_cst);
                },
                .drop_old => {
                    const head_index = self.qvar.getHeadIndex(head);
                    if (committed_version < (reserved_version + @as(u64, @intFromBool(head_index == 0)))) {
                        return false;
                    }

                    const next_cursor = self.qvar.newCursor(committed_version, 0);
                    _ = @atomicRmw(Cursor, &next_block.reserved, .Max, next_cursor, .seq_cst);
                },
            }

            _ = @atomicRmw(Head, &self.c_head, .Max, self.qvar.nextHead(head), .seq_cst);
            return true;
        }
    };
}

test "BBQ (retry-new) enqueues fill the queue then return an error indicating that it is full" {
    const T = u8;
    const options = BlockOptions{ .block_number = 4, .block_size = 2 };

    var bbq = try RetryNewQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    for (0..(options.block_number * options.block_size)) |i| {
        try bbq.enqueue(@as(T, @truncate(i)));
    }

    try std.testing.expectError(error.Full, bbq.enqueue(0));
}

test "BBQ (drop-old) enqueues fill the queue then overwrite the oldest entry" {
    const T = u8;
    const options = BlockOptions{ .block_number = 4, .block_size = 2 };

    var bbq = try DropOldQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    const additional_overwrites: u32 = 100;
    for (0..(options.block_number * options.block_size) + additional_overwrites) |i| {
        try bbq.enqueue(@as(T, @truncate(i)));
    }
}

test "BBQ (retry-new) basic enqueue/dequeue FIFO and Empty after drain" {
    const T = u32;
    const options = BlockOptions{ .block_number = 4, .block_size = 2 }; // capacity = 8

    var bbq = try RetryNewQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    try bbq.enqueue(10);
    try bbq.enqueue(11);
    try bbq.enqueue(12);

    try std.testing.expectEqual(@as(T, 10), try bbq.dequeue());
    try std.testing.expectEqual(@as(T, 11), try bbq.dequeue());
    try std.testing.expectEqual(@as(T, 12), try bbq.dequeue());

    try std.testing.expectError(error.Empty, bbq.dequeue());
}

test "BBQ (retry-new) fill exactly, then dequeue all in order and then Empty" {
    const T = u16;
    const options = BlockOptions{ .block_number = 4, .block_size = 2 }; // capacity = 8

    var bbq = try RetryNewQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    const cap: usize = options.block_number * options.block_size;
    for (0..cap) |i| try bbq.enqueue(@as(T, @truncate(i)));

    for (0..cap) |i| {
        const got = try bbq.dequeue();
        try std.testing.expectEqual(@as(T, @truncate(i)), got);
    }

    try std.testing.expectError(error.Empty, bbq.dequeue());
}

test "BBQ (drop-old) overwrites oldest; dequeue returns a contiguous suffix ending with latest" {
    const T = u32;
    const options = BlockOptions{ .block_number = 4, .block_size = 2 }; // capacity = 8

    var bbq = try DropOldQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    const cap: usize = options.block_number * options.block_size;
    const total: usize = cap + 5; // write past capacity

    for (0..total) |i| try bbq.enqueue(@as(T, @truncate(i)));

    var list = std.ArrayList(T).init(std.testing.allocator);
    defer list.deinit();

    while (true) {
        const val = bbq.dequeue() catch |e| switch (e) {
            error.Empty => break,
            else => return e,
        };
        try list.append(val);
    }

    try std.testing.expect(list.items.len > 0);
    try std.testing.expect(list.items.len <= cap);
    try std.testing.expectEqual(@as(T, @intCast(total - 1)), list.items[list.items.len - 1]);
    for (1..list.items.len) |i| {
        try std.testing.expectEqual(list.items[i - 1] + 1, list.items[i]);
    }
}

test "BBQ (drop-old) interleave dequeues and ensure window behavior" {
    const T = u8;
    const options = BlockOptions{ .block_number = 4, .block_size = 2 }; // capacity = 8

    var bbq = try DropOldQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    // Enqueue 4 items
    for (0..4) |i| try bbq.enqueue(@as(T, @truncate(i))); // [0,1,2,3]

    // Dequeue 2
    try std.testing.expectEqual(@as(T, 0), try bbq.dequeue());
    try std.testing.expectEqual(@as(T, 1), try bbq.dequeue());

    // Enqueue 6 more (exceeds remaining capacity and forces overwrites of the oldest unseen entries)
    for (4..10) |i| try bbq.enqueue(@as(T, @truncate(i))); // final retained should be last 8 of 0..9 => 2..9

    // We already consumed 0,1. The queue should now have 8 most recent: 2..9
    for (2..10) |i| {
        const got = try bbq.dequeue();
        try std.testing.expectEqual(@as(T, @truncate(i)), got);
    }

    try std.testing.expectError(error.Empty, bbq.dequeue());
}

test "BBQ supports non-power-of-two sizes (retry-new): 3 blocks x 3 entries" {
    const T = u16;
    const options = BlockOptions{ .block_number = 3, .block_size = 3 }; // capacity = 9 (non-power-of-two)

    var bbq = try RetryNewQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    const cap: usize = options.block_number * options.block_size; // 9
    for (0..cap) |i| try bbq.enqueue(@as(T, @truncate(i)));

    // Next enqueue should fail in retry-new mode
    try std.testing.expectError(error.Full, bbq.enqueue(999));

    // Drain and ensure FIFO order
    for (0..cap) |i| {
        const got = try bbq.dequeue();
        try std.testing.expectEqual(@as(T, @truncate(i)), got);
    }
    try std.testing.expectError(error.Empty, bbq.dequeue());
}

test "BBQ supports non-power-of-two sizes (drop-old): 3 blocks x 3 entries with overwrite" {
    const T = u32;
    const options = BlockOptions{ .block_number = 3, .block_size = 3 }; // capacity = 9 (non-power-of-two)

    var bbq = try DropOldQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    const cap: usize = options.block_number * options.block_size; // 9
    const total: usize = cap + 7; // 16 total pushes, forces wrap/overwrite
    for (0..total) |i| try bbq.enqueue(@as(T, @truncate(i)));

    // Collect all available items and validate contiguous increasing suffix ending at latest
    var list = std.ArrayList(T).init(std.testing.allocator);
    defer list.deinit();

    while (true) {
        const val = bbq.dequeue() catch |e| switch (e) {
            error.Empty => break,
            else => return e,
        };
        try list.append(val);
    }

    try std.testing.expect(list.items.len > 0);
    try std.testing.expect(list.items.len <= cap);
    try std.testing.expectEqual(@as(T, @intCast(total - 1)), list.items[list.items.len - 1]);
    for (1..list.items.len) |i| {
        try std.testing.expectEqual(list.items[i - 1] + 1, list.items[i]);
    }
}

test "BBQ with 3 blocks exposes old mask bug: interleave enq/deq works" {
    const T = u8;
    const options = BlockOptions{ .block_number = 3, .block_size = 2 }; // capacity = 6; 3 is non-power-of-two

    var bbq = try DropOldQueue(T).init(std.testing.allocator, options);
    defer bbq.deinit();

    // Initial enqueues
    for (0..4) |i| try bbq.enqueue(@as(T, @truncate(i))); // [0..3]

    // Dequeue a couple
    try std.testing.expectEqual(@as(T, 0), try bbq.dequeue());
    try std.testing.expectEqual(@as(T, 1), try bbq.dequeue());

    // Enqueue beyond capacity to force wrap/overwrite across the 3-block boundary
    for (4..12) |i| try bbq.enqueue(@as(T, @truncate(i))); // pushes 8 more

    // Read out what remains: should be a contiguous increasing suffix ending at latest
    var last: ?T = null;
    var count: usize = 0;
    while (true) {
        const val = bbq.dequeue() catch |e| switch (e) {
            error.Empty => break,
            else => return e,
        };
        if (last) |prev| {
            try std.testing.expectEqual(prev + 1, val);
        }
        last = val;
        count += 1;
    }
    try std.testing.expect(count > 0);
}

test "QVar bitfield encode/decode roundtrip for arbitrary sizes" {
    var random = std.Random.DefaultPrng.init(42);
    var rng = random.random();

    const trials: usize = 12;
    var t: usize = 0;
    while (t < trials) : (t += 1) {
        const bn: u32 = 2 + @as(u32, @intCast(rng.int(u32) % 13)); // [2..14]
        const bs: u32 = 2 + @as(u32, @intCast(rng.int(u32) % 11)); // [2..12]
        const options = BlockOptions{ .block_number = bn, .block_size = bs };

        const qv = QVar.init(options);

        const v_hi: u64 = if (qv.version_mask > 3) 3 else qv.version_mask; // test small range within mask

        var v: u64 = 0;
        while (v <= v_hi) : (v += 1) {
            // Head roundtrip for all valid indices
            var idx: u64 = 0;
            while (idx < options.block_number) : (idx += 1) {
                const h = qv.newHead(v, idx);
                try std.testing.expectEqual(v, qv.getHeadVersion(h));
                try std.testing.expectEqual(idx, qv.getHeadIndex(h));
            }

            // Cursor roundtrip for a few offsets including boundaries
            var off: u64 = 0;
            while (off <= options.block_size) : (off += @max(@as(u64, 1), options.block_size / 3)) {
                const c = qv.newCursor(v, off);
                try std.testing.expectEqual(v, qv.getCursorVersion(c));
                try std.testing.expectEqual(off, qv.getCursorOffset(c));
                if (off == options.block_size) break; // ensure inclusion of max once
            }
        }
    }
}

test "QVar nextHead wraps index and bumps version at end of block" {
    const configs = [_]BlockOptions{
        .{ .block_number = 3, .block_size = 2 },
        .{ .block_number = 5, .block_size = 7 },
        .{ .block_number = 8, .block_size = 4 },
    };

    for (configs) |options| {
        const qv = QVar.init(options);

        // Mid-block increment keeps version, bumps index
        const h_mid = qv.newHead(10, 1);
        const n_mid = qv.nextHead(h_mid);
        try std.testing.expectEqual(@as(u64, 10), qv.getHeadVersion(n_mid));
        try std.testing.expectEqual(@as(u64, 2), qv.getHeadIndex(n_mid));

        // End-of-block wraps to index 0 and increments version
        const last_idx: u64 = options.block_number - 1;
        const h_end = qv.newHead(10, last_idx);
        const n_end = qv.nextHead(h_end);
        try std.testing.expectEqual(@as(u64, 11), qv.getHeadVersion(n_end));
        try std.testing.expectEqual(@as(u64, 0), qv.getHeadIndex(n_end));
    }
}

/// Used to perform operations on Head and Cursor [q]ueue [var]iables. BBQ queue variables
/// each contain two fields. We use a single machine word to enable clean atomic operations;
/// however, some bit manipulation is required to access the fields within the variable.
const QVar = struct {
    const Self = @This();

    cursor_offset_mask: u64,
    head_index_mask: u64,
    version_mask: u64,

    cursor_version_shift: u6,
    head_version_shift: u6,

    block_number: u64,
    block_size: u64,

    fn init(block_parameters: BlockOptions) Self {
        assert(block_parameters.block_size >= 2);
        assert(block_parameters.block_number >= 2);

        // The paper describes using one bit as overflow protection, however, this does not adequately
        // project from overflow in cases where the block size is small and number of producers is large.
        // E.g. when block size = 4 and producers = 8, there is the possibility for the 0b011 offset to
        // concurrently fetch and add by all producers, causing it to overflow and corrupt the version field.
        // I don't think we can compute this value, since we cannot know how many producers or consumers will
        // use the queue. I've added assertions which should detect this condition.
        const cursor_offset_overflow_bits = 1;
        const cursor_offset_bits = cursor_offset_overflow_bits + std.math.log2_int_ceil(u64, block_parameters.block_size);
        const head_index_bits = std.math.log2_int_ceil(u64, block_parameters.block_number);
        const version_bits = 64 - @max(cursor_offset_bits, head_index_bits);

        assert(cursor_offset_bits > 0 and cursor_offset_bits <= std.math.maxInt(u6));
        assert(head_index_bits > 0 and head_index_bits <= std.math.maxInt(u6));

        const version_mask = (@as(u64, 1) << @as(u6, @intCast(version_bits))) - 1;
        const cursor_offset_mask = (@as(u64, 1) << @as(u6, @intCast(cursor_offset_bits))) - 1;
        const head_index_mask = (@as(u64, 1) << @as(u6, @intCast(head_index_bits))) - 1;

        return .{
            .cursor_offset_mask = cursor_offset_mask,
            .head_index_mask = head_index_mask,
            .version_mask = version_mask,

            .cursor_version_shift = @intCast(cursor_offset_bits),
            .head_version_shift = @intCast(head_index_bits),

            .block_number = block_parameters.block_number,
            .block_size = block_parameters.block_size,
        };
    }

    fn getCursorOffset(self: QVar, cursor: Cursor) u64 {
        return cursor & self.cursor_offset_mask;
    }

    fn getCursorVersion(self: QVar, cursor: Cursor) u64 {
        return (cursor >> self.cursor_version_shift) & self.version_mask;
    }

    fn getHeadIndex(self: QVar, head: Head) u64 {
        return head & self.head_index_mask;
    }

    fn getHeadVersion(self: QVar, head: Head) u64 {
        return (head >> self.head_version_shift) & self.version_mask;
    }

    fn newHead(self: QVar, version: u64, index: u64) Head {
        assert(index < self.block_number);
        assert(index <= self.head_index_mask);
        assert(version <= self.version_mask);
        return ((version & self.version_mask) << self.head_version_shift) | (index & self.head_index_mask);
    }

    fn nextHead(self: QVar, head: Head) Head {
        const ver = self.getHeadVersion(head);
        const idx = self.getHeadIndex(head);
        if (idx + 1 < self.block_number) {
            return self.newHead(ver, idx + 1);
        } else {
            return self.newHead(ver + 1, 0);
        }
    }

    fn newCursor(self: QVar, version: u64, offset: u64) Cursor {
        assert(offset <= self.cursor_offset_mask);
        assert(offset <= self.block_size);
        assert(version <= self.version_mask);
        return ((version & self.version_mask) << self.cursor_version_shift) | (offset & self.cursor_offset_mask);
    }
};

// 4.1 - "Head and Cursor types are 64-bit integers, which can be atomically updated"
// 4.1 - "We reserve two bit-segments in Head to represent the version and index"
const Head = u64;
// 4.1 - "We reserve [...] two bit-segments in Cursor to represent the version and offset"
const Cursor = u64;

const FullHandlingMode = enum {
    /// When the queue is full, the enqueue operation will return an error without mutating the queue.
    // 1 - "Retry-new is the typical producer-consumer mode for message passing and work distribution scenarios."
    retry_new,

    /// When the queue is full, the enqueue operation will overwrite the oldest entry in the queue. That overwritten
    /// entry will not be consumed by any consumer.
    // 1 - "drop-old is a lossy/overwrite mode for profiling/tracing [5,24] and debugging [44] scenar ios, in
    //     which producers may overwrite unconsumed data if the buffer is full"
    drop_old,
};