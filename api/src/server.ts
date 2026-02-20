import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import { authMiddleware } from "./lib/auth";
import bidRouter from "./routes/bid";
import settleRouter from "./routes/settle";
import statusRouter from "./routes/status";

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3001;

// --- Middleware ---
app.use(cors());
app.use(express.json());

// --- Health check (no auth) ---
app.get("/health", (_req, res) => {
  res.json({ status: "ok", timestamp: Date.now() });
});

// --- Protected routes (API key required) ---
app.use("/bid", authMiddleware, bidRouter);
app.use("/settle", authMiddleware, settleRouter);
app.use("/status", authMiddleware, statusRouter);

// --- Start server ---
app.listen(PORT, () => {
  console.log(`\n SealBid API running on port ${PORT}`);
  console.log(`   POST /bid       — Submit a signed bid`);
  console.log(`   POST /settle    — Run Vickrey settlement`);
  console.log(`   GET  /status/:id — Auction status`);
  console.log(`   GET  /health    — Health check\n`);
});

export default app;
