import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'
import { sendMail } from '../_lib/gmail.js'

const esc = (s) => String(s || '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))

export default async function handler(req, res) {
  const admin = requireAdmin(req)
  if (!admin) return res.status(401).json({ error: 'Not signed in' })
  if (req.method !== 'POST') return res.status(405).end()
  const { id, action, note = '' } = req.body || {}
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  const { data: shop } = await db.from('shops').select('id,name,email,email_normalized,mobile,status').eq('id', id).maybeSingle()
  if (!shop) return res.status(404).json({ error: 'Shop not found' })

  let mail = null
  if (action === 'approve') {
    const { error } = await db.rpc('approve_shop', { p_shop: id, p_admin: admin })
    if (error) return res.status(409).json({ error: error.message })
    mail = ['Your Stellar Forge Billing account is approved', `<p>Hi ${esc(shop.name)}, your account is approved. Your 15-day free trial has started. Sign in and set up your shop in Settings.</p>`]
  } else if (action === 'reject' && shop.status === 'pending_review') {
    await db.from('shops').update({ status: 'rejected', reviewed_by: admin, reviewed_at: new Date().toISOString(), review_note: note }).eq('id', id)
    await db.from('blocklist').upsert([{ kind: 'email', value: shop.email_normalized }, { kind: 'mobile', value: shop.mobile }])
    await db.from('audit_log').insert({ actor: admin, action: 'reject', shop_id: id, detail: { note } })
    mail = ['Your Stellar Forge account request', `<p>Hi ${esc(shop.name)}, we could not approve your account request.${note ? ' Note: ' + esc(note) : ''} Reply to this email if you think this is a mistake.</p>`]
  } else if (action === 'suspend' && shop.status === 'approved') {
    await db.from('shops').update({ status: 'suspended', review_note: note }).eq('id', id)
    await db.from('audit_log').insert({ actor: admin, action: 'suspend', shop_id: id, detail: { note } })
  } else if (action === 'reinstate' && shop.status === 'suspended') {
    await db.from('shops').update({ status: 'approved' }).eq('id', id)
    await db.from('audit_log').insert({ actor: admin, action: 'reinstate', shop_id: id })
  } else return res.status(400).json({ error: 'Not allowed for this shop status' })

  let mailed = true
  if (mail) { try { await sendMail({ to: shop.email, subject: mail[0], html: mail[1] }) } catch { mailed = false } }
  res.json({ ok: true, mailed })
}
