//! Copyright (c) 2025, Theodore Sackos, All rights reserved.
//! SPDX-License-Identifier: MIT

const std = @import("std");
const bbq = @import("bbq");

const WATCHDOG_TIMEOUT_SECS: u64 = 3;

const Item = struct {
    producer_id: u32,
    seq: u64,
};

pub fn main() !void {
    try run_throughput_test(.{
        .producers = 2,
        .consumers = 2,
        .items_per_producer = 100_000,
        .block_number = 32,
        .block_size = 512,
    });
}

const RegressionTestOptions = struct {
    producers: usize,
    consumers: usize,
    items_per_producer: u64,
    block_number: u32,
    block_size: u32,
};

fn printDurationHumanToWriter(writer: anytype, ns: u64) !void {
    if (ns >= 1_000_000_000) {
        try writer.print("{d} s", .{ns / 1_000_000_000});
    } else if (ns >= 1_000_000) {
        try writer.print("{d} ms", .{ns / 1_000_000});
    } else if (ns >= 1_000) {
        try writer.print("{d} us", .{ns / 1_000});
    } else {
        try writer.print("{d} ns", .{ns});
    }
}

pub fn run_throughput_test(test_options: RegressionTestOptions) !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    const options = bbq.BlockOptions{ .block_number = test_options.block_number, .block_size = test_options.block_size };
    var q = try bbq.RetryNewQueue(Item).init(alloc, options);
    defer q.deinit();

    // Scenario run
    const P: usize = test_options.producers;
    const C: usize = test_options.consumers;
    const N: u64 = test_options.items_per_producer;
    const CAP: usize = test_options.block_number * test_options.block_size;

    std.debug.print(
        "Starting throughput: P={d}, C={d}, BLOCKS={d}, BLOCK_SIZE={d}, capacity={d}, N={d}\n",
        .{
            P,
            C,
            test_options.block_number,
            test_options.block_size,
            CAP,
            N,
        },
    );

    // Start timing after initial setup/logging.
    var timer = try std.time.Timer.start();

    // Shared counters (plain ints with atomic builtins)
    var deq_ok: usize = 0;

    // Spawn producers
    const prod_threads = try alloc.alloc(std.Thread, P);
    defer alloc.free(prod_threads);
    for (prod_threads, 0..) |*th, i| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn run(id: u32, queue_ptr: *bbq.RetryNewQueue(Item), num_items: u64) !void {
                var seq: u64 = 0;
                while (seq < num_items) {
                    const it = Item{ .producer_id = id, .seq = seq };
                    queue_ptr.enqueue(it) catch |e| switch (e) {
                        error.Full, error.Busy => {
                            try std.Thread.yield();
                            continue;
                        },
                        else => @panic("Unable to enqueue due to unexpected error."),
                    };

                    // success
                    seq += 1;
                }
            }
        }.run, .{ @as(u32, @intCast(i)), &q, N });
    }

    // Spawn consumers
    const cons_threads = try alloc.alloc(std.Thread, C);
    defer alloc.free(cons_threads);
    // Per-consumer sums (u64 to avoid overflow)
    const cons_sums = try alloc.alloc(u64, C);
    defer alloc.free(cons_sums);
    for (cons_threads, 0..) |*th, ci| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn run(queue_ptr: *bbq.RetryNewQueue(Item), total_target: usize, deq_count_ptr: *usize, sum_out_ptr: *u64) void {
                var local_sum: u64 = 0;
                while (true) {
                    const done = @atomicLoad(usize, deq_count_ptr, .acquire) >= total_target;
                    if (done) break;

                    const it = queue_ptr.dequeue() catch |e| switch (e) {
                        error.Empty, error.Busy => {
                            continue;
                        },
                        else => @panic("Unable to dequeue due to unexpected error."),
                    };
                    local_sum += @as(u64, it.seq);
                    _ = @atomicRmw(usize, deq_count_ptr, .Add, 1, .acq_rel);
                }
                sum_out_ptr.* = local_sum;
            }
        }.run, .{ &q, P * @as(usize, @intCast(N)), &deq_ok, &cons_sums[ci] });
    }

    for (prod_threads) |*th| th.join();
    for (cons_threads) |*th| th.join();

    // Aggregate consumer sums and verify against analytical expectation
    var total_consumed_sum: u64 = 0;
    for (cons_sums) |s| total_consumed_sum += s;

    const n_u64: u64 = @as(u64, @intCast(N));
    const expected_per_producer: u64 = (n_u64 * (n_u64 - 1)) / 2; // sum 0..N-1
    const expected_total_sum: u64 = expected_per_producer * @as(u64, P);

    if (total_consumed_sum != expected_total_sum) {
        std.debug.print(
            "ERROR: checksum mismatch. total={d}, expected={d}\n",
            .{ total_consumed_sum, expected_total_sum },
        );
        return error.WrongSum;
    }

    // Throughput metrics (only reported if correctness check passes)
    const total_items: u64 = @as(u64, @intCast(P)) * n_u64;
    const elapsed_ns: u64 = timer.read();
    const total_items_f: f64 = @as(f64, @floatFromInt(total_items));
    const elapsed_ns_f: f64 = @as(f64, @floatFromInt(elapsed_ns));
    const duration_seconds: f64 = if (elapsed_ns != 0) elapsed_ns_f / 1_000_000_000.0 else 0.0;
    const ops_per_second: f64 = if (duration_seconds != 0.0) total_items_f / duration_seconds else 0.0;
    const ns_per_op: f64 = if (total_items != 0) elapsed_ns_f / total_items_f else 0.0;

    // Pretty-printed JSON for human and machine consumption, with units in keys.
    var out = std.io.getStdOut().writer();
    try out.print("{{\n", .{});
    try out.print("  \"params\": {{\n", .{});
    try out.print("    \"producers\": {d},\n", .{@as(u64, P)});
    try out.print("    \"consumers\": {d},\n", .{@as(u64, C)});
    try out.print("    \"items_per_producer\": {d},\n", .{N});
    try out.print("    \"block_number\": {d},\n", .{@as(u64, test_options.block_number)});
    try out.print("    \"block_size\": {d}\n", .{@as(u64, test_options.block_size)});
    try out.print("  }},\n", .{});
    try out.print("  \"duration_seconds\": {d:.4},\n", .{duration_seconds});
    try out.print("  \"ops_per_second\": {d},\n", .{@as(u32, @intFromFloat(ops_per_second))});
    try out.print("  \"ns_per_op\": {d}\n", .{ns_per_op});
    try out.print("}}\n", .{});
}
