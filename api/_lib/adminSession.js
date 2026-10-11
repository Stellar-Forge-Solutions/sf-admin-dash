import { createHmac, timingSafeEqual } from 'node:crypto'
const sign = (v) => createHmac('sha256', process.env.ADMIN_SESSION_SECRET).update(v).digest('hex')

export function makeSessionCookie(email, hours = 8) {
  const body = `${email}|${Date.now() + hours * 3600e3}`
  const val = Buffer.from(body).toString('base64url') + '.' + sign(body)
  return `sf_admin=${val}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${hours * 3600}`
}

// Returns the admin's email if the cookie is valid and unexpired, else null.
export function requireAdmin(req) {
  const m = /(?:^|;\s*)sf_admin=([^;]+)/.exec(req.headers.cookie || '')
  if (!m) return null
  const [b, sig] = m[1].split('.')
  const body = Buffer.from(b || '', 'base64url').toString()
  const a = Buffer.from(sig || ''), e = Buffer.from(sign(body))
  if (a.length !== e.length || !timingSafeEqual(a, e)) return null
  const [email, exp] = body.split('|')
  return Date.now() < Number(exp) ? email : null
}
