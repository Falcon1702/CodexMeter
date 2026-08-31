import { timingSafeEqual } from "node:crypto";
import http from "node:http";

import { AuthServiceError } from "./auth-service.js";

const MAX_JSON_BODY_BYTES = 4_096;

class HttpRequestError extends Error {
  constructor(code, statusCode) {
    super(code);
    this.code = code;
    this.statusCode = statusCode;
  }
}

function sendJson(response, statusCode, payload) {
  const body = `${JSON.stringify(payload)}\n`;
  response.writeHead(statusCode, {
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body),
    "content-type": "application/json; charset=utf-8",
    "x-content-type-options": "nosniff",
  });
  response.end(body);
}

function tokenMatches(header, expectedToken) {
  if (!expectedToken) {
    return true;
  }
  if (typeof header !== "string" || !header.startsWith("Bearer ")) {
    return false;
  }

  const receivedToken = header.slice("Bearer ".length);
  const expected = Buffer.from(expectedToken, "utf8");
  const received = Buffer.from(receivedToken, "utf8");
  return expected.length === received.length && timingSafeEqual(expected, received);
}

async function readJsonBody(request) {
  const contentType = request.headers["content-type"];
  if (
    typeof contentType !== "string" ||
    contentType.split(";", 1)[0].trim().toLowerCase() !== "application/json"
  ) {
    throw new HttpRequestError("unsupported_media_type", 415);
  }

  const declaredLength = Number(request.headers["content-length"]);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_JSON_BODY_BYTES) {
    throw new HttpRequestError("body_too_large", 413);
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > MAX_JSON_BODY_BYTES) throw new HttpRequestError("body_too_large", 413);
    chunks.push(buffer);
  }

  let parsed;
  try {
    parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpRequestError("bad_request", 400);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpRequestError("bad_request", 400);
  }
  return parsed;
}

function decodeSegment(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new HttpRequestError("bad_request", 400);
  }
}

function sendAuthError(response, error) {
  if (error instanceof HttpRequestError || error instanceof AuthServiceError) {
    sendJson(response, error.statusCode, { error: error.code });
    return;
  }
  sendJson(response, 503, { error: "auth_unavailable" });
}

export function createRequestHandler({ service, authService, bearerToken }) {
  let normalizedBearerToken;
  if (bearerToken !== undefined) {
    if (typeof bearerToken !== "string" || bearerToken.trim().length === 0) {
      throw new TypeError("bearerToken must not be empty or whitespace-only");
    }
    normalizedBearerToken = bearerToken.trim();
    if (normalizedBearerToken.length < 16) {
      throw new TypeError("bearerToken must contain at least 16 characters");
    }
  }

  return async (request, response) => {
    let url;
    try {
      url = new URL(request.url ?? "/", "http://bridge.local");
    } catch {
      sendJson(response, 400, { error: "bad_request" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/healthz") {
      sendJson(response, 200, { status: "ok" });
      return;
    }

    const isSnapshot = request.method === "GET" && url.pathname === "/v1/snapshot";
    const isAccountList = request.method === "GET" && url.pathname === "/v1/accounts";
    const isDeviceLoginStart =
      request.method === "POST" && url.pathname === "/v1/auth/device/start";
    const deviceLoginMatch = /^\/v1\/auth\/device\/([^/]+)$/.exec(url.pathname);
    const isDeviceLoginRead = request.method === "GET" && deviceLoginMatch;
    const isDeviceLoginCancel = request.method === "DELETE" && deviceLoginMatch;
    const accountMatch = /^\/v1\/accounts\/([^/]+)$/.exec(url.pathname);
    const isAccountLogout = request.method === "DELETE" && accountMatch;

    if (
      !isSnapshot &&
      !isAccountList &&
      !isDeviceLoginStart &&
      !isDeviceLoginRead &&
      !isDeviceLoginCancel &&
      !isAccountLogout
    ) {
      sendJson(response, 404, { error: "not_found" });
      return;
    }

    if (!isSnapshot && !normalizedBearerToken) {
      sendJson(response, 503, { error: "auth_unavailable" });
      return;
    }

    if (!tokenMatches(request.headers.authorization, normalizedBearerToken)) {
      response.setHeader("www-authenticate", "Bearer");
      sendJson(response, 401, { error: "unauthorized" });
      return;
    }

    if (isSnapshot) {
      try {
        sendJson(response, 200, await service.getSnapshot());
      } catch {
        sendJson(response, 503, { error: "snapshot_unavailable" });
      }
      return;
    }

    if (!authService) {
      sendJson(response, 503, { error: "auth_unavailable" });
      return;
    }

    try {
      if (isAccountList) {
        sendJson(response, 200, await authService.listAccounts());
        return;
      }
      if (isDeviceLoginStart) {
        const body = await readJsonBody(request);
        if (
          typeof body.accountId !== "string" ||
          Object.keys(body).some((key) => key !== "accountId")
        ) {
          throw new HttpRequestError("bad_request", 400);
        }
        sendJson(response, 201, await authService.startDeviceLogin(body.accountId));
        return;
      }
      if (isDeviceLoginRead) {
        sendJson(response, 200, authService.getDeviceLogin(decodeSegment(deviceLoginMatch[1])));
        return;
      }
      if (isDeviceLoginCancel) {
        sendJson(
          response,
          200,
          await authService.cancelDeviceLogin(decodeSegment(deviceLoginMatch[1])),
        );
        return;
      }
      sendJson(
        response,
        200,
        await authService.logoutAccount(decodeSegment(accountMatch[1])),
      );
    } catch (error) {
      sendAuthError(response, error);
    }
  };
}

export async function startHttpServer({ service, authService, host, port, bearerToken }) {
  const server = http.createServer(createRequestHandler({ service, authService, bearerToken }));
  server.once("close", () => authService?.close());

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      server.off("error", reject);
      resolve();
    });
  });

  return server;
}
