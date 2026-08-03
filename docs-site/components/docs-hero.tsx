import Link from 'next/link';
import { BrandGlyph } from '@/components/brand-glyph';

export function DocsHero() {
  return (
    <section className="docs-hero">
      <BrandGlyph size={56} className="docs-hero-glyph" />
      <h1 className="docs-hero-title">
        CI that runs your <span className="docs-hero-accent">local code</span>.
      </h1>
      <p className="docs-hero-lede">
        Define a pipeline in <code>.hm/</code>, and <code>hm run</code> executes
        it in a sandbox against whatever is in your working tree right now,
        before you've committed or pushed anything. Logs stream to your terminal
        as it runs.
      </p>
      <div className="docs-hero-cta">
        <Link className="docs-btn docs-btn-primary" href="/getting-started#install-hm">
          Install hm
        </Link>
        <a
          className="docs-btn"
          href="https://github.com/harmont-dev"
          target="_blank"
          rel="noopener noreferrer"
        >
          GitHub
        </a>
      </div>
    </section>
  );
}
