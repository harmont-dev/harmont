import type { MetadataRoute } from 'next';
import { source } from '@/lib/source';

const BASE = 'https://docs.harmont.dev';

export default function sitemap(): MetadataRoute.Sitemap {
  return source.getPages().map((page) => ({
    // page.url is "/" for the home page; avoid a trailing-slash URL there so
    // every sitemap entry matches its canonical no-trailing-slash form.
    url: page.url === '/' ? BASE : `${BASE}${page.url}`,
    changeFrequency: 'weekly',
    priority: page.url === '/' ? 1 : 0.7,
  }));
}
