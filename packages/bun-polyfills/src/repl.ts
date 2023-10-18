import bun from './index.js';
import * as jsc from './modules/jsc.js';
import * as ffi from './modules/ffi.js';

// This file serves two purposes:
// 1. It is the entry point for using the Bun global in the REPL. (--import this file)
// 2. It makes TypeScript check the full structural compatibility of the Bun global vs the polyfills object,
//    which allows for the type assertion below to be used as a TODO list index.

globalThis.Bun = bun as typeof bun & {
    // TODO: Missing polyfills
    readableStreamToFormData: typeof import('bun').readableStreamToFormData;
    build: typeof import('bun').build;
    connect: typeof import('bun').connect;
    listen: typeof import('bun').listen;
    CryptoHashInterface: typeof import('bun').CryptoHashInterface;
    CryptoHasher: typeof import('bun').CryptoHasher;
    FileSystemRouter: typeof import('bun').FileSystemRouter;

    //? Polyfilled but with broken types (See each one in ./src/modules/bun.ts for details)
    stdout: typeof import('bun').stdout;
    stderr: typeof import('bun').stderr;
    stdin: typeof import('bun').stdin;
};

Reflect.set(globalThis, 'jsc', jsc);
Reflect.set(globalThis, 'ffi', ffi);
