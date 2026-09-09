export function buildDeeplink({ token, refresh_token, device_id, state }) {
  const p = new URLSearchParams();
  p.set('token', token);
  if (refresh_token) p.set('refresh', refresh_token);
  if (device_id) p.set('device_id', device_id);
  if (state) p.set('state', state);
  return 'slipreel://auth?' + p.toString();
}

export async function startCheckout(api, { email, plan, device, deviceName, state }) {
  const body = { email, plan };
  if (device) body.device = device;
  if (deviceName) body.device_name = deviceName;
  if (state) body.state = state;
  const r = await api.checkout(body);
  if (!r.ok) return { error: r.data?.error || 'checkout_failed', status: r.status };
  return { redirect: r.data.url };
}

// After a session cookie is established, either mint a device token and deep-link
// the app (app-initiated flow, `device` present) or route to the account page.
async function afterSession(api, ctx) {
  if (ctx.device) {
    const t = await api.token({ fingerprint: ctx.device, device_name: ctx.device_name || null });
    const callbackError = (error) => ctx.state
      ? { errorDeeplink: 'slipreel://auth?' + new URLSearchParams({ error, state: ctx.state }) }
      : {};
    if (t.status === 409) return {
      seatLimit: t.data?.devices || [], ...callbackError('seat_limit'),
    };
    if (!t.ok) return {
      error: t.data?.error || 'token_failed', status: t.status,
      phase: 'activation', ...callbackError('activation_failed'),
    };
    return { deeplink: buildDeeplink({ ...t.data, state: ctx.state }) };
  }
  return { account: { email: ctx.email, userId: ctx.userId } };
}

export async function completeCheckout(api, sessionId, { attempts = 15, wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms)), onPending = () => {} } = {}) {
  let s;
  for (let attempt = 0; attempt < attempts; attempt++) {
    s = await api.sessionFromCheckout(sessionId);
    if (s.status !== 202) break;
    onPending(attempt);
    if (attempt + 1 < attempts) await wait(2000);
  }
  if (s.status === 202) return { pending: true, sessionId };
  if (!s.ok) return { error: s.data?.error || 'session_failed', status: s.status };
  return afterSession(api, {
    device: s.data.device, device_name: s.data.device_name, state: s.data.state,
    email: s.data.user?.email, userId: s.data.user?.id,
  });
}

export async function completeMagicLink(api, token) {
  const v = await api.magicLinkVerify(token);
  if (!v.ok) return { error: v.data?.error || 'verify_failed', status: v.status };
  if (v.data.checkout_flow) return { redirect: 'pricing.html?' + new URLSearchParams({ flow: v.data.checkout_flow }) };
  if (v.data.checkout_session_id) return { checkoutSessionId: v.data.checkout_session_id };
  if (v.data.checkout_plan) {
    const checkoutContext = { plan: v.data.checkout_plan, device: v.data.device, deviceName: v.data.device_name, state: v.data.state };
    const result = await startCheckout(api, checkoutContext);
    return result.error ? { ...result, phase: 'checkout', checkoutContext } : result;
  }
  return afterSession(api, {
    device: v.data.device, device_name: v.data.device_name, state: v.data.state,
    email: v.data.user?.email, userId: v.data.user?.id,
  });
}

export async function requestMagicLink(api, { email, device, deviceName, state, checkoutPlan, checkoutSessionId, checkoutFlow }) {
  const body = { email };
  if (device) body.device = device;
  if (deviceName) body.device_name = deviceName;
  if (state) body.state = state;
  if (checkoutPlan) body.checkout_plan = checkoutPlan;
  if (checkoutSessionId) body.checkout_session_id = checkoutSessionId;
  if (checkoutFlow) body.checkout_flow = checkoutFlow;
  const r = await api.magicLink(body);
  return { sent: r.ok };
}
