import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // Deno code for Supabase Edge Functions (npm: specifiers, Deno globals) -
    // not part of the Next.js app, so neither its lint nor its type rules apply.
    "supabase/functions/**",
  ]),
]);

export default eslintConfig;
