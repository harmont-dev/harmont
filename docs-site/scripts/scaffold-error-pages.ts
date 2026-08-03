import { errorCatalog } from '../lib/error-catalog';
import { existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = 'content/docs/api/errors';
let created = 0;

for (const spec of errorCatalog) {
  const file = join(dir, `${spec.code}.mdx`);
  if (existsSync(file)) continue;
  const body = `---
title: ${spec.code}
description: ${spec.message}
---

<ErrorMeta code="${spec.code}" />

## When this happens

TODO: describe the trigger for ${spec.code}.

## How to fix it

TODO: state the fix.
`;
  writeFileSync(file, body, 'utf8');
  created += 1;
  console.log(`scaffolded ${file}`);
}

console.log(created === 0 ? 'All error pages already exist.' : `Scaffolded ${created} page(s). Fill in the TODOs.`);
