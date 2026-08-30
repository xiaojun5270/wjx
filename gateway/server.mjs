import crypto from "node:crypto";
import http from "node:http";
import { pathToFileURL } from "node:url";

const ACTION_SUBMIT_RESPONSE = "1001001";
const MAX_BODY_BYTES = 1024 * 1024;
const MAX_BATCH_SIZE = 50;

function requiredEnvironment(environment, name) {
  const value = String(environment[name] || "").trim();
  if (!value) throw new Error(`缺少环境变量 ${name}`);
  return value;
}

function jsonResponse(response, statusCode, body) {
  const data = Buffer.from(JSON.stringify(body));
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": data.length,
    "Cache-Control": "no-store"
  });
  response.end(data);
}

function isAuthorized(request, expectedToken) {
  const authorization = String(request.headers.authorization || "");
  const suppliedToken = authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length).trim()
    : "";
  const supplied = Buffer.from(suppliedToken);
  const expected = Buffer.from(expectedToken);
  return supplied.length === expected.length &&
    crypto.timingSafeEqual(supplied, expected);
}

async function readJSON(request) {
  const chunks = [];
  let received = 0;
  for await (const chunk of request) {
    received += chunk.length;
    if (received > MAX_BODY_BYTES) {
      const error = new Error("请求数据过大");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    const error = new Error("请求体必须是有效的 JSON");
    error.statusCode = 400;
    throw error;
  }
}

function validateBatch(body) {
  const vid = Number(body?.vid);
  const inputCostTime = Number(body?.inputCostTime);
  const submissions = body?.submissions;
  if (!Number.isSafeInteger(vid) || vid <= 0) {
    throw new Error("vid 必须是正整数");
  }
  if (!Number.isSafeInteger(inputCostTime) || inputCostTime < 2 || inputCostTime > 86400) {
    throw new Error("inputCostTime 必须在 2 到 86400 秒之间");
  }
  if (!Array.isArray(submissions) || submissions.length < 1 || submissions.length > MAX_BATCH_SIZE) {
    throw new Error(`submissions 数量必须在 1 到 ${MAX_BATCH_SIZE} 之间`);
  }
  const normalized = submissions.map((submission, index) => {
    const clientID = String(submission?.clientID || "").trim();
    const presetName = String(submission?.presetName || `预设 ${index + 1}`).trim();
    const submitdata = String(submission?.submitdata || "").trim();
    if (!clientID || !submitdata) {
      throw new Error(`第 ${index + 1} 组缺少 clientID 或 submitdata`);
    }
    return { clientID, presetName, submitdata };
  });
  return { vid, inputCostTime, submissions: normalized };
}

export function createSignature(parameters, appKey, algorithm = "sha1") {
  const source = Object.keys(parameters)
    .sort()
    .map(key => parameters[key])
    .filter(value => value !== undefined && value !== null && String(value) !== "")
    .map(String)
    .join("") + appKey;
  return crypto.createHash(algorithm).update(source, "utf8").digest("hex");
}

function answerIDFrom(data) {
  if (!data || typeof data !== "object") return null;
  const candidate = data.answerid ?? data.answerId ?? data.responseid ?? data.responseId ?? data.id;
  return candidate === undefined || candidate === null ? null : String(candidate);
}

async function submitOne({ appID, appKey, host, vid, inputCostTime, submission }) {
  const parameters = {
    action: ACTION_SUBMIT_RESPONSE,
    appid: appID,
    encode: "sha1",
    inputcosttime: inputCostTime,
    submitdata: submission.submitdata,
    ts: Math.floor(Date.now() / 1000),
    vid
  };
  parameters.sign = createSignature(parameters, appKey);

  const endpoint = new URL(`https://${host}/openapi/default.aspx`);
  endpoint.searchParams.set("action", ACTION_SUBMIT_RESPONSE);
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/json"
    },
    body: JSON.stringify(parameters),
    signal: AbortSignal.timeout(30000)
  });
  const responseText = await response.text();
  let payload;
  try {
    payload = JSON.parse(responseText);
  } catch {
    payload = null;
  }
  if (!response.ok) {
    return {
      clientID: submission.clientID,
      presetName: submission.presetName,
      success: false,
      answerID: null,
      message: `问卷星返回 HTTP ${response.status}`
    };
  }
  const success = payload?.result === true;
  return {
    clientID: submission.clientID,
    presetName: submission.presetName,
    success,
    answerID: success ? answerIDFrom(payload?.data) : null,
    message: success ? null : String(payload?.errormsg || "问卷星未返回错误说明")
  };
}

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
let requestChain = Promise.resolve();
let lastWJXRequestAt = 0;

function enqueueWJXRequest(task, minimumInterval) {
  const scheduled = requestChain.then(async () => {
    const wait = Math.max(lastWJXRequestAt + minimumInterval - Date.now(), 0);
    if (wait > 0) await sleep(wait);
    try {
      return await task();
    } finally {
      lastWJXRequestAt = Date.now();
    }
  });
  requestChain = scheduled.catch(() => undefined);
  return scheduled;
}

export function createGatewayServer(environment = process.env) {
  const appID = requiredEnvironment(environment, "WJX_APP_ID");
  const appKey = requiredEnvironment(environment, "WJX_APP_KEY");
  const gatewayToken = requiredEnvironment(environment, "GATEWAY_TOKEN");
  const host = String(environment.WJX_HOST || "www.wjx.cn").trim();
  if (!/^[A-Za-z0-9.-]+$/.test(host)) {
    throw new Error("WJX_HOST 格式无效");
  }
  const configuredInterval = Number(environment.WJX_MIN_INTERVAL_MS || 1000);
  const minimumInterval = Number.isFinite(configuredInterval)
    ? Math.max(configuredInterval, 0)
    : 1000;

  return http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url || "/", "http://gateway.local");
      if (request.method === "GET" && url.pathname === "/health") {
        jsonResponse(response, 200, { success: true, configured: true });
        return;
      }
      if (request.method !== "POST" || url.pathname !== "/api/wjx/submit-batch") {
        jsonResponse(response, 404, { success: false, message: "接口不存在" });
        return;
      }
      if (!isAuthorized(request, gatewayToken)) {
        jsonResponse(response, 401, { success: false, message: "网关访问令牌无效" });
        return;
      }

      const batch = validateBatch(await readJSON(request));
      const results = [];
      for (const submission of batch.submissions) {
        try {
          const result = await enqueueWJXRequest(
            () => submitOne({
              appID,
              appKey,
              host,
              vid: batch.vid,
              inputCostTime: batch.inputCostTime,
              submission
            }),
            minimumInterval
          );
          results.push(result);
        } catch (error) {
          results.push({
            clientID: submission.clientID,
            presetName: submission.presetName,
            success: false,
            answerID: null,
            message: `请求问卷星失败：${String(error?.message || "网络错误")}`
          });
        }
      }
      const failed = results.filter(result => !result.success).length;
      jsonResponse(response, 200, {
        success: failed === 0,
        results,
        message: failed === 0
          ? `成功提交 ${results.length} 组`
          : `成功 ${results.length - failed} 组，失败 ${failed} 组`
      });
    } catch (error) {
      jsonResponse(response, Number(error?.statusCode || 400), {
        success: false,
        message: String(error?.message || "网关处理失败")
      });
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT || 8787);
  const server = createGatewayServer(process.env);
  server.listen(port, "0.0.0.0", () => {
    console.log(`WJX API gateway listening on port ${port}`);
  });
}
