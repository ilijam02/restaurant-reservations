import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Dev server only (ignored by `next build`/production). Lets the app be
  // opened as owner.localhost / customer.localhost / employee.localhost, which
  // browsers resolve to this machine but give separate cookie jars - so one
  // browser can stay signed in as all three roles at once (one per hostname),
  // instead of every tab sharing a single session on plain `localhost`.
  allowedDevOrigins: ["*.localhost"],
};

export default nextConfig;
