import type { EmailConfig } from './config.js';
import type { EmailSender } from './sender.js';
import { renderMagicLinkEmail } from './template.js';

/** Resend-backed sender. `fetchImpl` is injectable so tests never hit the network. */
export function createResendSender(
  config: EmailConfig,
  fetchImpl: typeof fetch = fetch,
): EmailSender {
  return {
    async sendSignInCode(to, code) {
      if (!/^\d{8}$/.test(code)) throw new Error('Invalid sign-in code');
      const response = await fetchImpl('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({from: config.from, to: [to], subject: 'Your Slipreel sign-in code',
          text: `Your Slipreel sign-in code is ${code}. Enter it in Slipreel within 10 minutes. If you did not request this, ignore this email.`,
          html: `<div style="background:#f7f5fb;padding:32px;font-family:Arial,sans-serif;color:#262032"><div style="max-width:480px;margin:auto;background:white;border-radius:16px;padding:32px"><h1 style="font-size:24px">Sign in to Slipreel</h1><p>Enter this code in the app:</p><p style="font-size:32px;letter-spacing:6px;font-weight:bold;color:#7250d5">${code}</p><p>This code expires in 10 minutes. If you did not request it, ignore this email.</p></div></div>`}),
      });
      if (!response.ok) throw new Error('Email delivery unavailable');
      return await response.json() as {id?: string};
    },
    async sendMagicLink(to, link) {
      const res = await fetchImpl('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: config.from,
          to: [to],
          ...renderMagicLinkEmail(link),
        }),
      });
      if (!res.ok) {
        throw new Error(`resend send failed: ${res.status}`);
      }
      const data = (await res.json().catch(() => ({}))) as { id?: string };
      return { id: data.id };
    },
  };
}
