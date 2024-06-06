const std = @import("std");
const bun = @import("root").bun;
const Environment = bun.Environment;
const JSC = bun.JSC;
const string = bun.string;
const Output = bun.Output;
const ZigString = JSC.ZigString;
const Queue = std.fifo.LinearFifo(JSC.Node.BlobOrStringOrBuffer, .Dynamic);

const Z_NO_FLUSH = 0;
const Z_FINISH = 4;

pub const DeflateEncoder = struct {
    pub usingnamespace bun.New(@This());
    pub usingnamespace JSC.Codegen.JSDeflateEncoder;

    globalThis: *JSC.JSGlobalObject,
    stream: bun.zlib.ZlibCompressorStreaming = .{},

    freelist: Queue = Queue.init(bun.default_allocator),
    freelist_write_lock: bun.Lock = bun.Lock.init(),

    input: Queue = Queue.init(bun.default_allocator),
    input_lock: bun.Lock = bun.Lock.init(),

    has_called_end: bool = false,
    callback_value: JSC.Strong = .{},

    output: std.ArrayListUnmanaged(u8) = .{},
    output_lock: bun.Lock = bun.Lock.init(),

    has_pending_activity: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pending_encode_job_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ref_count: u32 = 1,
    write_failed: bool = false,
    poll_ref: bun.Async.KeepAlive = .{},

    pub fn constructor(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) ?*@This() {
        _ = callframe;
        globalThis.throw("DeflateEncoder is not constructable", .{});
        return null;
    }

    pub fn create(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
        const arguments = callframe.arguments(3).slice();

        if (arguments.len < 3) {
            globalThis.throwNotEnoughArguments("DeflateEncoder", 3, arguments.len);
            return .zero;
        }

        const opts = arguments[0];
        const callback = arguments[2];

        const level = globalThis.checkRangesOrGetDefault(opts, "level", u8, 0, 9, 6) orelse return .zero;
        const windowBits = globalThis.checkRangesOrGetDefault(opts, "windowBits", u8, 8, 15, 15) orelse return .zero;
        const memLevel = globalThis.checkRangesOrGetDefault(opts, "memLevel", u8, 1, 9, 8) orelse return .zero;
        const strategy = globalThis.checkRangesOrGetDefault(opts, "strategy", u8, 0, 4, 0) orelse return .zero;

        var this: *DeflateEncoder = DeflateEncoder.new(.{
            .globalThis = globalThis,
        });
        this.stream.init(level, windowBits, memLevel, strategy) catch {
            globalThis.throw("Failed to create DeflateEncoder", .{});
            return .zero;
        };

        const out = this.toJS(globalThis);
        DeflateEncoder.callbackSetCached(out, globalThis, callback);
        this.callback_value.set(globalThis, callback);

        return out;
    }

    pub fn finalize(this: *@This()) callconv(.C) void {
        this.deinit();
    }

    pub fn deinit(this: *@This()) void {
        this.input.deinit();
        this.callback_value.deinit();
        this.destroy();
    }

    pub fn encodeSync(this: *@This(), globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
        const arguments = callframe.arguments(3);

        if (arguments.len < 2) {
            globalThis.throwNotEnoughArguments("DeflateEncoder.encode", 2, arguments.len);
            return .zero;
        }

        if (this.has_called_end) {
            globalThis.throw("DeflateEncoder.encodeSync called after DeflateEncoder.end", .{});
            return .zero;
        }

        const input = callframe.argument(0);
        const optional_encoding = callframe.argument(1);
        const is_last = callframe.argument(2).toBoolean();

        const input_to_queue = JSC.Node.BlobOrStringOrBuffer.fromJSWithEncodingValueMaybeAsync(globalThis, bun.default_allocator, input, optional_encoding, true) orelse {
            globalThis.throwInvalidArgumentType("DeflateEncoder.encode", "input", "Blob, String, or Buffer");
            return .zero;
        };

        _ = this.has_pending_activity.fetchAdd(1, .Monotonic);
        if (is_last)
            this.has_called_end = true;

        var task: EncodeJob = .{
            .encoder = this,
            .is_async = false,
        };

        {
            this.input_lock.lock();
            defer this.input_lock.unlock();

            this.input.writeItem(input_to_queue) catch unreachable;
        }
        task.run();
        return if (!is_last and this.output.items.len == 0) .undefined else this.collectOutputValue();
    }

    pub fn encode(this: *@This(), globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
        const arguments = callframe.arguments(3);

        if (arguments.len < 2) {
            globalThis.throwNotEnoughArguments("DeflateEncoder.encode", 2, arguments.len);
            return .zero;
        }

        if (this.has_called_end) {
            globalThis.throw("DeflateEncoder.encode called after DeflateEncoder.end", .{});
            return .zero;
        }

        const input = callframe.argument(0);
        const optional_encoding = callframe.argument(1);
        const is_last = callframe.argument(2).toBoolean();

        const input_to_queue = JSC.Node.BlobOrStringOrBuffer.fromJSWithEncodingValueMaybeAsync(globalThis, bun.default_allocator, input, optional_encoding, true) orelse {
            globalThis.throwInvalidArgumentType("DeflateEncoder.encode", "input", "Blob, String, or Buffer");
            return .zero;
        };

        _ = this.has_pending_activity.fetchAdd(1, .Monotonic);
        if (is_last)
            this.has_called_end = true;

        var task = EncodeJob.new(.{
            .encoder = this,
            .is_async = true,
        });

        {
            this.input_lock.lock();
            defer this.input_lock.unlock();

            this.input.writeItem(input_to_queue) catch unreachable;
        }
        JSC.WorkPool.schedule(&task.task);

        return .undefined;
    }

    pub fn runFromJSThread(this: *@This()) void {
        this.poll_ref.unref(this.globalThis.bunVM());

        defer _ = this.has_pending_activity.fetchSub(1, .Monotonic);
        this.drainFreelist();

        const result = this.callback_value.get().?.call(this.globalThis, &.{
            if (this.write_failed)
                // TODO: propagate error from zlib
                this.globalThis.createErrorInstance("DeflateError", .{})
            else
                JSC.JSValue.null,
            this.collectOutputValue(),
        });

        if (result.toError()) |err| {
            _ = this.globalThis.bunVM().uncaughtException(this.globalThis, err, false);
        }
    }

    pub fn hasPendingActivity(this: *@This()) callconv(.C) bool {
        return this.has_pending_activity.load(.Monotonic) > 0;
    }

    fn drainFreelist(this: *DeflateEncoder) void {
        this.freelist_write_lock.lock();
        defer this.freelist_write_lock.unlock();
        const to_free = this.freelist.readableSlice(0);
        for (to_free) |*input| {
            input.deinit();
        }
        this.freelist.discard(to_free.len);
    }

    fn collectOutputValue(this: *DeflateEncoder) JSC.JSValue {
        this.output_lock.lock();
        defer this.output_lock.unlock();

        defer this.output.clearRetainingCapacity();
        return JSC.ArrayBuffer.createBuffer(this.globalThis, this.output.items);
    }

    const EncodeJob = struct {
        task: JSC.WorkPoolTask = .{ .callback = &runTask },
        encoder: *DeflateEncoder,
        is_async: bool,

        pub usingnamespace bun.New(@This());

        pub fn runTask(this: *JSC.WorkPoolTask) void {
            var job: *EncodeJob = @fieldParentPtr(EncodeJob, "task", this);
            job.run();
            job.destroy();
        }

        pub fn run(this: *EncodeJob) void {
            defer {
                _ = this.encoder.has_pending_activity.fetchSub(1, .Monotonic);
            }

            var any = false;

            if (this.encoder.pending_encode_job_count.fetchAdd(1, .Monotonic) >= 0) {
                const is_last = this.encoder.has_called_end;
                while (true) {
                    this.encoder.input_lock.lock();
                    defer this.encoder.input_lock.unlock();
                    const readable = this.encoder.input.readableSlice(0);
                    defer this.encoder.input.discard(readable.len);
                    const pending = readable;

                    const Writer = struct {
                        encoder: *DeflateEncoder,

                        pub const Error = error{OutOfMemory};
                        pub fn writeAll(writer: @This(), chunk: []const u8) Error!void {
                            writer.encoder.output_lock.lock();
                            defer writer.encoder.output_lock.unlock();

                            try writer.encoder.output.appendSlice(bun.default_allocator, chunk);
                        }
                    };

                    defer {
                        this.encoder.freelist_write_lock.lock();
                        this.encoder.freelist.write(pending) catch unreachable;
                        this.encoder.freelist_write_lock.unlock();
                    }
                    for (pending) |input| {
                        var writer = this.encoder.stream.writer(Writer{ .encoder = this.encoder });
                        writer.writeAll(input.slice()) catch {
                            _ = this.encoder.pending_encode_job_count.fetchSub(1, .Monotonic);
                            this.encoder.write_failed = true;
                            return;
                        };
                    }

                    any = any or pending.len > 0;

                    if (this.encoder.pending_encode_job_count.fetchSub(1, .Monotonic) == 0)
                        break;
                }

                if (is_last and any) {
                    const output = &this.encoder.output;
                    this.encoder.output_lock.lock();
                    defer this.encoder.output_lock.unlock();

                    this.encoder.stream.end(output) catch {
                        _ = this.encoder.pending_encode_job_count.fetchSub(1, .Monotonic);
                        this.encoder.write_failed = true;
                        return;
                    };
                }
            }

            if (this.is_async and any) {
                var vm = this.encoder.globalThis.bunVMConcurrently();
                _ = this.encoder.has_pending_activity.fetchAdd(1, .Monotonic);
                this.encoder.poll_ref.refConcurrently(vm);
                vm.enqueueTaskConcurrent(JSC.ConcurrentTask.create(JSC.Task.init(this.encoder)));
            }
        }
    };
};

