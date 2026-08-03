// Pure, JSON-free logic for the SDK reference pipeline. No imports of
// sdk-api.json here, so this module is unit-testable on its own.

export interface SdkParam {
  name: string;
  type: string;
  required: boolean;
  doc: string;
}

export interface SdkRequestBody {
  type: string;
  required: boolean;
}

export interface SdkFunction {
  name: string; // operationId — equals the exported SDK function name
  tag: string;
  method: string; // GET | POST | PUT | PATCH | DELETE
  path: string;
  summary: string;
  description: string;
  dataType: string; // PascalCase(name) + "Data"
  responseType: string; // PascalCase(name) + "Response"
  pathParams: SdkParam[];
  queryParams: SdkParam[];
  requestBody: SdkRequestBody | null;
}

export interface SdkApi {
  version: string;
  package: string;
  functions: SdkFunction[];
}

// Minimal shape of the bits of OpenAPI we read.
interface OpenApiSchema {
  type?: string;
  $ref?: string;
  items?: OpenApiSchema;
}
interface OpenApiParam {
  name: string;
  in: string;
  required?: boolean;
  schema?: OpenApiSchema;
  description?: string;
}
interface OpenApiOperation {
  operationId?: string;
  tags?: string[];
  summary?: string;
  description?: string;
  parameters?: OpenApiParam[];
  requestBody?: { required?: boolean; content?: Record<string, { schema?: OpenApiSchema }> };
}
interface OpenApiSpec {
  info?: { version?: string };
  paths: Record<string, Record<string, OpenApiOperation>>;
}

const METHODS = ['get', 'post', 'put', 'patch', 'delete'] as const;

export function pascalCase(operationId: string): string {
  return operationId.charAt(0).toUpperCase() + operationId.slice(1);
}

// Last path segment of a `$ref`, e.g. "#/components/schemas/CreateBuildRequest"
// -> "CreateBuildRequest".
export function refName(schema: OpenApiSchema | undefined): string | null {
  if (!schema?.$ref) return null;
  const parts = schema.$ref.split('/');
  return parts[parts.length - 1] ?? null;
}

// A human-readable TypeScript-ish type for a parameter schema.
export function schemaType(schema: OpenApiSchema | undefined): string {
  if (!schema) return 'unknown';
  if (schema.$ref) return refName(schema) ?? 'unknown';
  if (schema.type === 'array') return `${schemaType(schema.items)}[]`;
  if (schema.type === 'integer' || schema.type === 'number') return 'number';
  if (schema.type === 'boolean') return 'boolean';
  return schema.type ?? 'string';
}

export function extractSdkApi(spec: OpenApiSpec): SdkApi {
  const functions: SdkFunction[] = [];
  for (const [path, item] of Object.entries(spec.paths)) {
    for (const method of METHODS) {
      const op = item[method];
      if (!op || !op.operationId) continue;
      const name = op.operationId;
      const params = op.parameters ?? [];
      const toParam = (p: OpenApiParam): SdkParam => ({
        name: p.name,
        type: schemaType(p.schema),
        required: Boolean(p.required),
        doc: p.description ?? '',
      });
      const bodySchema = op.requestBody?.content?.['application/json']?.schema;
      const requestBody: SdkRequestBody | null = bodySchema
        ? { type: refName(bodySchema) ?? schemaType(bodySchema), required: Boolean(op.requestBody?.required) }
        : null;
      functions.push({
        name,
        tag: op.tags?.[0] ?? 'default',
        method: method.toUpperCase(),
        path,
        summary: op.summary ?? '',
        description: op.description ?? op.summary ?? '',
        dataType: `${pascalCase(name)}Data`,
        responseType: `${pascalCase(name)}Response`,
        pathParams: params.filter((p) => p.in === 'path').map(toParam),
        queryParams: params.filter((p) => p.in === 'query').map(toParam),
        requestBody,
      });
    }
  }
  functions.sort((a, b) => a.name.localeCompare(b.name));
  return { version: spec.info?.version ?? '0', package: '@harmont/cloud', functions };
}

// A readable TS call signature for guides and reference headings.
export function renderSignature(fn: SdkFunction): string {
  return `${fn.name}(options): RequestResult<${fn.responseType}>`;
}
