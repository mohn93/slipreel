import type { EmailConfig } from './config.js';
import type { EmailSender } from './sender.js';

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
          subject: 'Your Slipreel sign-in link',
          html: `<p>Click to sign in to Slipreel:</p><p><a href="${link}">${link}</a></p>`
            + `<p>This link expires in 30 minutes. If you didn't request it, ignore this email.</p>`,
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