pub const DeflateDecoder = struct {
    pub usingnamespace bun.New(@This());
    pub usingnamespace JSC.Codegen.JSDeflateDecoder;

    globalThis: *JSC.JSGlobalObject,
    stream: bun.zlib.ZlibDecompressorStreaming = .{},

    freelist: Queue = Queue.init(bun.default_allocator),
    freelist_write_lock: bun.Lock = bun.Lock.init(),

    input: Queue = Queue.init(bun.default_allocator),
    input_lock: bun.Lock = bun.Lock.init(),

    has_called_end: bool = false,
    callback_value: JSC.Strong = .{},

    output: std.ArrayListUnmanaged(u8) = .{},
    output_lock: bun.Lock = bun.Lock.init(),

    has_pending_activity: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pending_encode_job_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ref_count: u32 = 1,
    write_failed: bool = false,
    poll_ref: bun.Async.KeepAlive = .{},

    pub fn constructor(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) ?*@This() {
        _ = callframe;
        globalThis.throw("DeflateDecoder is not constructable", .{});

        return null;
    }

    pub fn create(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
        const arguments = callframe.arguments(3).slice();

        if (arguments.len < 3) {
            globalThis.throwNotEnoughArguments("DeflateDecoder", 3, arguments.len);
            return .zero;
        }

        // const opts = arguments[0];
        const callback = arguments[2];

        var this: *DeflateDecoder = DeflateDecoder.new(.{
            .globalThis = globalThis,
        });
        this.stream.init() catch {
            globalThis.throw("Failed to create DeflateDecoder", .{});
            return .zero;
        };

        const out = this.toJS(globalThis);
        DeflateDecoder.callbackSetCached(out, globalThis, callback);
        this.callback_value.set(globalThis, callback);

        return out;
    }

    pub fn finalize(this: *@This()) callconv(.C) void {
        this.deinit();
    }

    pub fn deinit(this: *@This()) void {
        this.input.deinit();
        this.callback_value.deinit();
        this.destroy();
    }

    pub fn decodeSync(this: *@This(), globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
        const arguments = callframe.arguments(3);

        if (arguments.len < 2) {
            globalThis.throwNotEnoughArguments("DeflateDecoder.encode", 2, arguments.len);
            return .zero;
        }

        if (this.has_called_end) {
            globalThis.throw("DeflateDecoder.encodeSync called after DeflateDecoder.end", .{});
            return .zero;
        }

        const input = callframe.argument(0);
        const optional_encoding = callframe.argument(1);
        const is_last = callframe.argument(2).toBoolean();

        const input_to_queue = JSC.Node.BlobOrStringOrBuffer.fromJSWithEncodingValueMaybeAsync(globalThis, bun.default_allocator, input, optional_encoding, true) orelse {
            globalThis.throwInvalidArgumentType("DeflateDecoder.encode", "input", "Blob, String, or Buffer");
            return .zero;
        };

        _ = this.has_pending_activity.fetchAdd(1, .Monotonic);
        if (is_last)
            this.has_called_end = true;

        var task: DecodeJob = .{
            .decoder = this,
            .is_async = false,
        };

        {
            this.input_lock.lock();
            defer this.input_lock.unlock();

            this.input.writeItem(input_to_queue) catch unreachable;
        }
        task.run();
        return if (!is_last and this.output.items.len == 0) .undefined else this.collectOutputValue();
    }

    pub fn decode(this: *@This(), globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
        const arguments = callframe.arguments(3);

        if (arguments.len < 2) {
            globalThis.throwNotEnoughArguments("DeflateDecoder.encode", 2, arguments.len);
            return .zero;
        }

        if (this.has_called_end) {
            globalThis.throw("DeflateDecoder.encode called after DeflateDecoder.end", .{});
            return .zero;
        }

        const input = callframe.argument(0);
        const optional_encoding = callframe.argument(1);
        const is_last = callframe.argument(2).toBoolean();

        const input_to_queue = JSC.Node.BlobOrStringOrBuffer.fromJSWithEncodingValueMaybeAsync(globalThis, bun.default_allocator, input, optional_encoding, true) orelse {
            globalThis.throwInvalidArgumentType("DeflateDecoder.encode", "input", "Blob, String, or Buffer");
            return .zero;
        };

        _ = this.has_pending_activity.fetchAdd(1, .Monotonic);
        if (is_last)
            this.has_called_end = true;

        var task = DecodeJob.new(.{
            .decoder = this,
            .is_async = true,
        });

        {
            this.input_lock.lock();
            defer this.input_lock.unlock();

            this.input.writeItem(input_to_queue) catch unreachable;
        }
        JSC.WorkPool.schedule(&task.task);

        return .undefined;
    }

    pub fn runFromJSThread(this: *@This()) void {
        this.poll_ref.unref(this.globalThis.bunVM());

        defer _ = this.has_pending_activity.fetchSub(1, .Monotonic);
        this.drainFreelist();

        const result = this.callback_value.get().?.call(this.globalThis, &.{
            if (this.write_failed)
                // TODO: propagate error from zlib
                this.globalThis.createErrorInstance("DeflateError", .{})
            else
                JSC.JSValue.null,
            this.collectOutputValue(),
        });

        if (result.toError()) |err| {
            _ = this.globalThis.bunVM().uncaughtException(this.globalThis, err, false);
        }
    }

    pub fn hasPendingActivity(this: *@This()) callconv(.C) bool {
        return this.has_pending_activity.load(.Monotonic) > 0;
    }

    fn drainFreelist(this: *DeflateDecoder) void {
        this.freelist_write_lock.lock();
        defer this.freelist_write_lock.unlock();
        const to_free = this.freelist.readableSlice(0);
        for (to_free) |*input| {
            input.deinit();
        }
        this.freelist.discard(to_free.len);
    }

    fn collectOutputValue(this: *DeflateDecoder) JSC.JSValue {
        this.output_lock.lock();
        defer this.output_lock.unlock();

        defer this.output.clearRetainingCapacity();
        return JSC.ArrayBuffer.createBuffer(this.globalThis, this.output.items);
    }

    const DecodeJob = struct {
        task: JSC.WorkPoolTask = .{ .callback = &runTask },
        decoder: *DeflateDecoder,
        is_async: bool,

        pub usingnamespace bun.New(@This());

        pub fn runTask(this: *JSC.WorkPoolTask) void {
            var job: *DecodeJob = @fieldParentPtr(DecodeJob, "task", this);
            job.run();
            job.destroy();
        }

        pub fn run(this: *DecodeJob) void {
            defer {
                _ = this.decoder.has_pending_activity.fetchSub(1, .Monotonic);
            }

            var any = false;

            if (this.decoder.pending_encode_job_count.fetchAdd(1, .Monotonic) >= 0) {
                const is_last = this.decoder.has_called_end;
                while (true) {
                    this.decoder.input_lock.lock();
                    defer this.decoder.input_lock.unlock();
                    const readable = this.decoder.input.readableSlice(0);
                    defer this.decoder.input.discard(readable.len);
                    const pending = readable;

                    const Writer = struct {
                        decoder: *DeflateDecoder,

                        pub const Error = error{OutOfMemory};
                        pub fn writeAll(writer: @This(), chunk: []const u8) Error!void {
                            writer.decoder.output_lock.lock();
                            defer writer.decoder.output_lock.unlock();

                            try writer.decoder.output.appendSlice(bun.default_allocator, chunk);
                        }
                    };

                    defer {
                        this.decoder.freelist_write_lock.lock();
                        this.decoder.freelist.write(pending) catch unreachable;
                        this.decoder.freelist_write_lock.unlock();
                    }
                    for (pending) |input| {
                        var writer = this.decoder.stream.writer(Writer{ .decoder = this.decoder });
                        writer.writeAll(input.slice()) catch {
                            _ = this.decoder.pending_encode_job_count.fetchSub(1, .Monotonic);
                            this.decoder.write_failed = true;
                            return;
                        };
                    }

                    any = any or pending.len > 0;

                    if (this.decoder.pending_encode_job_count.fetchSub(1, .Monotonic) == 0)
                        break;
                }

                if (is_last and any) {
                    const output = &this.decoder.output;
                    this.decoder.output_lock.lock();
                    defer this.decoder.output_lock.unlock();

                    this.decoder.stream.end(output) catch {
                        _ = this.decoder.pending_encode_job_count.fetchSub(1, .Monotonic);
                        this.decoder.write_failed = true;
                        return;
                    };
                }
            }

            if (this.is_async and any) {
                var vm = this.decoder.globalThis.bunVMConcurrently();
                _ = this.decoder.has_pending_activity.fetchAdd(1, .Monotonic);
                this.decoder.poll_ref.refConcurrently(vm);
                vm.enqueueTaskConcurrent(JSC.ConcurrentTask.create(JSC.Task.init(this.decoder)));
            }
        }
    };
};
