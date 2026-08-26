import { randomUUID } from 'node:crypto';

/** Prefixed identifier, e.g. newId('usr') -> 'usr_3f2a...'. */
export function newId(prefix: string): string {
  return `${prefix}_${randomUUID().replace(/-/g, '')}`;
}
