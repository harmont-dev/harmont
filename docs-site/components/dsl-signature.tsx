import { findSignature, renderSignature } from '@/lib/dsl-api';

/**
 * Renders a DSL symbol or method's live signature + parameter table from
 * dsl-api.json, so hand-written guides never drift from the harmont package.
 *
 *   <DslSignature name="sh" />
 *   <DslSignature name="rust.project" />
 *
 * Throws at build time if the ref is unknown.
 */
export function DslSignature({ name }: { name: string }) {
  const found = findSignature(name);
  if (!found) {
    throw new Error(
      `<DslSignature name="${name}"/>: not found in dsl-api.json. ` +
        `Run "make docs-generate" and check the spelling ("symbol" or "symbol.method").`,
    );
  }
  const { signature } = found;
  return (
    <div className="not-prose my-4 rounded-lg border border-fd-border bg-fd-card p-4">
      <pre className="overflow-x-auto text-sm">
        <code>{renderSignature(found.name, signature)}</code>
      </pre>
      {signature.params.length > 0 && (
        <table className="mt-3 w-full text-sm">
          <thead>
            <tr>
              <th scope="col" className="text-left">Parameter</th>
              <th scope="col" className="text-left">Type</th>
              <th scope="col" className="text-left">Default</th>
              <th scope="col" className="text-left">Description</th>
            </tr>
          </thead>
          <tbody>
            {signature.params.map((p) => (
              <tr key={p.name}>
                <td>
                  <code>{p.name}</code>
                </td>
                <td>{p.annotation ? <code>{p.annotation}</code> : '—'}</td>
                <td>{p.default === null ? <em>required</em> : <code>{p.default}</code>}</td>
                <td>{p.doc || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
