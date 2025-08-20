<div align="center">

# zig-bbq

**High-performance, lock-free ring buffer for Zig, based on the BBQ algorithm described in [BBQ: A Block-based Bounded Queue for Exchanging Data and Profiling](https://www.usenix.org/conference/atc22/presentation/wang-jiawei).**

![GitHub License](https://img.shields.io/github/license/sackosoft/zig-bbq)
![Zig Version](https://img.shields.io/badge/Zig-0.14.1-blue)

<!--
TODO: Add a visualization, diagram, or demo of BBQ in action.
-->

</div>

## About

`zig-bbq` is a pure Zig implementation of the [B]lock-based [B]ounded [Q]ueue (BBQ) algorithm; a lock-free ring buffer, designed
for high-performance data transfer between threads. BBQ is suitable for both lossless (retry-new) and lossy (drop-old)
producer-consumer scenarios, making it ideal for message passing, work distribution, profiling, tracing, and debugging.

## Features

- **Lock-free**, **high-performance** ring buffer for concurrent producer-consumer scenarios.
- **Configurable** capacity for performance tuning. The BBQ paper describes options to optimize for latency or throughput.
- Two modes of operation:
    - `RetryNewQueue`: lossless, blocks producers when full.
    - `DropOldQueue`: lossy, overwrites oldest unconsumed data when full.

## Zig Version

The `main` branch targets the latest stable Zig release (currently `0.14.1`).

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

pub fn main() !void {
    const options = bbq.BlockOptions{
        .block_number = 4,
        .block_size = 2,
    };

    var q = try bbq.RetryNewQueue(u32).init(std.heap.page_allocator, options);
    defer q.deinit();

    const expected: u32 = 42;
    try q.enqueue(expected);
    const actual = try q.dequeue();
    std.debug.assert(expected == actual);
}
```

## API

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

This implementation is based on the BBQ algorithm described in the USENIX ATC 2022 paper by
Jiawei Wang et al.

> **BBQ: A Block-based Bounded Queue for Exchanging Data and Profiling**  
> Jiawei Wang, Diogo Behrens, Ming Fu, Lilith Oberhauser, Jonas Oberhauser, Jitang Lei, Geng Chen, Hermann Härtig, Haibo Chen  
> [USENIX ATC 2022](https://www.usenix.org/conference/atc22/presentation/wang-jiawei)

The author of `zig-bbq` has no affiliation with the paper or its authors.