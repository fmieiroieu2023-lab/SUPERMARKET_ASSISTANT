// The publishable key is meant to be public (it only identifies the project; RLS protects the data).
// Defaults point at `dev`. Production builds override them with VITE_SUPABASE_URL / VITE_SUPABASE_KEY.
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL ?? "https://fijlwdcbindkymqgyfck.supabase.co";
export const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_KEY ?? "sb_publishable_MQAaBG14xPHsOEmGTGzYxQ_3rWFTkKO";
// Web Push public key (VAPID). Public by design; the private half is a Supabase secret.
export const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY ?? "BBGQgqh89eJ4pjC0v1aug24jhYdQ_LTVcv8ykA4VpsAe994ooybtlmL4FpFmg-7z9mKLC8jIhoYclPfC4jbUhmE";
