//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT

const std = @import("std");
const bbq = @import("bbq");

// Hard-coded scenario parameters (stress defaults)
const RUN_STRESS: bool = false; // enable in next step
const PRODUCERS: u32 = 8;
const CONSUMERS: u32 = 1;
const BLOCK_NUMBER: u32 = 31; // small capacity to force contention
const BLOCK_SIZE: u32 = 2; // capacity = 62 (queue requires block_size > 1)
const ITEMS_PER_PRODUCER: u64 = 100_000; // keep for stress; can reduce temporarily during development
const WATCHDOG_TIMEOUT_SECS: u64 = 30;

const Item = struct {
    producer_id: u32,
    seq: u64,
    checksum: u64,
};

fn checksum(producer_id: u32, seq: u64) u64 {
    var h = std.hash.Wyhash.init(0xa1b2c3d4e5f60789);
    h.update(std.mem.asBytes(&producer_id));
    h.update(std.mem.asBytes(&seq));
    return h.final();
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    // Step 1: Ensure we can initialize and deinit the queue.
    const options = bbq.BlockOptions{ .block_number = BLOCK_NUMBER, .block_size = BLOCK_SIZE };
    var q = try bbq.BBQ(Item).init(alloc, .retry_new, options);
    defer q.deinit();

    // Smoke insert/dequeue just to verify wiring before stress logic lands
    try q.enqueue(.{ .producer_id = 0, .seq = 0, .checksum = checksum(0, 0) });
    const got = try q.dequeue();
    if (got.producer_id != 0 or got.seq != 0 or got.checksum != checksum(0, 0)) {
        return error.InitSmokeFailed;
    }

    // If only validating initialization wiring, stop here.
    if (!RUN_STRESS) {
        std.debug.print("BBQ init smoke test passed.\n", .{});
        return;
    }

    // Scenario run
    const P: usize = PRODUCERS;
    const C: usize = CONSUMERS;
    const N: u64 = ITEMS_PER_PRODUCER;
    const CAP: usize = BLOCK_NUMBER * BLOCK_SIZE;

    std.debug.print("Starting stress: P={d}, C={d}, cap={d}, N={d}\n", .{ P, C, CAP, N });

    // Shared counters (plain ints with atomic builtins)
    var deq_ok: usize = 0;
    var progress: u64 = 0;

    // Start barrier
    const Barrier = struct {
        count: u32 = 0,
        total: u32,
        fn wait(self: *@This()) void {
            _ = @atomicRmw(u32, &self.count, .Add, 1, .acq_rel);
            while (@atomicLoad(u32, &self.count, .acquire) < self.total) {
                std.Thread.yield() catch {};
            }
        }
    };
    var barrier = Barrier{ .total = @intCast(P + C) };

    // Per-producer success counts
    var producer_counts = try alloc.alloc(u64, P);
    defer alloc.free(producer_counts);
    @memset(producer_counts, 0);

    // Per-consumer logs: store all Items to verify at end
    var consumer_logs = try alloc.alloc(std.ArrayList(Item), C);
    defer {
        // deinit lists
        for (consumer_logs) |*lst| lst.deinit();
        alloc.free(consumer_logs);
    }
    for (consumer_logs) |*lst| lst.* = std.ArrayList(Item).init(alloc);

    // Random helper per-thread
    const Prng = struct {
        rng: std.Random.DefaultPrng,
        fn init(seed: u64) @This() {
            return .{ .rng = std.Random.DefaultPrng.init(seed) };
        }
        fn jitter(self: *@This(), n: u32) void {
            const v = self.rng.random().intRangeAtMost(u32, 0, n);
            if (v % 8 == 0) {
                std.Thread.yield() catch {};
            } else if (v % 7 == 0) {
                std.time.sleep(2000); // 2us
            }
        }
    };

    // Watchdog
    var wd_stop: u8 = 0;
    const watcher = try std.Thread.spawn(.{}, struct {
        fn run(progress_ptr: *u64, wd_stop_ptr: *u8) void {
            const timeout_ns = WATCHDOG_TIMEOUT_SECS * std.time.ns_per_s;
            var last = @atomicLoad(u64, progress_ptr, .acquire);
            var last_ts = std.time.nanoTimestamp();
            while (@atomicLoad(u8, wd_stop_ptr, .acquire) == 0) {
                std.time.sleep(10 * std.time.ns_per_ms);
                const now = std.time.nanoTimestamp();
                const cur = @atomicLoad(u64, progress_ptr, .acquire);
                if (cur != last) {
                    last = cur;
                    last_ts = now;
                    continue;
                }
                if (@as(u128, @intCast(now - last_ts)) > @as(u128, timeout_ns)) {
                    std.debug.print("WATCHDOG timeout: no progress for {d}s (progress={d})\n", .{ WATCHDOG_TIMEOUT_SECS, cur });
                    // Hard exit on timeout (cross-platform)
                    std.process.exit(1);
                }
            }
        }
    }.run, .{ &progress, &wd_stop });
    defer watcher.join();

    // Spawn producers
    const prod_threads = try alloc.alloc(std.Thread, P);
    defer alloc.free(prod_threads);
    for (prod_threads, 0..) |*th, i| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn run(id: u32, queue_ptr: *bbq.BBQ(Item), num_items: u64, barrier_ptr: *Barrier, pc: *u64, progress_ptr: *u64) void {
                var prng = Prng.init(0xC001D00D + id);
                barrier_ptr.wait();
                var seq: u64 = 0;
                while (seq < num_items) {
                    const it = Item{ .producer_id = id, .seq = seq, .checksum = checksum(id, seq) };
                    queue_ptr.enqueue(it) catch |e| switch (e) {
                        error.Full, error.Busy => {
                            prng.jitter(31);
                            continue;
                        },
                    };
                    // success
                    seq += 1;
                    pc.* = seq;
                    _ = @atomicRmw(u64, progress_ptr, .Add, 1, .acq_rel);
                }
            }
        }.run, .{ @as(u32, @intCast(i)), &q, N, &barrier, &producer_counts[i], &progress });
    }

    // Spawn consumers
    const cons_threads = try alloc.alloc(std.Thread, C);
    defer alloc.free(cons_threads);
    for (cons_threads, 0..) |*th, cidx| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn run(queue_ptr: *bbq.BBQ(Item), barrier_ptr: *Barrier, total_target: usize, deq_count_ptr: *usize, progress_ptr: *u64, out_log: *std.ArrayList(Item)) void {
                const seed: u64 = 0xBADBEEF0000 + @as(u64, @intCast(total_target));
                var prng = Prng.init(seed ^ 0x55);
                barrier_ptr.wait();
                while (true) {
                    const done = @atomicLoad(usize, deq_count_ptr, .acquire) >= total_target;
                    if (done) break;

                    const it = queue_ptr.dequeue() catch |e| switch (e) {
                        error.Empty, error.Busy => {
                            prng.jitter(31);
                            continue;
                        },
                    };
                    _ = @atomicRmw(usize, deq_count_ptr, .Add, 1, .acq_rel);
                    _ = @atomicRmw(u64, progress_ptr, .Add, 1, .acq_rel);
                    // Append to local log
                    out_log.append(it) catch {};
                }
            }
        }.run, .{ &q, &barrier, P * @as(usize, @intCast(N)), &deq_ok, &progress, &consumer_logs[cidx] });
    }

    // Join producers
    for (prod_threads) |*th| th.join();

    // Wait for consumers to drain remaining items
    while (@atomicLoad(usize, &deq_ok, .acquire) < @as(usize, @intCast(P)) * @as(usize, @intCast(N))) {
        std.time.sleep(1000);
    }
    for (cons_threads) |*th| th.join();

    // Stop watchdog
    @atomicStore(u8, &wd_stop, 1, .release);

    // Totals
    var total_enq: u64 = 0;
    for (producer_counts) |cnt| total_enq += cnt;
    const total_deq: usize = @atomicLoad(usize, &deq_ok, .acquire);

    // Collate logs into one array for verification
    var all = std.ArrayList(Item).init(alloc);
    defer all.deinit();
    for (consumer_logs) |*lst| try all.appendSlice(lst.items);

    // Basic totals
    const expected_total: usize = P * @as(usize, @intCast(N));
    if (total_enq != N * @as(u64, P) or total_deq != expected_total or all.items.len != expected_total) {
        std.debug.print("FAIL totals: P={d} C={d} cap={d} N={d} enq_ok={d} deq_ok={d} log={d}\n", .{ P, C, CAP, N, total_enq, total_deq, all.items.len });
        return error.TotalsMismatch;
    }

    // Verification structures
    // For duplicates and exact multiset: bitsets per producer of size N
    // Use a packed bitset in an ArrayList(u64)
    const Bits = struct {
        data: []u64,
        fn init(allocator: std.mem.Allocator, nbits: usize) !@This() {
            const words = (nbits + 63) / 64;
            const buf = try allocator.alloc(u64, words);
            @memset(buf, 0);
            return .{ .data = buf };
        }
        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.data);
        }
        fn testSet(self: *@This(), idx: usize) bool {
            const w = idx / 64;
            const b = idx % 64;
            const mask: u64 = (@as(u64, 1) << @intCast(b));
            const prev = self.data[w];
            self.data[w] = prev | mask;
            return (prev & mask) != 0;
        }
    };

    var bitsets = try alloc.alloc(Bits, P);
    defer {
        for (bitsets) |*bs| bs.deinit(alloc);
        alloc.free(bitsets);
    }
    for (bitsets) |*bs| bs.* = try Bits.init(alloc, @intCast(N));

    // Track FIFO per producer
    var last_seq = try alloc.alloc(i64, P);
    defer alloc.free(last_seq);
    for (last_seq) |*v| v.* = -1;

    // Checks
    var dup_found = false;
    var fifo_violation = false;
    var invalid_found = false;
    var first_dup: ?Item = null;
    var fifo_detail: struct { pid: u32, last: i64, cur: i64, pos: usize } = .{ .pid = 0, .last = 0, .cur = 0, .pos = 0 };

    for (all.items, 0..) |it, pos| {
        // No spurious values
        if (it.producer_id >= P or it.seq >= N or it.checksum != checksum(it.producer_id, it.seq)) {
            invalid_found = true;
            std.debug.print("FAIL invalid item at pos={d}: pid={d} seq={d}\n", .{ pos, it.producer_id, it.seq });
            break;
        }

        // Duplicates and exact multiset tracking
        const repeated = bitsets[@intCast(it.producer_id)].testSet(@intCast(it.seq));
        if (repeated and !dup_found) {
            dup_found = true;
            first_dup = it;
        }

        // FIFO per producer
        const prev = last_seq[@intCast(it.producer_id)];
        if (@as(i64, @intCast(it.seq)) <= prev and !fifo_violation) {
            fifo_violation = true;
            fifo_detail = .{ .pid = it.producer_id, .last = prev, .cur = @intCast(it.seq), .pos = pos };
        }
        last_seq[@intCast(it.producer_id)] = @intCast(it.seq);
    }

    // Check completeness: each bitset must have all bits set in [0, N)
    var missing_total: usize = 0;
    const show_gaps: usize = 8;
    var gaps_buf = try alloc.alloc(struct { pid: u32, seq: u64 }, show_gaps);
    defer alloc.free(gaps_buf);
    var gaps_len: usize = 0;
    for (bitsets, 0..) |bs, pid| {
        var s: u64 = 0;
        while (s < N) : (s += 1) {
            const w = @as(usize, @intCast(s)) / 64;
            const b = @as(usize, @intCast(s)) % 64;
            const mask: u64 = (@as(u64, 1) << @intCast(b));
            const set = (bs.data[w] & mask) != 0;
            if (!set) {
                if (gaps_len < show_gaps) {
                    gaps_buf[gaps_len] = .{ .pid = @intCast(pid), .seq = s };
                    gaps_len += 1;
                }
                missing_total += 1;
            }
        }
    }

    if (invalid_found or dup_found or fifo_violation or missing_total != 0) {
        std.debug.print("FAIL diagnostics:\n", .{});
        std.debug.print("  Params: P={d} C={d} cap={d} N={d}\n", .{ P, C, CAP, N });
        std.debug.print("  Totals: enq_ok={d} deq_ok={d}\n", .{ total_enq, total_deq });
        if (dup_found) {
            if (first_dup) |d| {
                std.debug.print("  Duplicate example: pid={d} seq={d}\n", .{ d.producer_id, d.seq });
            }
        }
        if (missing_total != 0) {
            std.debug.print("  Missing total={d}, sample gaps:", .{missing_total});
            for (gaps_buf[0..gaps_len]) |g| std.debug.print(" (pid={d}, seq={d})", .{ g.pid, g.seq });
            std.debug.print("\n", .{});
        }
        if (fifo_violation) {
            std.debug.print("  FIFO violation: pid={d} last_seq={d} cur_seq={d} at pos={d}\n", .{ fifo_detail.pid, fifo_detail.last, fifo_detail.cur, fifo_detail.pos });
        }
        return error.VerificationFailed;
    }

    std.debug.print("PASS: P={d} C={d} cap={d} N={d} totals: enq={d} deq={d}\n", .{ P, C, CAP, N, total_enq, total_deq });
}
