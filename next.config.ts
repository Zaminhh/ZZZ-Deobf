import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  outputFileTracingIncludes: {
    "/api/deobf": ["./runtimes/**/*"],
  },
};

export default nextConfig;
