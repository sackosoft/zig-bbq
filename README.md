<div align="center">

# zig-bbq

**High-performance, lock-free ring buffer for Zig, based on the BBQ algorithm described in [BBQ: A Block-based Bounded Queue for Exchanging Data and Profiling](https://www.usenix.org/conference/atc22/presentation/wang-jiawei).**

![GitHub License](https://img.shields.io/github/license/sackosoft/zig-bbq)
![Zig Version](https://img.shields.io/badge/Zig-0.16.1-blue)

<!--
TODO: Add a visualization, diagram, or demo of BBQ in action.
-->

</div>

## About

`zig-bbq` implements the **B**lock-based **B**ounded **Q**ueue (BBQ) algorithm; a lock-free threadsafe ring buffer,
designed for high-performance data transfer between threads. BBQ is suitable for both lossless ("retry-new") and
lossy ("drop-old") producer-consumer scenarios, making it ideal for message passing, work distribution, profiling,
tracing, and debugging.

The implementation is **lock-free** and **non-blocking**. The library has **zero dependencies**
outside of Zig's standard library. Queue behavior is configurable. The `RetryNewQueue` is a lossless
queue, calls to insert are rejected when the queue is full. The `DropOldQueue` is a lossy queue,
calls to insert overwrite the oldest unconsumed entry when the queue is full.

The authors of the research paper make the following claims. I cannot confirm or reject those claims,
but my own benchmarks on a modest laptop show a throughput of 2,500,000 items per second in a MPMC setup.
This is more than sufficient for my needs.

> "In **single-producer/single-consumer micro-benchmarks, BBQ yields 11.3x to 42.4x higher throughput** than 
the ringbuffers from Linux kernel, DPDK, Boost, and Folly libraries."

> "In **real world scenarios, BBQ achieves up to 1.5x, 50.5x, and 11.1x performance improvements** in
benchmarks of DPDK, Linux io\_uring, and Disruptor, respectively."

Emphasis added, [BBQ - USENIX ATC 2022 - Jiawei Wang et al.](https://www.usenix.org/system/files/atc22-wang-jiawei.pdf)

## Zig Version

The `main` branch targets the latest stable Zig release (currently `0.16.1`).

## AI Usage Disclosure

From my memory, AI was used for the following when developing this project:

- [x] As a teaching aid to dissect and understand topics of the research paper.
- [x] As a code reviewer to provide opinions and guidance regarding atomic memory ordering semantics.
- [x] To modify and author some parts of the regression test suite (`regression-test/src/main.zig`).
- [x] To draft the initial README.md.

AI was never used to author core functionality of the library (`src/bbq.zig`).
This library was developed as a learning experience and to explore and learn an
unfamiliar topic (memory models and memory ordering sematics).

## Installation

It is recommended that you install `zig-bbq` using `zig fetch`. This will add a `bbq` dependency to your `build.zig.zon` file.
The `zig-bbq` project has zero dependencies and is always statically linked. 

```bash
zig fetch --save=bbq git+https://github.com/sackosoft/zig-bbq
```

Next, in order for your code to import `zig-bbq`, you'll need to update your `build.zig` to do the following:

1. get a reference the `zig-bbq` dependency (installed via `zig fetch`),
2. get a reference to the `bbq` module within the dependency,
3. add the module as an import to your executable or library.

```zig
// (1) Get a reference to the `zig fetch`'ed dependency
const bbq_dep = b.dependency("bbq", .{
    .target = target,
    .optimize = optimize,
});

// (2) Get a reference to the language bindings module.
const bbq = bbq_dep.module("bbq");

// Set up your library or executable
const lib = // ...
const exe = // ...

// (3) Add the module as an import to your executable or library.
my_exe.root_module.addImport("bbq", bbq);
my_lib.root_module.addImport("bbq", bbq);
```

Now the code in your library or exectable can import and use the BBQ library.

```zig
const std = @import("std");
const bbq = @import("bbq");

pub fn main() !void {
    std.debug.print("{s}\n", .{@typeName(RetryNewQueue(u32))});
}

```

## Example Usage

`zig-bbq` is thread-safe and can be safely used by multiple producers and multiple consumers
concurrently. The entire API is only four functions: `.init()`, `.deinit()`, `.enqueue()` and `.dequeue()`.

```zig
const std = @import("std");
const bbq = @import("bbq");

pub fn main(init: std.process.Init) !void {
    const options = bbq.BlockOptions{
        .block_number = 4,
        .block_size = 2,
    };

    var q = try bbq.RetryNewQueue(u32).init(init.gpa, options);
    defer q.deinit();

    const expected: u32 = 42;
    try q.enqueue(expected);
    const actual = try q.dequeue();
    std.debug.assert(expected == actual);
}
```


## API Overview

| Symbol(s)                | Description                                                                  |
|--------------------------|------------------------------------------------------------------------------|
| `RetryNewQueue(T)`       | FIFO queue containing elements of type `T`, blocks producers when full       | 
| `DropOldQueue(T)`        | FIFO queue containing elements of type `T`, overwrites oldest data when full |
| `.init(allocator, opts)` | Initializes a new instance of the queue                                      |
| `.enqueue()`             | Used by producers to add data to the queue                                   |
| `.dequeue()`             | Used by consumers to remove the oldest item from the queue                   |
| `.deinit()`              | Free resources                                                               |
| `BlockOptions`           | Set block count and block size                                               |


## Credits

This implementation is based on the BBQ (Block-based Bounded Queue) algorithm described in the research paper:

> **"BBQ: A Block-based Bounded Queue for Exchanging Data and Profiling"**  
> Jiawei Wang, Diogo Behrens, Ming Fu, Lilith Oberhauser, Jonas Oberhauser, Jitang Lei, Geng Chen, Hermann Härtig, Haibo Chen  
> USENIX Annual Technical Conference (ATC) 2022  
> [USENIX ATC 2022](https://www.usenix.org/system/files/atc22-wang-jiawei.pdf)

**Important:** This `zig-bbq` implementation is an independent work by Theodore Sackos. The author has no affiliation with
the original research paper or its authors. All rights to the original research paper and algorithm design remain with the
original authors and USENIX.

This implementation is provided under the MIT license and covers only the source code contained in this repository.