/**
 * Prevents multiple Codex app-server processes from touching the same
 * CODEX_HOME concurrently. Device-code logins hold a lease for their complete
 * lifecycle; short account/snapshot reads fail fast while that lease is held.
 */
export class ProfileAppServerCoordinator {
  #leases = new Set();

  tryAcquire(codexHome) {
    if (this.#leases.has(codexHome)) {
      return null;
    }

    this.#leases.add(codexHome);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.#leases.delete(codexHome);
    };
  }

  isBusy(codexHome) {
    return this.#leases.has(codexHome);
  }
}
