// Two steps: {step:'password', email, password} -> emails a 6-digit code; {step:'code', email, code} -> sets session.
// No signup exists. Only emails present in platform_admins can ever receive a code.
import { createClient } from '@supabase/supabase-js'
import { scryptSync, randomInt, createHmac, timingSafeEqual } from 'node:crypto'
import { sendMail } from '../_lib/gmail.js'
import { makeSessionCookie } from '../_lib/adminSession.js'

const sb = () => createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })
const hash = (s) => createHmac('sha256', process.env.ADMIN_SESSION_SECRET).update(s).digest('hex')
const same = (a, b) => { const x = Buffer.from(a), y = Buffer.from(b); return x.length === y.length && timingSafeEqual(x, y) }
const FAIL = { ok: false, error: 'Invalid details' } // same reply for every failure: no admin enumeration
const ago = (ms) => new Date(Date.now() - ms).toISOString()

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end()
  const { step, password, code } = req.body || {}
  const email = String(req.body?.email || '').trim().toLowerCase()
  const db = sb()
  const { data: admin } = await db.from('platform_admins').select('*').eq('email', email).maybeSingle()

  if (step === 'password') {
    const derived = scryptSync(String(password || ''), admin?.password_salt || 'none', 64).toString('hex') // runs even for unknown emails
    if (!admin || !same(derived, admin.password_hash)) return res.status(401).json(FAIL)

    const { count: locked } = await db.from('admin_login_codes').select('id', { count: 'exact', head: true })
      .eq('email', email).gte('attempts', 5).gte('created_at', ago(15 * 60e3))
    if (locked) return res.status(429).json({ ok: false, error: 'Too many attempts. Try again in 15 minutes.' })
    const { count: recent } = await db.from('admin_login_codes').select('id', { count: 'exact', head: true })
      .eq('email', email).gte('created_at', ago(60e3))
    if (recent) return res.status(429).json({ ok: false, error: 'Wait 60 seconds before requesting another code.' })

    const c = String(randomInt(0, 1_000_000)).padStart(6, '0')
    await db.from('admin_login_codes').insert({ email, code_hash: hash(email + c), expires_at: new Date(Date.now() + 10 * 60e3).toISOString() })
    try { await sendMail({ to: email, subject: 'Stellar Forge admin login code', html: `<p>Your login code is <b style="font-size:20px">${c}</b>. It expires in 10 minutes.</p>` }) }
    catch { return res.status(503).json({ ok: false, error: 'Could not send the code. Check Gmail credentials.' }) }
    return res.json({ ok: true })
  }

  if (step === 'code' && admin) {
    const { data: row } = await db.from('admin_login_codes').select('*').eq('email', email)
      .is('used_at', null).gt('expires_at', new Date().toISOString()).order('created_at', { ascending: false }).limit(1).maybeSingle()
    if (!row || row.attempts >= 5) return res.status(401).json(FAIL)
    await db.from('admin_login_codes').update({ attempts: row.attempts + 1 }).eq('id', row.id)
    if (!same(hash(email + String(code || '')), row.code_hash)) return res.status(401).json(FAIL)
    await db.from('admin_login_codes').update({ used_at: new Date().toISOString() }).eq('id', row.id)
    await db.from('audit_log').insert({ actor: email, action: 'admin_login' })
    res.setHeader('Set-Cookie', makeSessionCookie(email))
    return res.json({ ok: true })
  }
  return res.status(401).json(FAIL)
}
