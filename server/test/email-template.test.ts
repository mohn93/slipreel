import { describe, expect, it } from 'vitest';
import { renderMagicLinkEmail } from '../src/email/template.js';

describe('transactional email template', () => {
  it('escapes the HTML URL while preserving the plain text link', () => {
    const link = 'https://slipreel.app/login?token=abc&state="<tag>';
    const email = renderMagicLinkEmail(link);
    expect(email.html).toContain('href="https://slipreel.app/login?token=abc&amp;state=&quot;&lt;tag&gt;"');
    expect(email.html).not.toContain('<tag>');
    expect(email.text).toContain(link);
    expect(email.text).toContain('30 minutes');
  });
  it('rejects unsafe action protocols', () => {
    expect(() => renderMagicLinkEmail('javascript:alert(1)')).toThrow(/HTTPS/);
  });
});
