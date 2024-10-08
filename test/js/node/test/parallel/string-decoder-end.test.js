//#FILE: test-string-decoder-end.js
//#SHA1: 9b9cd65cf41dc419c54b8c47317aef7fcb251c5c
//-----------------
// Copyright Joyent, Inc. and other Node contributors.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.

"use strict";
// Verify that the string decoder works getting 1 byte at a time,
// the whole buffer at once, and that both match the .toString(enc)
// result of the entire buffer.

const assert = require("assert");
const SD = require("string_decoder").StringDecoder;
const encodings = ["base64", "base64url", "hex", "utf8", "utf16le", "ucs2"];

const bufs = ["☃💩", "asdf"].map(b => Buffer.from(b));

// Also test just arbitrary bytes from 0-15.
for (let i = 1; i <= 16; i++) {
  const bytes = "."
    .repeat(i - 1)
    .split(".")
    .map((_, j) => j + 0x78);
  bufs.push(Buffer.from(bytes));
}

encodings.forEach(testEncoding);

function testEncoding(encoding) {
  bufs.forEach(buf => {
    testBuf(encoding, buf);
  });
}

function testBuf(encoding, buf) {
  test(`StringDecoder ${encoding} - ${buf.toString()}`, () => {
    // Write one byte at a time.
    let s = new SD(encoding);
    let res1 = "";
    for (let i = 0; i < buf.length; i++) {
      res1 += s.write(buf.slice(i, i + 1));
    }
    res1 += s.end();

    // Write the whole buffer at once.
    let res2 = "";
    s = new SD(encoding);
    res2 += s.write(buf);
    res2 += s.end();

    // .toString() on the buffer
    const res3 = buf.toString(encoding);

    // One byte at a time should match toString
    expect(res1).toBe(res3);
    // All bytes at once should match toString
    expect(res2).toBe(res3);
  });
}

function testEnd(encoding, incomplete, next, expected) {
  test(`StringDecoder ${encoding} end - ${incomplete.toString("hex")} + ${next.toString("hex")}`, () => {
    let res = "";
    const s = new SD(encoding);
    res += s.write(incomplete);
    res += s.end();
    res += s.write(next);
    res += s.end();

    expect(res).toBe(expected);
  });
}

testEnd("utf8", Buffer.of(0xe2), Buffer.of(0x61), "\uFFFDa");
testEnd("utf8", Buffer.of(0xe2), Buffer.of(0x82), "\uFFFD\uFFFD");
testEnd("utf8", Buffer.of(0xe2), Buffer.of(0xe2), "\uFFFD\uFFFD");
testEnd("utf8", Buffer.of(0xe2, 0x82), Buffer.of(0x61), "\uFFFDa");
testEnd("utf8", Buffer.of(0xe2, 0x82), Buffer.of(0xac), "\uFFFD\uFFFD");
testEnd("utf8", Buffer.of(0xe2, 0x82), Buffer.of(0xe2), "\uFFFD\uFFFD");
testEnd("utf8", Buffer.of(0xe2, 0x82, 0xac), Buffer.of(0x61), "€a");

testEnd("utf16le", Buffer.of(0x3d), Buffer.of(0x61, 0x00), "a");
testEnd("utf16le", Buffer.of(0x3d), Buffer.of(0xd8, 0x4d, 0xdc), "\u4DD8");
testEnd("utf16le", Buffer.of(0x3d, 0xd8), Buffer.of(), "\uD83D");
testEnd("utf16le", Buffer.of(0x3d, 0xd8), Buffer.of(0x61, 0x00), "\uD83Da");
testEnd("utf16le", Buffer.of(0x3d, 0xd8), Buffer.of(0x4d, 0xdc), "\uD83D\uDC4D");
testEnd("utf16le", Buffer.of(0x3d, 0xd8, 0x4d), Buffer.of(), "\uD83D");
testEnd("utf16le", Buffer.of(0x3d, 0xd8, 0x4d), Buffer.of(0x61, 0x00), "\uD83Da");
testEnd("utf16le", Buffer.of(0x3d, 0xd8, 0x4d), Buffer.of(0xdc), "\uD83D");
testEnd("utf16le", Buffer.of(0x3d, 0xd8, 0x4d, 0xdc), Buffer.of(0x61, 0x00), "👍a");

testEnd("base64", Buffer.of(0x61), Buffer.of(), "YQ==");
testEnd("base64", Buffer.of(0x61), Buffer.of(0x61), "YQ==YQ==");
testEnd("base64", Buffer.of(0x61, 0x61), Buffer.of(), "YWE=");
testEnd("base64", Buffer.of(0x61, 0x61), Buffer.of(0x61), "YWE=YQ==");
testEnd("base64", Buffer.of(0x61, 0x61, 0x61), Buffer.of(), "YWFh");
testEnd("base64", Buffer.of(0x61, 0x61, 0x61), Buffer.of(0x61), "YWFhYQ==");

testEnd("base64url", Buffer.of(0x61), Buffer.of(), "YQ");
testEnd("base64url", Buffer.of(0x61), Buffer.of(0x61), "YQYQ");
testEnd("base64url", Buffer.of(0x61, 0x61), Buffer.of(), "YWE");
testEnd("base64url", Buffer.of(0x61, 0x61), Buffer.of(0x61), "YWEYQ");
testEnd("base64url", Buffer.of(0x61, 0x61, 0x61), Buffer.of(), "YWFh");
testEnd("base64url", Buffer.of(0x61, 0x61, 0x61), Buffer.of(0x61), "YWFhYQ");

//<#END_FILE: test-string-decoder-end.js
