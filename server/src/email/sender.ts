/** Transactional email sender. Injected into the app so tests never send mail. */
export type EmailSender = {
  // Returns the provider message id when available (for delivery tracing);
  // `void` keeps simple test stubs valid.
  sendMagicLink(to: string, link: string): Promise<{ id?: string } | void>;
};
