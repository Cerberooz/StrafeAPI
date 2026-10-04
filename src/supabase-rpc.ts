// Server-only RPC transport. Database wrappers retain scope checks and transactions.
export class SupabaseRpcError extends Error {
  constructor(
    readonly responseStatus: number,
    readonly backendCode: string | undefined,
    message: string,
  ) {
    super(message);
    this.name = 'SupabaseRpcError';
  }
}

export class SupabaseRpc {
  private readonly origin: string;
  constructor(url: string, private readonly secret: string) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
      throw new Error('SUPABASE_URL must be an HTTPS project origin.');
    }
    if (!secret.startsWith('sb_secret_')) throw new Error('SUPABASE_SECRET_KEY must be a server-only sb_secret_ key.');
    this.origin = parsed.origin;
  }
  async call<T>(name: string, parameters: Record<string, unknown>): Promise<T> {
    if (!/^[a-z_]+$/.test(name)) throw new Error('Invalid RPC name');
    const response = await fetch(`${this.origin}/rest/v1/rpc/${name}`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10_000),
      headers: { apikey: this.secret, 'Content-Type': 'application/json', 'Content-Profile': 'strafe_api', 'Accept-Profile': 'strafe_api' },
      body: JSON.stringify(parameters),
    });
    const reader = response.body?.getReader();
    if (!reader) throw new Error('Supabase response missing');
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 16 * 1024 * 1024) throw new Error('Supabase response too large');
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => {}); }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!response.ok) {
      // Only PostgreSQL application exceptions participate in the API's error mapping.
      const rawCode = body !== null && typeof body === 'object' ? body.code : undefined;
      const backendCode = typeof rawCode === 'string' && /^[A-Z0-9_]{1,24}$/.test(rawCode) ? rawCode : undefined;
      throw new SupabaseRpcError(
        response.status,
        backendCode,
        backendCode === 'P0001' && typeof body.message === 'string' ? body.message : 'Supabase RPC unavailable',
      );
    }
    return body as T;
  }
}
