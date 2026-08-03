import assert from 'node:assert/strict';
import { pascalCase, extractSdkApi, renderSignature, schemaType } from './sdk-api-core';

// pascalCase upper-cases only the first character (camelCase operationId).
assert.equal(pascalCase('createBuild'), 'CreateBuild');
assert.equal(pascalCase('listOrganizations'), 'ListOrganizations');

// extractSdkApi maps one operation to one typed SdkFunction.
const spec = {
  info: { version: '0' },
  paths: {
    '/api/v0/organizations/{org}/pipelines/{pipeline}/builds': {
      post: {
        operationId: 'createBuild',
        tags: ['builds'],
        summary: 'Create a build',
        description: 'Create a build for a pipeline.',
        parameters: [
          { name: 'org', in: 'path', required: true, schema: { type: 'string' }, description: 'The organization slug.' },
          { name: 'pipeline', in: 'path', required: true, schema: { type: 'string' }, description: 'The pipeline slug.' },
        ],
        requestBody: {
          required: true,
          content: { 'application/json': { schema: { $ref: '#/components/schemas/CreateBuildRequest' } } },
        },
        responses: { '201': {} },
      },
    },
    '/api/v0/organizations': {
      get: { operationId: 'listOrganizations', tags: ['organizations'], summary: 'List orgs', responses: { '200': {} } },
    },
  },
};

const api = extractSdkApi(spec);
assert.equal(api.package, '@harmont/cloud');
assert.equal(api.functions.length, 2);

// functions are sorted by name: createBuild before listOrganizations
const cb = api.functions[0];
assert.equal(cb.name, 'createBuild');
assert.equal(cb.tag, 'builds');
assert.equal(cb.method, 'POST');
assert.equal(cb.path, '/api/v0/organizations/{org}/pipelines/{pipeline}/builds');
assert.equal(cb.dataType, 'CreateBuildData');
assert.equal(cb.responseType, 'CreateBuildResponse');
assert.equal(cb.pathParams.length, 2);
assert.equal(cb.pathParams[0].name, 'org');
assert.equal(cb.pathParams[0].type, 'string');
assert.equal(cb.pathParams[0].required, true);
assert.equal(cb.queryParams.length, 0);
assert.ok(cb.requestBody);
assert.equal(cb.requestBody.type, 'CreateBuildRequest');
assert.equal(cb.requestBody.required, true);

const lo = api.functions[1];
assert.equal(lo.name, 'listOrganizations');
assert.equal(lo.requestBody, null);

// renderSignature produces a readable TS call line.
assert.equal(renderSignature(cb), 'createBuild(options): RequestResult<CreateBuildResponse>');

// schemaType maps the non-string parameter schemas the real spec uses.
assert.equal(schemaType({ type: 'string' }), 'string');
assert.equal(schemaType({ type: 'integer' }), 'number');
assert.equal(schemaType({ type: 'boolean' }), 'boolean');
assert.equal(schemaType({ type: 'array', items: { type: 'string' } }), 'string[]');

// query parameters are routed to queryParams (typed), not pathParams.
const spec2 = {
  paths: {
    '/api/v0/organizations/{org}/builds': {
      get: {
        operationId: 'listBuilds',
        tags: ['builds'],
        parameters: [
          { name: 'org', in: 'path', required: true, schema: { type: 'string' } },
          { name: 'limit', in: 'query', required: false, schema: { type: 'integer' } },
        ],
        responses: { '200': {} },
      },
    },
  },
};
const lb = extractSdkApi(spec2).functions[0];
assert.equal(lb.pathParams.length, 1);
assert.equal(lb.pathParams[0].name, 'org');
assert.equal(lb.queryParams.length, 1);
assert.equal(lb.queryParams[0].name, 'limit');
assert.equal(lb.queryParams[0].type, 'number');
assert.equal(lb.queryParams[0].required, false);

console.log('sdk-api-core: all assertions passed');
