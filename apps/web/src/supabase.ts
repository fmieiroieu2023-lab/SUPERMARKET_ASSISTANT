import { createClient } from "@supabase/supabase-js";
import { SUPABASE_KEY, SUPABASE_URL } from "./config";

// The session is kept in this device's localStorage and renewed automatically, so you stay signed in.
export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, storage: window.localStorage },
});

// Ask the browser to keep this site's data (Safari otherwise may clear it after a while of not visiting).
void navigator.storage?.persist?.().catch(() => undefined);
