import { source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';

// Server-side Orama instance, populated at module load. Cloud Run keeps the
// container warm between requests, so the index is built once per cold start.
export const { GET } = createFromSource(source, {
  // https://docs.orama.com/docs/orama-js/supported-languages
  language: 'english',
});
