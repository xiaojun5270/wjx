import assert from "node:assert/strict";
import test from "node:test";
import { createGatewayServer, createSignature } from "./server.mjs";

test("signature order is stable", () => {
  assert.equal(
    createSignature({ b: "2", a: "1" }, "key"),
    createSignature({ a: "1", b: "2" }, "key")
  );
});

test("batch gateway signs and normalizes two successful submissions", async () => {
  const originalFetch = globalThis.fetch;
  const captured = [];
  globalThis.fetch = async (url, options) => {
    if (!String(url).startsWith("https://www.wjx.cn/")) {
      return originalFetch(url, options);
    }
    const body = JSON.parse(options.body);
    captured.push(body);
    const { sign, ...unsigned } = body;
    assert.equal(sign, createSignature(unsigned, "test-key"));
    return new Response(
      JSON.stringify({ result: true, data: { answerid: captured.length } }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  };

  const server = createGatewayServer({
    WJX_APP_ID: "test-app",
    WJX_APP_KEY: "test-key",
    GATEWAY_TOKEN: "test-token",
    WJX_HOST: "www.wjx.cn",
    WJX_MIN_INTERVAL_MS: "0"
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));

  try {
    const address = server.address();
    const response = await originalFetch(
      `http://127.0.0.1:${address.port}/api/wjx/submit-batch`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer test-token"
        },
        body: JSON.stringify({
          vid: 123,
          inputCostTime: 2,
          submissions: [
            { clientID: "a", presetName: "预设 1", submitdata: "1$甲}2$001" },
            { clientID: "b", presetName: "预设 2", submitdata: "1$乙}2$002" }
          ]
        })
      }
    );
    const result = await response.json();
    assert.equal(response.status, 200);
    assert.equal(result.success, true);
    assert.equal(result.results.length, 2);
    assert.equal(captured.length, 2);
  } finally {
    globalThis.fetch = originalFetch;
    await new Promise(resolve => server.close(resolve));
  }
});
