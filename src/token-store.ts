import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  scryptSync,
} from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Encrypted token store — persists refresh tokens to disk (one per account)
// ---------------------------------------------------------------------------

interface StoredAccount {
  email: string;
  refreshToken: string; // encrypted
  addedAt: string;
}

interface StoreData {
  accounts: StoredAccount[];
}

const ALGORITHM = "aes-256-gcm";

function dataDir(): string {
  return process.env.DATA_DIR || "./data";
}

function dataFile(): string {
  return join(dataDir(), "accounts.json");
}

function deriveKey(): Buffer {
  const secret = process.env.ENCRYPTION_KEY;
  if (!secret) {
    throw new Error("ENCRYPTION_KEY environment variable is required");
  }
  return scryptSync(secret, "gmail-mcp-salt", 32);
}

function encrypt(plaintext: string): string {
  const key = deriveKey();
  const iv = randomBytes(16);
  const cipher = createCipheriv(ALGORITHM, key, iv);
  const encrypted = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return [iv.toString("hex"), tag.toString("hex"), encrypted.toString("hex")].join(":");
}

function decrypt(blob: string): string {
  const key = deriveKey();
  const [ivHex, tagHex, encHex] = blob.split(":");
  const decipher = createDecipheriv(
    ALGORITHM,
    key,
    Buffer.from(ivHex, "hex")
  );
  decipher.setAuthTag(Buffer.from(tagHex, "hex"));
  return Buffer.concat([
    decipher.update(Buffer.from(encHex, "hex")),
    decipher.final(),
  ]).toString("utf8");
}

export class TokenStore {
  private accounts = new Map<string, StoredAccount>();

  constructor() {
    this.load();
  }

  private load(): void {
    const dir = dataDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

    const file = dataFile();
    if (!existsSync(file)) return;

    try {
      const raw: StoreData = JSON.parse(readFileSync(file, "utf8"));
      for (const acct of raw.accounts ?? []) {
        this.accounts.set(acct.email, acct);
      }
      console.log(`[token-store] Loaded ${this.accounts.size} account(s)`);
    } catch (err) {
      console.error("[token-store] Failed to load accounts file — starting fresh", err);
    }
  }

  private save(): void {
    const dir = dataDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

    writeFileSync(
      dataFile(),
      JSON.stringify(
        { accounts: Array.from(this.accounts.values()) } satisfies StoreData,
        null,
        2
      )
    );
  }

  addAccount(email: string, refreshToken: string): void {
    this.accounts.set(email, {
      email,
      refreshToken: encrypt(refreshToken),
      addedAt: new Date().toISOString(),
    });
    this.save();
    console.log(`[token-store] Added account: ${email}`);
  }

  removeAccount(email: string): boolean {
    const deleted = this.accounts.delete(email);
    if (deleted) {
      this.save();
      console.log(`[token-store] Removed account: ${email}`);
    }
    return deleted;
  }

  getRefreshToken(email: string): string | null {
    const acct = this.accounts.get(email);
    if (!acct) return null;
    try {
      return decrypt(acct.refreshToken);
    } catch (err) {
      console.error(`[token-store] Failed to decrypt token for ${email}`, err);
      return null;
    }
  }

  listAccounts(): { email: string; addedAt: string }[] {
    return Array.from(this.accounts.values()).map((a) => ({
      email: a.email,
      addedAt: a.addedAt,
    }));
  }

  hasAccount(email: string): boolean {
    return this.accounts.has(email);
  }

  get size(): number {
    return this.accounts.size;
  }
}
