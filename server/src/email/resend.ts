import type { EmailConfig } from './config.js';
import type { EmailSender } from './sender.js';
import { renderMagicLinkEmail } from './template.js';

/** Resend-backed sender. `fetchImpl` is injectable so tests never hit the network. */
export function createResendSender(
  config: EmailConfig,
  fetchImpl: typeof fetch = fetch,
): EmailSender {
  return {
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
