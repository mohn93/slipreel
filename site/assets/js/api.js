// Thin API client. `fetchImpl` is injectable so it is testable under node:test.
// Every call sends the session cookie (credentials:'include').
export function createApi(baseUrl, fetchImpl = fetch) {
  async function call(method, path, body) {
    let res;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    try {
      res = await fetchImpl(baseUrl + path, {
        method,
        signal: controller.signal,
        credentials: 'include',
        headers: body ? { 'Content-Type': 'application/json' } : {},
        body: body ? JSON.stringify(body) : undefined,
      });
      let data = null;
      try { data = await res.json(); } catch { data = null; }
      return { ok: res.ok, status: res.status, data };
    } catch {
      // Network error (API unreachable, DNS, CORS-blocked): surface as a failure
      // the caller can render, never an unhandled rejection. status 0 = no response.
      return { ok: false, status: 0, data: null };
    } finally { clearTimeout(timeout); }
  }
  return {
    checkoutContext: (id) => call('GET', '/v1/checkout-context/' + encodeURIComponent(id)),
    checkout: (b) => call('POST', '/v1/checkout', b),
    sessionFromCheckout: (id) => call('POST', '/v1/auth/session-from-checkout', { checkout_session_id: id }),
    token: (b) => call('POST', '/v1/token', b),
    magicLink: (b) => call('POST', '/v1/auth/magic-link', b),
    magicLinkVerify: (token) => call('POST', '/v1/auth/magic-link/verify', { token }),
    portal: (email) => call('POST', '/v1/portal', { email }),
    entitlement: () => call('GET', '/v1/entitlement'),
    devices: () => call('GET', '/v1/devices'),
    deleteDevice: (id) => call('DELETE', '/v1/devices/' + encodeURIComponent(id)),
    logout: () => call('POST', '/v1/auth/logout'),
  };
}
