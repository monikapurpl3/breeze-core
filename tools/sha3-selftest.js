// Check static/js/sha3.js against the runtime's own native SHA3-512.
//
//   bun tools/sha3-selftest.js
//
// A hand-written Keccak that is wrong in some corner produces signatures the
// server rejects as `bad_signature`, with nothing anywhere to say the hash was
// the problem. So this compares against a known-good implementation over the
// published vectors, every length around the 72-byte rate boundary (where the
// padding and block logic actually live), and random inputs.

import { sha3_512_hex } from "../static/js/sha3.js";

const native = (bytes) => {
  const h = new Bun.CryptoHasher("sha3-512");
  h.update(bytes);
  return h.digest("hex");
};

let checks = 0;
let bad = 0;
const check = (label, bytes) => {
  checks++;
  const mine = sha3_512_hex(bytes);
  const theirs = native(bytes);
  if (mine !== theirs) {
    bad++;
    console.log(`  MISMATCH  ${label}`);
    console.log(`    mine   ${mine}`);
    console.log(`    native ${theirs}`);
  }
};

// The published vectors, spelled out so a failure here is unmistakable.
const VECTORS = {
  "": "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a6"
    + "15b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26",
  abc: "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e"
    + "10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0",
};
for (const [input, expected] of Object.entries(VECTORS)) {
  checks++;
  const mine = sha3_512_hex(new TextEncoder().encode(input));
  if (mine !== expected) {
    bad++;
    console.log(`  MISMATCH  published vector ${JSON.stringify(input)}`);
    console.log(`    mine     ${mine}`);
    console.log(`    expected ${expected}`);
  }
}

// Every length from 0 to 200: crosses the 72-byte rate twice, so it exercises
// the empty case, a partial block, an exactly-full block (where the padding
// needs a whole extra block) and multi-block absorption.
for (let n = 0; n <= 200; n++) {
  check(`${n} bytes of 'a'`, new TextEncoder().encode("a".repeat(n)));
}

// Byte values a text-only test would never produce.
for (let i = 0; i < 50; i++) {
  const len = Math.floor(Math.random() * 500);
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  check(`random ${len} bytes`, bytes);
}

// A realistic body: what the panel actually signs over.
check("json body", new TextEncoder().encode(
  JSON.stringify({ power_state: true, target_temperature: 22.5, beep: false }),
));

console.log(bad === 0
  ? `  sha3.js matches native SHA3-512 across ${checks} inputs`
  : `  ${bad} of ${checks} FAILED`);
process.exit(bad === 0 ? 0 : 1);
