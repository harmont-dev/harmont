import type { MetadataRoute } from 'next';

const BASE = 'https://docs.harmont.dev';

export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: '*', allow: '/' },
    sitemap: `${BASE}/sitemap.xml`,
  };
}
