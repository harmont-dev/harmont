import { source } from '@/lib/source';
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import { APIPage } from '@/components/api-page';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { MarkdownActions } from '@/components/markdown-actions';

export default async function Page(props: PageProps<'/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const isHome = !params.slug || params.slug.length === 0;

  return (
    <DocsPage toc={page.data.toc} full={page.data.full}>
      {!isHome && (
        <div className="flex items-center justify-between gap-4">
          <DocsTitle>{page.data.title}</DocsTitle>
          <MarkdownActions mdUrl={`${page.url}.md`} />
        </div>
      )}
      {!isHome && <DocsDescription>{page.data.description}</DocsDescription>}
      <DocsBody>
        <MDX
          components={getMDXComponents({
            APIPage,
            a: createRelativeLink(source, page),
          })}
        />
      </DocsBody>
    </DocsPage>
  );
}

export async function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata(
  props: PageProps<'/[[...slug]]'>,
): Promise<Metadata> {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  return {
    title: page.data.title,
    description: page.data.description,
    alternates: {
      types: { 'text/markdown': `${page.url}.md` },
    },
  };
}
