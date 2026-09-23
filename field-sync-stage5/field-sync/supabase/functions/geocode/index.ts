// path: supabase/functions/geocode/index.ts
// Supabase Edge Function 진입점 (Deno). 로직은 handler.ts — Node 테스트에서 fetch·env를 주입해 검증.
import { handle } from './handler.ts';

Deno.serve((req: Request) => handle(req, { fetch, env: Deno.env.toObject() }));
