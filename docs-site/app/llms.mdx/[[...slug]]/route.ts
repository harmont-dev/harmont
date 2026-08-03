import { source } from '@/lib/source';
import { getLLMText } from '@/lib/get-llm-text';
import { notFound } from 'next/navigation';

export const revalidate = false;

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ slug?: string[] }> },
): Promise<Response> {
  const { slug } = await params;
  // The home page lives at slug [] (url "/"); /index.md maps here as ["index"].
  const normalized = slug?.length === 1 && slug[0] === 'index' ? [] : slug;
  const page = source.getPage(normalized);
  if (!page) notFound();

  return new Response(await getLLMText(page), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
}

export function generateStaticParams() {
  return source.generateParams();
}
