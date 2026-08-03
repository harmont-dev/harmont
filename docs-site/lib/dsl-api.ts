import api from '../dsl-api.json';

export interface DslParam {
  name: string;
  kind: string;
  annotation: string | null;
  default: string | null;
  doc: string;
}

export interface DslReturns {
  annotation: string | null;
  doc: string;
}

export interface DslSignatureData {
  params: DslParam[];
  returns: DslReturns;
}

export interface DslMethod {
  name: string;
  summary: string;
  description: string;
  examples: string[];
  signature: DslSignatureData;
}

export interface DslField {
  name: string;
  annotation: string | null;
  default: string | null;
}

export interface DslSymbol {
  name: string;
  kind: 'function' | 'dataclass' | 'class' | 'singleton';
  group: string;
  page: string;
  summary: string;
  description: string;
  examples: string[];
  signature: DslSignatureData | null;
  fields: DslField[];
  methods: DslMethod[];
}

export interface DslApi {
  version: string;
  package: string;
  symbols: DslSymbol[];
}

export const dslApi = api as DslApi;
export const dslSymbols = dslApi.symbols;

/** Look up `"sh"` (a symbol) or `"rust.project"` (a method on a symbol). */
export function findSignature(
  ref: string,
): { name: string; doc: string; signature: DslSignatureData } | null {
  const [head, member] = ref.split('.', 2);
  const sym = dslSymbols.find((s) => s.name === head);
  if (!sym) return null;
  if (!member) {
    if (!sym.signature) return null;
    return { name: sym.name, doc: sym.summary, signature: sym.signature };
  }
  const m = sym.methods.find((x) => x.name === member);
  if (!m) return null;
  return { name: `${head}.${member}`, doc: m.summary, signature: m.signature };
}

/** Render a Python-style call signature, e.g. `sh(cmd, *, cwd=None) -> Step`. */
export function renderSignature(name: string, sig: DslSignatureData): string {
  const parts: string[] = [];
  let starEmitted = false;
  for (const p of sig.params) {
    if (p.kind === 'var_positional') {
      parts.push(`*${p.name}`);
      starEmitted = true;
      continue;
    }
    if (p.kind === 'var_keyword') {
      parts.push(`**${p.name}`);
      continue;
    }
    if (p.kind === 'keyword_only' && !starEmitted) {
      parts.push('*');
      starEmitted = true;
    }
    parts.push(p.default === null ? p.name : `${p.name}=${p.default}`);
  }
  const ret = sig.returns.annotation ? ` -> ${sig.returns.annotation}` : '';
  return `${name}(${parts.join(', ')})${ret}`;
}
