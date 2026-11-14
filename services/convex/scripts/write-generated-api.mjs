// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes convex/_generated/api.d.ts the way `npx convex codegen` does, for machines without a Convex deployment
// (codegen needs one). It lists every function module under convex/ (skipping _generated, schema.ts,
// auth.config.ts, convex.config.ts and files with more than one dot, which Convex does not treat as modules) and
// declares the installed components. `npx convex dev` rewrites the same file; the two must agree.
//
// Usage, from services/convex:  node scripts/write-generated-api.mjs [--check]

import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const root = "convex";
const SKIP = new Set(["schema.ts", "auth.config.ts", "convex.config.ts"]);

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name === "_generated") continue;
      out.push(...walk(path));
    } else if (name.endsWith(".ts") && !SKIP.has(relative(root, path)) && name.split(".").length === 2) {
      out.push(relative(root, path).split(sep).join("/").replace(/\.ts$/, ""));
    }
  }
  return out;
}

const modules = walk(root).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
const alias = (m) => m.replace(/\//g, "_");
const key = (m) => (m.includes("/") ? `"${m}"` : m);

const components = {
  agent: "@convex-dev/agent",
  rag: "@convex-dev/rag",
  rateLimiter: "@convex-dev/rate-limiter",
};

const out = `// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/* eslint-disable */
/**
 * Generated \`api\` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run \`npx convex dev\` or \`npx convex codegen\`.
 * @module
 */

${modules.map((m) => `import type * as ${alias(m)} from "../${m}.js";`).join("\n")}

import type { ApiFromModules, FilterApi, FunctionReference } from "convex/server";

declare const fullApi: ApiFromModules<{
${modules.map((m) => `  ${key(m)}: typeof ${alias(m)};`).join("\n")}
}>;

export declare const api: FilterApi<typeof fullApi, FunctionReference<any, "public">>;
export declare const internal: FilterApi<typeof fullApi, FunctionReference<any, "internal">>;

export declare const components: {
${Object.entries(components)
  .map(([name, pkg]) => `  ${name}: import("${pkg}/_generated/component.js").ComponentApi<"${name}">;`)
  .join("\n")}
};
`;

const target = join(root, "_generated", "api.d.ts");
if (process.argv.includes("--check")) {
  if (readFileSync(target, "utf8") !== out) {
    process.stderr.write(`${target} is stale. Run \`node scripts/write-generated-api.mjs\`.\n`);
    process.exitCode = 1;
  }
} else {
  writeFileSync(target, out);
}
