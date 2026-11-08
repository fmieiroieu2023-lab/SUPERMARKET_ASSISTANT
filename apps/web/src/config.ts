// The publishable key is meant to be public (it only identifies the project; RLS protects the data).
// Defaults point at `dev`. Production builds override them with VITE_SUPABASE_URL / VITE_SUPABASE_KEY.
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL ?? "https://fijlwdcbindkymqgyfck.supabase.co";
export const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_KEY ?? "sb_publishable_MQAaBG14xPHsOEmGTGzYxQ_3rWFTkKO";
