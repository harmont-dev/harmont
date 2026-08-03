import { defineConfig } from "tsup";

// Bundle the public entrypoint into dist/ as both ESM (.js) and CJS (.cjs)
// with type declarations. Runtime deps (declared in package.json
// "dependencies") are externalized automatically, so @hey-api/client-fetch
// is NOT inlined.
export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  // No sourcemaps: src/ isn't shipped and the bundle is generated code, so
  // maps would just bloat the published tarball (~⅓) with no real debug value.
  sourcemap: false,
  treeshake: true,
  outDir: "dist",
  target: "node18",
});
