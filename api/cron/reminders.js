// Called every 10 minutes by .github/workflows/reminders.yml. Emails both admins about shops nearing/past their review time.
import { createClient } from '@supabase/supabase-js'
import { sendMail } from '../_lib/brevo.js'

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))
const hhmm = (d) => new Date(d).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })

export default async function handler(req, res) {
  if (req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) return res.status(401).end()
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  const { data: shops } = await db.from('shops').select('id,name,mobile,whatsapp,review_due_at,reminded_soon,reminded_overdue')
    .eq('status', 'pending_review').is('deleted_at', null).not('review_due_at', 'is', null)
  const now = Date.now(), soon = [], late = []
  for (const s of shops || []) {
    const due = new Date(s.review_due_at).getTime()
    if (now >= due && !s.reminded_overdue) late.push(s)
    else if (now >= due - 30 * 60e3 && now < due && !s.reminded_soon) soon.push(s)
  }
  const list = (a) => a.map((s) => `<li><b>${esc(s.name)}</b> · ${esc(s.mobile)} · <a href="https://wa.me/91${esc(s.whatsapp)}">WhatsApp</a> · review by ${hhmm(s.review_due_at)} IST</li>`).join('')
  const to = String(process.env.ADMIN_EMAILS || '').split(',').map((x) => x.trim()).filter(Boolean)
  const btn = `<p><a href="${process.env.ADMIN_DASH_URL}">Open dashboard</a></p>`
  try {
    if (late.length) { await sendMail({ to, subject: `OVERDUE: ${late.length} signup(s) past the 1-hour review time`, html: `<ul>${list(late)}</ul>${btn}` }); await db.from('shops').update({ reminded_overdue: true, reminded_soon: true }).in('id', late.map((s) => s.id)) }
    if (soon.length) { await sendMail({ to, subject: `Reminder: ${soon.length} signup(s) due for review within 30 minutes`, html: `<ul>${list(soon)}</ul>${btn}` }); await db.from('shops').update({ reminded_soon: true }).in('id', soon.map((s) => s.id)) }
  } catch (e) { return res.status(503).json({ ok: false, error: e.message }) } // flags stay unset, so the next run retries
  res.json({ ok: true, soon: soon.length, overdue: late.length })
}
