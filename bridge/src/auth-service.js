import { AppServerClient } from "./app-server-client.js";

const MAX_ACCOUNTS = 3;
const LOGIN_LIFETIME_MS = 10 * 60_000;
const TERMINAL_SESSION_RETENTION_MS = 5 * 60_000;
const POLL_INTERVAL_SECONDS = 2;
const LOGIN_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
const USER_CODE_PATTERN = /^[A-Za-z0-9-]{4,64}$/;
const DEVICE_VERIFICATION_URL = "https://auth.openai.com/codex/device";

export class AuthServiceError extends Error {
  constructor(code, statusCode) {
    super(code);
    this.name = "AuthServiceError";
    this.code = code;
    this.statusCode = statusCode;
  }
}

function authError(code, statusCode) {
  return new AuthServiceError(code, statusCode);
}

function sanitizedPlanType(value) {
  if (typeof value !== "string") return null;
  const planType = value.trim();
  return /^[A-Za-z0-9_-]{1,32}$/.test(planType) ? planType : null;
}

function validateDeviceLoginResult(result) {
  if (
    !result ||
    typeof result !== "object" ||
    result.type !== "chatgptDeviceCode" ||
    typeof result.loginId !== "string" ||
    !LOGIN_ID_PATTERN.test(result.loginId) ||
    typeof result.userCode !== "string" ||
    !USER_CODE_PATTERN.test(result.userCode) ||
    result.verificationUrl !== DEVICE_VERIFICATION_URL
  ) {
    throw authError("auth_unavailable", 503);
  }

  return {
    loginId: result.loginId,
    userCode: result.userCode,
    verificationUrl: result.verificationUrl,
  };
}

/**
 * Owns the device-code lifecycle for all configured live profiles. Raw account
 * objects (including email addresses) and upstream errors stay inside this
 * class and are never part of a returned DTO.
 */
export class AccountAuthService {
  #config;
  #clientFactory;
  #profileCoordinator;
  #profilesById;
  #sessions = new Map();
  #activeLoginByAccountId = new Map();
  #now;
  #onProfileAuthChanged;
  #closed = false;
  #loginLifetimeMs;
  #terminalSessionRetentionMs;

  constructor(
    config,
    {
      clientFactory = (options) => new AppServerClient(options),
      profileCoordinator,
      now = () => Date.now(),
      onProfileAuthChanged = () => {},
      loginLifetimeMs = LOGIN_LIFETIME_MS,
      terminalSessionRetentionMs = TERMINAL_SESSION_RETENTION_MS,
    } = {},
  ) {
    if (!Number.isInteger(loginLifetimeMs) || loginLifetimeMs < 1) {
      throw new TypeError("loginLifetimeMs must be a positive integer");
    }
    if (!Number.isInteger(terminalSessionRetentionMs) || terminalSessionRetentionMs < 1) {
      throw new TypeError("terminalSessionRetentionMs must be a positive integer");
    }
    this.#config = config;
    this.#clientFactory = clientFactory;
    this.#profileCoordinator = profileCoordinator;
    this.#profilesById = new Map(config.profiles.map((profile) => [profile.id, profile]));
    this.#now = now;
    this.#onProfileAuthChanged = onProfileAuthChanged;
    this.#loginLifetimeMs = loginLifetimeMs;
    this.#terminalSessionRetentionMs = terminalSessionRetentionMs;
  }

