const { spawn } = require("child_process");

if (!process.env.BUN_GARBAGE_COLLECTOR_LEVEL || !process.env.BUN_FEATURE_FLAG_FORCE_WAITER_THREAD) {
  throw new Error("This test must be run with BUN_GARBAGE_COLLECTOR_LEVEL and BUN_FEATURE_FLAG_FORCE_WAITER_THREAD");
}

spawn("sleep", ["infinity"]).ref();
