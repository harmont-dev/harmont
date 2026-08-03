// Single source for the Harmont brand-mark SVG (viewBox 0 0 330.92 448).
// Shared by the docs hero and the sidebar footer so the path lives in one
// place. `size` is the mark height in px; width is derived to keep ratio.
const GLYPH_PATH =
  'M269.79,262.18c-60.18-62.42-88.14-90.55-45.27-225.8l10.9-31.49c1.2-3.13.64-4.89-3.77-4.89h-72.12c-4.17,0-5.21.72-6.97,5.21L.32,443.27c-.88,2.48,0,4.33,3.29,4.33h74.44c1.98.25,3.8-1.09,4.17-3.04l70.83-202.33c9.1,13.36,19.87,25.5,32.05,36.14,52.32,46.8,72.12,70.11,62.58,161.62-.64,6.33,0,8.01,6.65,8.01h71.55c2.56,0,3.53-1.52,3.77-4.09,6.49-86.14-11.78-131.97-59.86-181.73Z';

export function BrandGlyph({
  size = 14,
  className,
}: {
  size?: number;
  className?: string;
}) {
  const width = Math.round((size * 330.92) / 448);
  return (
    <svg
      width={width}
      height={size}
      viewBox="0 0 330.92 448"
      aria-hidden
      focusable="false"
      className={className}
      style={{ display: 'block', flexShrink: 0 }}
    >
      <path fill="currentColor" d={GLYPH_PATH} />
    </svg>
  );
}
