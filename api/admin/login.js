// Single step: {email, password} -> verifies password and sets session.
// No signup exists. Only emails present in platform_admins can log in.
import { createClient } from '@supabase/supabase-js'
import { scryptSync, timingSafeEqual } from 'node:crypto'
import { makeSessionCookie } from '../_lib/adminSession.js'

const sb = () => createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })
const same = (a, b) => { const x = Buffer.from(a), y = Buffer.from(b); return x.length === y.length && timingSafeEqual(x, y) }
const FAIL = { ok: false, error: 'Invalid details' } // same reply for every failure: no admin enumeration

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end()
  const { password } = req.body || {}
  const email = String(req.body?.email || '').trim().toLowerCase()
  const db = sb()
  const { data: admin } = await db.from('platform_admins').select('*').eq('email', email).maybeSingle()

  const derived = scryptSync(String(password || ''), admin?.password_salt || 'none', 64).toString('hex') // runs even for unknown emails
  if (!admin || !same(derived, admin.password_hash)) return res.status(401).json(FAIL)

  await db.from('audit_log').insert({ actor: email, action: 'admin_login' })
  res.setHeader('Set-Cookie', makeSessionCookie(email))
  return res.json({ ok: true })
}
