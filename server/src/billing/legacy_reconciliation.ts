/** Safety checks shared by the dry-run CLI and regression tests. */
export function validateLegacyCoverage(existing: {payment_intent_id:string;legacy_until?: Date|string|null}[], paymentIds: string[]): boolean {
  let hasPlaceholder = false;
  for (const row of existing) {
    if (row.legacy_until && row.payment_intent_id.startsWith('legacy_')) {hasPlaceholder = true;continue;}
    if (!paymentIds.includes(row.payment_intent_id)) throw new Error(`Stripe history does not cover existing payment ${row.payment_intent_id}; include verified historical prices`);
  }
  return hasPlaceholder;
}

export function validateReplacementCeilings(before: Date|string|null, after: Date|string|null, expectedBefore?: string, expectedAfter?: string): void {
  const time = (value: Date|string|null|undefined) => value === 'none' || value == null ? null : new Date(value).getTime();
  if (expectedBefore === undefined || expectedAfter === undefined ||
      time(before) !== time(expectedBefore) || time(after) !== time(expectedAfter)) {
    throw new Error('Synthetic legacy replacement requires --expected-current-until and --expected-reconciled-until matching the reviewed dry-run ceilings (use none for null)');
  }
}
