/** Transactional email sender. Injected into the app so tests never send mail. */
export type EmailSender = {
  sendMagicLink(to: string, link: string): Promise<void>;
};
