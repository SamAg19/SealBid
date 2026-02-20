import { Request, Response, NextFunction } from "express";

/**
 * Middleware: validates X-Api-Key header against BID_API_KEY env var.
 * Called only via Confidential HTTP from CRE — API key is decrypted
 * inside the enclave and never exposed.
 */
export function authMiddleware(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  const apiKey = req.headers["x-api-key"] as string | undefined;
  const expectedKey = process.env.BID_API_KEY;

  if (!expectedKey) {
    console.error("BID_API_KEY not set in environment");
    res.status(500).json({ error: "Server misconfigured" });
    return;
  }

  if (!apiKey || apiKey !== expectedKey) {
    res.status(403).json({ error: "Invalid API key" });
    return;
  }

  next();
}
