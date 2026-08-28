import { z } from 'zod';

const schema = z.object({
  RESEND_API_KEY: z.string().min(1, 'RESEND_API_KEY is required'),
  RESEND_FROM: z.string().min(1).default('Slipreel <noreply@slipreel.app>'),
});

export type EmailConfig = { apiKey: string; from: string };

export function loadEmailConfig(env: NodeJS.ProcessEnv = process.env): EmailConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid email configuration: ${issues}`);
  }
  return { apiKey: parsed.data.RESEND_API_KEY, from: parsed.data.RESEND_FROM };
}
