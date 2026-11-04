import { describe, expect, test } from 'bun:test';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const HOOK = join(import.meta.dir, '..', 'hooks', 'session-end.sh');

async function runHook(stdin: string, env: Record<string, string>): Promise<
  { code: number; stderr: string }> {
  const p = Bun.spawn(['bash', HOOK], { stdin: new Blob([stdin]), stdout: 'pipe', stderr: 'pipe',
    env: { PATH: process.env.PATH ?? '', ...env } });
  const stderr = await new Response(p.stderr).text();
  return { code: await p.exited, stderr };
}

function fakeServer(): { url: string; seen: { method: string; path: string; auth: string | null }[];
  stop: () => Promise<void> } {
  const seen: { method: string; path: string; auth: string | null }[] = [];
  const s = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
    seen.push({ method: req.method, path: decodeURIComponent(new URL(req.url).pathname),
      auth: req.headers.get('authorization') });
    return new Response(null, { status: 204 });
  } });
  return { url: `http://127.0.0.1:${s.port}`, seen, stop: async () => { await s.stop(true); } };
}

describe('хук SessionEnd', () => {
  const dir = mkdtempSync(join(tmpdir(), 'hook-'));
  const tokenFile = join(dir, 'token');
  writeFileSync(tokenFile, 'sekret\n');

  test('удаляет тред agent:session с Bearer', async () => {
    const srv = fakeServer();
    const r = await runHook('{"session_id":"abc-123","hook_event_name":"SessionEnd"}', {
      PSEUDONYMIZER_URL: srv.url, AGENT_ID: 'dev', PSEUDONYMIZER_TOKEN_FILE: tokenFile });
    expect(r.code).toBe(0);
    expect(srv.seen).toEqual([{ method: 'DELETE', path: '/threads/dev:abc-123',
      auth: 'Bearer sekret' }]);
    expect(r.stderr).not.toContain('sekret');
    await srv.stop();
  });

  test('сервис недоступен: exit 0, запись в stderr', async () => {
    const r = await runHook('{"session_id":"abc"}', {
      PSEUDONYMIZER_URL: 'http://127.0.0.1:1', AGENT_ID: 'dev',
      PSEUDONYMIZER_TOKEN_FILE: tokenFile });
    expect(r.code).toBe(0);
    expect(r.stderr).toContain('не удалось');
  });

  test('мусор в stdin и нет файла токена: exit 0', async () => {
    const a = await runHook('не json', { PSEUDONYMIZER_URL: 'http://x', AGENT_ID: 'dev',
      PSEUDONYMIZER_TOKEN_FILE: tokenFile });
    expect(a.code).toBe(0);
    const b = await runHook('{"session_id":"s"}', { PSEUDONYMIZER_URL: 'http://x', AGENT_ID: 'dev',
      PSEUDONYMIZER_TOKEN_FILE: join(dir, 'нет') });
    expect(b.code).toBe(0);
    expect(b.stderr).toContain('токена');
  });
});
