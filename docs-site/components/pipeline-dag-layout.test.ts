import assert from 'node:assert/strict';
import { layoutPipeline, NODE_W, NODE_H, ROW_GAP } from './pipeline-dag-layout';

// sequence: codegen -> test  (two ranks, one row each)
{
  const { width, nodes, edges } = layoutPipeline(
    [
      { id: 'codegen', label: 'codegen' },
      { id: 'test', label: 'test' },
    ],
    [{ from: 'codegen', to: 'test' }],
  );
  const codegen = nodes.find((n) => n.id === 'codegen')!;
  const test = nodes.find((n) => n.id === 'test')!;
  assert.equal(codegen.x, 16, 'codegen sits in the first column (PAD=16)');
  assert.ok(test.x > codegen.x, 'test sits to the right of codegen');
  assert.equal(codegen.y, test.y, 'single-row ranks share a y');
  assert.equal(edges.length, 1);
  assert.ok(
    edges[0].d.startsWith(`M${codegen.x + NODE_W} `),
    'edge leaves codegen right edge',
  );
  assert.ok(width > NODE_W, 'width spans two columns');
}

// parallel: uv-sync -> {test, lint}  (rank 1 has two rows)
{
  const { nodes } = layoutPipeline(
    [
      { id: 'uv-sync', label: 'uv sync' },
      { id: 'test', label: 'test' },
      { id: 'lint', label: 'lint' },
    ],
    [
      { from: 'uv-sync', to: 'test' },
      { from: 'uv-sync', to: 'lint' },
    ],
  );
  const test = nodes.find((n) => n.id === 'test')!;
  const lint = nodes.find((n) => n.id === 'lint')!;
  assert.equal(test.x, lint.x, 'parallel leaves share a column');
  assert.notEqual(test.y, lint.y, 'parallel leaves are on different rows');
  assert.equal(
    test.y + NODE_H + ROW_GAP,
    lint.y,
    'leaves stack with exactly one ROW_GAP, in input order',
  );
}

// unknown edge endpoint throws
assert.throws(
  () => layoutPipeline([{ id: 'a', label: 'a' }], [{ from: 'a', to: 'ghost' }]),
  /unknown node/,
);

// cycle throws
assert.throws(
  () =>
    layoutPipeline(
      [
        { id: 'a', label: 'a' },
        { id: 'b', label: 'b' },
      ],
      [
        { from: 'a', to: 'b' },
        { from: 'b', to: 'a' },
      ],
    ),
  /cycle/,
);

// empty input yields a zero-size, empty layout (no NaN geometry)
{
  const empty = layoutPipeline([], []);
  assert.deepEqual(empty, { width: 0, height: 0, nodes: [], edges: [] });
}

console.log('pipeline-dag-layout: all assertions passed');
