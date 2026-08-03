import { test } from "node:test";
import assert from "node:assert/strict";
import { isTerminal, defaultIr } from "./lib.ts";

test("isTerminal: only passed/failed/canceled are terminal", () => {
  assert.equal(isTerminal("passed"), true);
  assert.equal(isTerminal("failed"), true);
  assert.equal(isTerminal("canceled"), true);
  assert.equal(isTerminal("scheduled"), false);
  assert.equal(isTerminal("running"), false);
  assert.equal(isTerminal("failing"), false); // transient roll-up, not terminal
  assert.equal(isTerminal("canceling"), false);
});

test("defaultIr: source-independent command is valid v0 IR", () => {
  const ir = JSON.parse(defaultIr(false));
  assert.equal(ir.version, "0");
  assert.equal(ir.steps.length, 1);
  assert.equal(ir.steps[0].type, "command");
  assert.equal(ir.steps[0].key, "e2e");
  assert.match(ir.steps[0].cmd, /echo/);
});

test("defaultIr: expectSource uses a file-dependent command", () => {
  const ir = JSON.parse(defaultIr(true));
  assert.match(ir.steps[0].cmd, /harmont-e2e-marker\.txt/);
});
