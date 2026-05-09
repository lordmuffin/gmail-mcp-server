// ---------------------------------------------------------------------------
// Logger
//
// Tiny stderr-only logger. MCP servers that speak stdio use stdout for the
// JSON-RPC wire protocol — every line on stdout MUST be a valid JSON-RPC
// message. Anything else (banners, status, debug, request logs) corrupts the
// transport and causes the client to time out on initialize.
//
// Rule of thumb: if you'd reach for console.log, call logger.info instead.
// Reserve raw process.stdout writes for actual protocol output (which the MCP
// SDK transport handles for us — application code should not write stdout).
// ---------------------------------------------------------------------------

function format(level: string, args: unknown[]): string {
  const parts = args.map((a) => {
    if (a instanceof Error) {
      return a.stack ?? `${a.name}: ${a.message}`;
    }
    if (typeof a === "string") return a;
    try {
      return JSON.stringify(a);
    } catch {
      return String(a);
    }
  });
  return `[${level}] ${parts.join(" ")}\n`;
}

function write(level: string, args: unknown[]): void {
  process.stderr.write(format(level, args));
}

export const logger = {
  debug: (...args: unknown[]): void => {
    if (process.env.LOG_LEVEL === "debug") write("debug", args);
  },
  info: (...args: unknown[]): void => write("info", args),
  warn: (...args: unknown[]): void => write("warn", args),
  error: (...args: unknown[]): void => write("error", args),
};
