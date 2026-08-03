import { findFunction, renderSignature } from '@/lib/sdk-api';

/**
 * Renders an SDK function's live signature + parameter table from
 * sdk-api.json, so hand-written guides never drift from @harmont/cloud.
 *
 *   <SdkSignature name="createBuild" />
 *
 * Throws at build time if the function is unknown.
 */
export function SdkSignature({ name }: { name: string }) {
  const fn = findFunction(name);
  if (!fn) {
    throw new Error(
      `<SdkSignature name="${name}"/>: not found in sdk-api.json. ` +
        `Run "make docs-generate" and check the spelling (the function's operationId).`,
    );
  }
  const params = [...fn.pathParams, ...fn.queryParams];
  return (
    <div className="not-prose my-4 rounded-lg border border-fd-border bg-fd-card p-4">
      <pre className="overflow-x-auto text-sm">
        <code>{renderSignature(fn)}</code>
      </pre>
      <p className="mt-2 text-sm text-fd-muted-foreground">
        <code>
          {fn.method} {fn.path}
        </code>
      </p>
      {params.length > 0 && (
        <table className="mt-3 w-full text-sm">
          <thead>
            <tr>
              <th scope="col" className="text-left">Parameter</th>
              <th scope="col" className="text-left">In</th>
              <th scope="col" className="text-left">Type</th>
              <th scope="col" className="text-left">Description</th>
            </tr>
          </thead>
          <tbody>
            {fn.pathParams.map((p) => (
              <tr key={`path-${p.name}`}>
                <td>
                  <code>{p.name}</code>
                </td>
                <td>path</td>
                <td>
                  <code>{p.type}</code>
                </td>
                <td>{p.doc || '—'}</td>
              </tr>
            ))}
            {fn.queryParams.map((p) => (
              <tr key={`query-${p.name}`}>
                <td>
                  <code>{p.name}</code>
                </td>
                <td>query</td>
                <td>
                  <code>{p.type}</code>
                </td>
                <td>{p.doc || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {fn.requestBody && (
        <p className="mt-3 text-sm">
          <strong>Body</strong> <code>{fn.requestBody.type}</code>
          {fn.requestBody.required ? ' (required)' : ' (optional)'}
        </p>
      )}
      <p className="mt-1 text-sm">
        <strong>Returns</strong> <code>{fn.responseType}</code>
      </p>
    </div>
  );
}