  #currentTimeMs() {
    const value = this.#now();
    if (!Number.isFinite(value)) throw authError("auth_unavailable", 503);
    return value;
  }

  #requireLive() {
    if (this.#closed || this.#config.mode !== "live") {
      throw authError("auth_unavailable", 503);
    }
  }

  #requireProfile(accountId) {
    const profile = this.#profilesById.get(accountId);
    if (!profile) throw authError("account_not_found", 404);
    return profile;
  }

  #createClient(profile) {
    return this.#clientFactory({
      codexCommand: this.#config.codexCommand,
      codexHome: profile.codexHome,
      requestTimeoutMs: this.#config.requestTimeoutMs,
    });
  }

  #tryAcquire(profile) {
    if (!this.#profileCoordinator) return () => {};
    return this.#profileCoordinator.tryAcquire(profile.codexHome);
  }

  async #withShortClient(profile, operation) {
    const release = this.#tryAcquire(profile);
    if (!release) throw authError("auth_unavailable", 503);

    let client;
    try {
      client = this.#createClient(profile);
      await client.initialize();
      return await operation(client);
    } catch (error) {
      if (error instanceof AuthServiceError) throw error;
      throw authError("auth_unavailable", 503);
    } finally {
      client?.close();
      release();
    }
  }

  #pruneSessions() {
    const now = this.#currentTimeMs();
    for (const [loginId, session] of this.#sessions) {
      if (
        session.status !== "pending" &&
        now - session.terminalAtMs >= this.#terminalSessionRetentionMs
      ) {
        this.#sessions.delete(loginId);
      }
    }
  }

  #publicSession(session, { includeCeremony = false } = {}) {
    const result = {
      accountId: session.accountId,
      loginId: session.loginId,
      status: session.status,
      expiresAt: new Date(session.expiresAtMs).toISOString(),
      intervalSeconds: POLL_INTERVAL_SECONDS,
    };
    if (includeCeremony) {
      result.verificationUrl = session.verificationUrl;
      result.userCode = session.userCode;
    }
    return result;
  }

  #finishSession(session, status) {
    if (session.status !== "pending") return;
    session.status = status;
    session.terminalAtMs = this.#currentTimeMs();
    clearTimeout(session.expirationTimer);
    session.unsubscribeNotification?.();
    session.unsubscribeClose?.();
    session.client.close();
    session.release();
    if (this.#activeLoginByAccountId.get(session.accountId) === session.loginId) {
      this.#activeLoginByAccountId.delete(session.accountId);
    }
  }

  #reportAuthState(accountId, authenticated) {
    try {
      this.#onProfileAuthChanged(accountId, authenticated);
    } catch {
      // Cache invalidation must not turn a completed auth operation into an
      // upstream-looking failure or expose callback details over HTTP.
    }
  }

  async #completeSession(session, params) {
    if (
      session.status !== "pending" ||
      session.completionStarted ||
      !params ||
      typeof params !== "object" ||
      params.loginId !== session.loginId
    ) {
      return;
    }

    session.completionStarted = true;
    if (params.success !== true) {
      this.#finishSession(session, session.cancelRequested ? "cancelled" : "failed");
      return;
    }

    try {
      const result = await session.client.readAccount();
      const verified = result?.account?.type === "chatgpt";
      if (verified) this.#reportAuthState(session.accountId, true);
      this.#finishSession(session, verified ? "succeeded" : "failed");
    } catch {
      this.#finishSession(session, "failed");
    }
  }

  async listAccounts() {
    if (this.#config.mode !== "live" || this.#closed) {
      return {
        maxAccounts: MAX_ACCOUNTS,
        accounts: this.#config.profiles.map((profile) => ({
          id: profile.id,
          displayName: profile.displayName,
          status: "error",
          authMode: null,
          planType: null,
        })),
      };
    }

    this.#pruneSessions();
    const accounts = await Promise.all(
      this.#config.profiles.map(async (profile) => {
        const activeLoginId = this.#activeLoginByAccountId.get(profile.id);
        if (activeLoginId) {
          return {
            id: profile.id,
            displayName: profile.displayName,
            status: "pending",
            authMode: null,
            planType: null,
            loginId: activeLoginId,
          };
        }

        try {
          const result = await this.#withShortClient(profile, (client) => client.readAccount());
          if (result?.account?.type === "chatgpt") {
            this.#reportAuthState(profile.id, true);
            return {
              id: profile.id,
              displayName: profile.displayName,
              status: "signed_in",
              authMode: "chatgpt",
              planType: sanitizedPlanType(result.account.planType),
            };
          }
          if (result?.account == null) {
            this.#reportAuthState(profile.id, false);
            return {
              id: profile.id,
              displayName: profile.displayName,
              status: "signed_out",
              authMode: null,
              planType: null,
            };
          }
        } catch {
          // A per-profile read failure is represented only by the stable state.
        }
        return {
          id: profile.id,
          displayName: profile.displayName,
          status: "error",
          authMode: null,
          planType: null,
        };
      }),
    );

    return { maxAccounts: MAX_ACCOUNTS, accounts };
  }

  async startDeviceLogin(accountId) {
    this.#requireLive();
    this.#pruneSessions();
    const profile = this.#requireProfile(accountId);
    if (this.#activeLoginByAccountId.has(accountId)) {
      throw authError("login_in_progress", 409);
    }

    const release = this.#tryAcquire(profile);
    if (!release) throw authError("auth_unavailable", 503);

    let client;
    let unsubscribeNotification;
    let unsubscribeClose;
    const earlyCompletions = [];
    let liveSession = null;
    try {
      client = this.#createClient(profile);
      unsubscribeNotification = client.onNotification((method, params) => {
        if (method !== "account/login/completed") return;
        if (liveSession) {
          void this.#completeSession(liveSession, params);
        } else {
          earlyCompletions.push(params);
        }
      });
      if (typeof client.onClose === "function") {
        unsubscribeClose = client.onClose(() => {
          if (liveSession) this.#finishSession(liveSession, "failed");
        });
      }

      await client.initialize();
      const current = await client.readAccount();
      if (current?.account != null) throw authError("already_signed_in", 409);

      const ceremony = validateDeviceLoginResult(await client.startDeviceCodeLogin());
      const now = this.#currentTimeMs();
      const session = {
        accountId,
        loginId: ceremony.loginId,
        status: "pending",
        verificationUrl: ceremony.verificationUrl,
        userCode: ceremony.userCode,
        expiresAtMs: now + this.#loginLifetimeMs,
        terminalAtMs: null,
        completionStarted: false,
        cancelRequested: false,
        client,
        release,
        unsubscribeNotification,
        unsubscribeClose,
        expirationTimer: null,
      };
      liveSession = session;
      session.expirationTimer = setTimeout(() => {
        // Writing the documented cancel request is best-effort; closing the
        // child immediately afterwards is the final local cancellation bound.
        void session.client.cancelLogin(session.loginId).catch(() => {});
        this.#finishSession(session, "failed");
      }, this.#loginLifetimeMs);
      session.expirationTimer.unref?.();

      if (this.#sessions.has(session.loginId)) {
        throw authError("auth_unavailable", 503);
      }
      this.#sessions.set(session.loginId, session);
      this.#activeLoginByAccountId.set(accountId, session.loginId);

      for (const params of earlyCompletions) {
        if (params?.loginId === session.loginId) {
          void this.#completeSession(session, params);
          break;
        }
      }
      return this.#publicSession(session, { includeCeremony: true });
    } catch (error) {
      if (!liveSession || liveSession.status === "pending") {
        unsubscribeNotification?.();
        unsubscribeClose?.();
        client?.close();
        release();
      }
      if (error instanceof AuthServiceError) throw error;
      throw authError("auth_unavailable", 503);
    }
  }

  getDeviceLogin(loginId) {
    this.#requireLive();
    this.#pruneSessions();
    const session = this.#sessions.get(loginId);
    if (!session) throw authError("login_not_found", 404);
    return this.#publicSession(session);
  }

  async cancelDeviceLogin(loginId) {
    this.#requireLive();
    this.#pruneSessions();
    const session = this.#sessions.get(loginId);
    if (!session) throw authError("login_not_found", 404);
    if (session.status !== "pending") return this.#publicSession(session);

    session.cancelRequested = true;
    try {
      await session.client.cancelLogin(session.loginId);
    } catch {
      if (session.status !== "cancelled") throw authError("auth_unavailable", 503);
    }
    this.#finishSession(session, "cancelled");
    return this.#publicSession(session);
  }

  async logoutAccount(accountId) {
    this.#requireLive();
    const profile = this.#requireProfile(accountId);
    const activeLoginId = this.#activeLoginByAccountId.get(accountId);
    if (activeLoginId) await this.cancelDeviceLogin(activeLoginId);

    await this.#withShortClient(profile, (client) => client.logout());
    this.#reportAuthState(accountId, false);
    return { accountId, status: "signed_out" };
  }

  close() {
    if (this.#closed) return;
    for (const session of this.#sessions.values()) {
      if (session.status === "pending") this.#finishSession(session, "failed");
    }
    this.#closed = true;
  }
}
