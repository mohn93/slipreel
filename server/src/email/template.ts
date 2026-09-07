/** Shared light email layout. Inline styles and tables support email clients. */
export interface EmailContent {
  subject: string;
  preview: string;
  heading: string;
  message: string;
  actionLabel: string;
  actionUrl: string;
  note: string;
  footer: string;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]!);
}

export function renderEmail(content: EmailContent): { subject: string; html: string; text: string } {
  const url = new URL(content.actionUrl);
  if (url.protocol !== 'https:') throw new Error('Email action requires an HTTPS URL');
  const e = escapeHtml;
  return {
    subject: content.subject,
    text: `${content.heading}\n\n${content.message}\n\n${content.actionLabel}: ${content.actionUrl}\n\n${content.note}\n\n${content.footer}\n\nSlipreel\nhttps://slipreel.app`,
    html: `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light"><title>${e(content.subject)}</title>
<style>:root{color-scheme:light only}body{margin:0!important}a{color:#4A3FC7}@media(max-width:600px){.outer{padding:24px 12px!important}.content{padding:30px 24px!important}.heading{font-size:28px!important}}</style></head>
<body style="margin:0;padding:0;background-color:#F5F5FA;color:#222233;font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;">
<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">${e(content.preview)}</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#F5F5FA"><tr><td class="outer" align="center" style="padding:48px 20px;">
<!--[if mso]><table role="presentation" width="560"><tr><td><![endif]-->
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:560px;">
<tr><td style="padding:0 0 24px 4px;"><a href="https://slipreel.app" style="text-decoration:none;color:#222233;"><img src="https://slipreel.app/apple-touch-icon.png" width="36" height="36" alt="" style="vertical-align:middle;border:0;border-radius:9px;"><span style="vertical-align:middle;font-size:22px;font-weight:700;letter-spacing:-0.6px;">&nbsp; Slipreel</span></a></td></tr>
<tr><td class="content" bgcolor="#FFFFFF" style="padding:40px;border:1px solid #E5E3EF;border-radius:22px;background-color:#FFFFFF;">
<h1 class="heading" style="margin:0 0 16px;font-size:32px;line-height:1.2;letter-spacing:-0.9px;font-weight:700;color:#222233;">${e(content.heading)}</h1>
<p style="margin:0 0 28px;font-size:16px;line-height:1.65;color:#626276;">${e(content.message)}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr><td bgcolor="#6C5CE7" style="border-radius:14px;background-color:#6C5CE7;text-align:center;mso-padding-alt:16px 28px;"><a href="${e(content.actionUrl)}" style="display:inline-block;padding:16px 28px;border:1px solid #6C5CE7;border-radius:14px;font-size:16px;line-height:20px;font-weight:600;color:#FFFFFF;text-decoration:none;">${e(content.actionLabel)}</a></td></tr></table>
<p style="margin:20px 0 0;font-size:14px;line-height:1.6;color:#626276;">${e(content.note)}</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr><td style="padding-top:28px;border-bottom:1px solid #E5E3EF;"></td></tr></table>
<p style="margin:24px 0 8px;font-size:13px;line-height:1.6;color:#626276;">Button not working? Copy and paste this link into your browser:</p>
<p style="margin:0;font-size:12px;line-height:1.7;word-break:break-all;overflow-wrap:anywhere;"><a href="${e(content.actionUrl)}" style="color:#4A3FC7;text-decoration:underline;word-break:break-all;">${e(content.actionUrl)}</a></p>
</td></tr>
<tr><td style="padding:24px 12px 0;font-size:12px;line-height:1.7;color:#626276;">${e(content.footer)}<br><a href="https://slipreel.app" style="display:inline-block;margin-top:12px;color:#626276;text-decoration:none;">Slipreel · Beautiful screen recordings</a></td></tr>
</table><!--[if mso]></td></tr></table><![endif]-->
</td></tr></table></body></html>`,
  };
}

export function renderMagicLinkEmail(link: string) {
  return renderEmail({
    subject: 'Your Slipreel sign-in link',
    preview: 'Sign in to Slipreel. Your secure link expires in 30 minutes.',
    heading: 'Your next take starts here.',
    message: 'Sign in to your Slipreel account to manage your license and connected devices.',
    actionLabel: 'Sign in to Slipreel',
    actionUrl: link,
    note: 'This link expires in 30 minutes and can only be used once.',
    footer: 'If you didn’t request this email, you can safely ignore it.',
  });
}
