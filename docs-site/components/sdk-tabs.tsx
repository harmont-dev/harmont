import { Tabs, Tab } from 'fumadocs-ui/components/tabs';
import type { ReactNode } from 'react';

/**
 * Persistent, site-wide Python/TypeScript switch. Every SdkTabs shares the
 * same `groupId`, so picking a language once syncs every code sample across
 * the docs (and survives reloads via localStorage). Python is the default.
 */
export function SdkTabs({ children }: { children: ReactNode }) {
  return (
    <Tabs groupId="harmont-sdk" persist items={['Python', 'TypeScript']}>
      {children}
    </Tabs>
  );
}

export { Tab };
