import { describe, it, expect, vi } from 'vitest';
import { createResendSender } from '../src/email/resend.js';

const config = { apiKey: 'test_key', from: 'Slipreel <noreply@slipreel.app>' };

describe('createResendSender', () => {
  it('POSTs a well-formed request to Resend', async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ id: 'e1' }), { status: 200 }));
    const sender = createResendSender(config, fetchImpl as unknown as typeof fetch);
    await sender.sendMagicLink('u@example.com', 'https://slipreel.app/login?token=abc');

    expect(fetchImpl).toHaveBeenCalledTimes(1);
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.resend.com/emails');
    expect(init.method).toBe('POST');
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe('Bearer test_key');
    expect(headers['Content-Type']).toBe('application/json');
    const body = JSON.parse(init.body as string);
    expect(body.from).toBe(config.from);
    expect(body.to).toEqual(['u@example.com']);
    expect(typeof body.subject).toBe('string');
    expect(body.html).toContain('https://slipreel.app/login?token=abc');
  });

  it('throws when Resend returns a non-2xx', async () => {
    const fetchImpl = vi.fn(async () => new Response('nope', { status: 422 }));
    const sender = createResendSender(config, fetchImpl as unknown as typeof fetch);
    await expect(sender.sendMagicLink('u@example.com', 'https://x/y')).rejects.toThrow(/resend/i);
  });
});
