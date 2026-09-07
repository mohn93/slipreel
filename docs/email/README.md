# Slipreel transactional email style

Sign-in emails use `server/src/email/template.ts`, deployed September 6, 2026.
This is currently the only application-owned email type; new transactional
emails should use `renderEmail()` and supply their own subject, preview,
heading, message, action, note, and footer. Send both returned `html` and `text`.

## Visual direction

Adapt the site's existing purple identity to a light email layout:

- Purple `#6C5CE7` for the main action; deeper `#4A3FC7` for text links.
- White `#FFFFFF` content, pale `#F5F5FA` canvas, ink `#222233`, secondary text `#626276`.
- Existing Slipreel app icon, system sans-serif with Inter when available.
- Left-aligned content, 560px maximum width, 22px content corners and 14px button corners.
- One clear action, expiry information, visible fallback URL, and quiet security footer.

The layout uses presentation tables, inline styles, explicit background colors,
mobile padding, and light color-scheme metadata. Email clients can override
colors; browser previews do not establish Gmail/Outlook rendering fidelity.
Do not place authentication tokens in preview files or screenshots. The included
`sign-in-preview.html` contains a dummy link only. Do not use the supplied
screenshot's real sign-in URL.

## Verification and deployment

Server build and four focused sender/template tests passed. Tests mock Resend;
no email was sent. Production renderer and API health were checked after deploy.
Browser visual review was unavailable: the localhost preview timed out, and file
navigation was blocked by browser policy. Inbox rendering remains unverified.

Only `src/email/resend.ts` and `src/email/template.ts` were deployed, followed by
a server build and API restart. Previous sender source/build are backed up at
`/root/slipreel-backups/email-style-20260906/` on 185.203.116.117.

Stripe receipts are managed separately. Its account reports “Becoming Ventures,
LLC” and no existing branding. Account-wide branding is pending confirmation
that the account is dedicated to Slipreel; do not change other products' receipts.
