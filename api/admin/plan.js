import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  const admin = requireAdmin(req)
  if (!admin) return res.status(401).json({ error: 'Not signed in' })
  if (req.method !== 'POST') return res.status(405).end()

  const {
    shop_id,
    product,
    plan,
    custom_order_limit,
    overage_limit_rupees,
    overage_rate
  } = req.body || {}

  if (!shop_id) return res.status(400).json({ error: 'Shop ID is required' })

  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // Find shop
  const { data: shop, error: shopErr } = await db.from('shops')
    .select('id, signup_product, plan, custom_order_limit, overage_limit_rupees')
    .eq('id', shop_id)
    .maybeSingle()

  if (shopErr || !shop) return res.status(404).json({ error: 'Shop not found' })

  const targetProduct = product || shop.signup_product || 'orders'

  // 1. Update shop level plan and custom limits if provided
  const shopUpdates = {}
  if (plan && ['free', 'basic', 'pro'].includes(plan)) {
    shopUpdates.plan = plan
  }
  if (custom_order_limit !== undefined) {
    shopUpdates.custom_order_limit = custom_order_limit === '' || custom_order_limit === null ? null : parseInt(custom_order_limit, 10)
  }
  if (overage_limit_rupees !== undefined) {
    shopUpdates.overage_limit_rupees = overage_limit_rupees === '' || overage_limit_rupees === null ? 300 : parseFloat(overage_limit_rupees)
  }

  if (Object.keys(shopUpdates).length > 0) {
    const { error: shopUpdErr } = await db.from('shops').update(shopUpdates).eq('id', shop_id)
    if (shopUpdErr) return res.status(500).json({ error: 'Failed updating shop limits: ' + shopUpdErr.message })
  }

  // 2. Update entitlement for the specific product
  const entUpdates = {}
  if (plan && ['free', 'basic', 'pro'].includes(plan)) {
    entUpdates.plan_tier = plan
    // entitlements.plan has check (plan in ('basic', 'pro')) in original core schema
    if (['basic', 'pro'].includes(plan)) {
      entUpdates.plan = plan
    }
  }
  if (overage_rate !== undefined && overage_rate !== null && overage_rate !== '') {
    entUpdates.overage_rate = parseFloat(overage_rate)
  }

  let existing = null
  if (targetProduct) {
    const { data: ent } = await db.from('entitlements')
      .select('shop_id, product, plan, plan_tier, overage_rate')
      .eq('shop_id', shop_id)
      .eq('product', targetProduct)
      .maybeSingle()
    existing = ent

    if (existing) {
      if (Object.keys(entUpdates).length > 0) {
        const { error: updErr } = await db.from('entitlements')
          .update(entUpdates)
          .eq('shop_id', shop_id)
          .eq('product', targetProduct)
        if (updErr) return res.status(500).json({ error: 'Could not update entitlement: ' + updErr.message })
      }
    } else {
      const { error: insErr } = await db.from('entitlements')
        .insert({
          shop_id,
          product: targetProduct,
          plan: ['basic', 'pro'].includes(plan) ? plan : 'basic',
          plan_tier: plan || 'free',
          overage_rate: entUpdates.overage_rate || 0.30
        })
      if (insErr) return res.status(500).json({ error: 'Could not set entitlement: ' + insErr.message })
    }
  }

  // Audit log
  await db.from('audit_log').insert({
    actor: admin,
    action: 'change_plan_and_limits',
    shop_id,
    detail: {
      product: targetProduct,
      plan: plan || shop.plan,
      custom_order_limit: shopUpdates.custom_order_limit,
      overage_limit_rupees: shopUpdates.overage_limit_rupees,
      overage_rate: entUpdates.overage_rate
    }
  })

  res.json({ ok: true, product: targetProduct, shopUpdates, entUpdates })
}
