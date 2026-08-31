import { spawn as nodeSpawn } from "node:child_process";
import readline from "node:readline";

const CLIENT_INFO = Object.freeze({
  name: "watch_overlay_bridge",
  title: "CodexMeter Bridge",
  version: "0.1.0",
});

export class AppServerProtocolError extends Error {
  constructor(message) {
    super(message);
    this.name = "AppServerProtocolError";
  }
}

export class AppServerClient {
  #child;
  #lineReader;
  #nextId = 1;
  #pending = new Map();
  #requestTimeoutMs;
  #closed = false;
  #notificationHandlers = new Set();
  #closeHandlers = new Set();
  #transportFailureSignaled = false;

  constructor({
    codexCommand = "codex",
    codexHome,
    requestTimeoutMs = 10_000,
    spawnProcess = nodeSpawn,
  }) {
    if (typeof codexHome !== "string" || codexHome.length === 0) {
      throw new Error("codexHome is required");
    }

    this.#requestTimeoutMs = requestTimeoutMs;
    const childEnvironment = { ...process.env, CODEX_HOME: codexHome };
    // The HTTP credential belongs only to this bridge and is never inherited by
    // the Codex child process.
    delete childEnvironment.WATCH_OVERLAY_BRIDGE_TOKEN;
    // Profile auth must come from this CODEX_HOME, not from an unrelated shell
    // credential that could collapse all configured slots onto one identity.
    delete childEnvironment.OPENAI_API_KEY;
    delete childEnvironment.CODEX_ACCESS_TOKEN;
    this.#child = spawnProcess(
      codexCommand,
      ["app-server", "-c", 'cli_auth_credentials_store="file"'],
      {
        env: childEnvironment,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );

    // App-server diagnostics can contain local details. The bridge deliberately
    // discards stderr instead of forwarding it into HTTP responses or logs.
    this.#child.stderr?.resume();

    this.#lineReader = readline.createInterface({ input: this.#child.stdout });
    this.#lineReader.on("line", (line) => this.#handleLine(line));
    this.#child.once("error", () => {
      const error = new AppServerProtocolError("Unable to start Codex app-server");
      this.#failPending(error);
      this.#signalTransportFailure(error);
    });
    this.#child.once("close", () => {
      if (!this.#closed) {
        const error = new AppServerProtocolError("Codex app-server closed unexpectedly");
        this.#failPending(error);
        this.#signalTransportFailure(error);
      }
    });
  }

  #signalTransportFailure(error) {
    if (this.#transportFailureSignaled) return;
    this.#transportFailureSignaled = true;
    for (const handler of this.#closeHandlers) {
      try {
        handler(error);
      } catch {
        // Close observers are isolated just like notification observers.
      }
    }
  }

  #send(message) {
    if (this.#closed || !this.#child.stdin?.writable) {
      throw new AppServerProtocolError("Codex app-server connection is closed");
    }
    this.#child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      const error = new AppServerProtocolError("Codex app-server sent malformed JSON");
      this.#failPending(error);
      this.#signalTransportFailure(error);
      return;
    }

    if (!Object.hasOwn(message, "id")) {
      if (typeof message.method === "string") {
        for (const handler of this.#notificationHandlers) {
          try {
            handler(message.method, message.params);
          } catch {
            // Notification consumers are isolated from the protocol reader.
            // In particular, an HTTP/UI handler must never be able to break
            // another in-flight app-server request.
          }
        }
      }
      return;
    }

    const pending = this.#pending.get(message.id);
    if (!pending) {
      return;
    }

    this.#pending.delete(message.id);
    clearTimeout(pending.timer);

    if (message.error) {
      pending.reject(new AppServerProtocolError("Codex app-server rejected the request"));
      return;
    }
    pending.resolve(message.result);
  }

  #failPending(error) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }

  request(method, params) {
    const id = this.#nextId++;
    const message = { method, id };
    if (params !== undefined) {
      message.params = params;
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new AppServerProtocolError("Codex app-server request timed out"));
      }, this.#requestTimeoutMs);

      this.#pending.set(id, { resolve, reject, timer });
      try {
        this.#send(message);
      } catch (error) {
        clearTimeout(timer);
        this.#pending.delete(id);
        reject(error);
      }
    });
  }

  notify(method, params = {}) {
    this.#send({ method, params });
  }

  onNotification(handler) {
    if (typeof handler !== "function") {
      throw new TypeError("notification handler must be a function");
    }
    this.#notificationHandlers.add(handler);
    return () => this.#notificationHandlers.delete(handler);
  }

  onClose(handler) {
    if (typeof handler !== "function") {
      throw new TypeError("close handler must be a function");
    }
    this.#closeHandlers.add(handler);
    return () => this.#closeHandlers.delete(handler);
  }

  async initialize() {
    await this.request("initialize", { clientInfo: CLIENT_INFO });
    this.notify("initialized");
  }

  async readRateLimits() {
    return this.request("account/rateLimits/read");
  }

  async readAccount() {
    return this.request("account/read", { refreshToken: false });
  }

  async startDeviceCodeLogin() {
    return this.request("account/login/start", { type: "chatgptDeviceCode" });
  }

  async cancelLogin(loginId) {
    return this.request("account/login/cancel", { loginId });
  }

  async logout() {
    return this.request("account/logout");
  }

  close() {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    this.#notificationHandlers.clear();
    this.#closeHandlers.clear();
    this.#failPending(new AppServerProtocolError("Codex app-server connection closed"));
    this.#lineReader.close();
    this.#child.stdin?.end();
    if (this.#child.exitCode === null) {
      this.#child.kill("SIGTERM");
    }
  }
}

export async function fetchProfileRateLimits(profile, options = {}) {
  const client = new AppServerClient({
    codexCommand: options.codexCommand,
    codexHome: profile.codexHome,
    requestTimeoutMs: options.requestTimeoutMs,
    spawnProcess: options.spawnProcess,
  });

  try {
    await client.initialize();
    return await client.readRateLimits();
  } finally {
    client.close();
  }
}
