import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  const admin = requireAdmin(req)
  if (!admin) return res.status(401).json({ error: 'Not signed in' })
  if (req.method !== 'POST') return res.status(405).end()

  const { shop_id, product, plan } = req.body || {}
  if (!shop_id) return res.status(400).json({ error: 'Shop ID is required' })
  if (!['basic', 'pro'].includes(plan)) return res.status(400).json({ error: 'Plan must be basic or pro' })

  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // Find shop to know its signup_product if product is not explicitly specified
  const { data: shop, error: shopErr } = await db.from('shops').select('id, signup_product').eq('id', shop_id).maybeSingle()
  if (shopErr || !shop) return res.status(404).json({ error: 'Shop not found' })

  const targetProduct = product || shop.signup_product || 'billing'

  // Upsert or update entitlement
  const { data: existing } = await db.from('entitlements')
    .select('shop_id, product, plan')
    .eq('shop_id', shop_id)
    .eq('product', targetProduct)
    .maybeSingle()

  if (existing) {
    const { error: updErr } = await db.from('entitlements')
      .update({ plan })
      .eq('shop_id', shop_id)
      .eq('product', targetProduct)
    if (updErr) return res.status(500).json({ error: 'Could not update plan: ' + updErr.message })
  } else {
    const { error: insErr } = await db.from('entitlements')
      .insert({ shop_id, product: targetProduct, plan })
    if (insErr) return res.status(500).json({ error: 'Could not set plan: ' + insErr.message })
  }

  // Audit log
  await db.from('audit_log').insert({
    actor: admin,
    action: 'change_plan',
    shop_id,
    detail: { product: targetProduct, plan, previous_plan: existing?.plan || null }
  })

  res.json({ ok: true, product: targetProduct, plan })
}
