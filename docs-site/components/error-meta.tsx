import { errorByCode } from '@/lib/error-catalog';

/**
 * Renders the machine facts (HTTP status, type, code, default message) for a
 * coded error, sourced from error-catalog.json so they never drift from the
 * API. The surrounding prose ("why" / "how to fix") is hand-authored in the
 * page. Throws at build time if `code` is not in the catalog.
 */
export function ErrorMeta({ code }: { code: string }) {
  const spec = errorByCode.get(code);
  if (!spec) {
    throw new Error(
      `<ErrorMeta code="${code}"/>: code not found in error-catalog.json. ` +
        `Run "make error-catalog" and check the spelling.`,
    );
  }
  return (
    <table>
      <tbody>
        <tr>
          <td>HTTP status</td>
          <td>
            <code>{spec.http_status}</code>
          </td>
        </tr>
        <tr>
          <td>
            <code>type</code>
          </td>
          <td>
            <code>{spec.type}</code>
          </td>
        </tr>
        <tr>
          <td>
            <code>code</code>
          </td>
          <td>
            <code>{spec.code}</code>
          </td>
        </tr>
        <tr>
          <td>Default message</td>
          <td>{spec.message}</td>
        </tr>
      </tbody>
    </table>
  );
}
