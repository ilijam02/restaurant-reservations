// Stands in for the "server-only" import in unit tests. Next replaces that
// import itself at build time (and fails the build if a Client Component
// reaches it); Vitest has no such thing, so it resolves here to nothing.
export {};
