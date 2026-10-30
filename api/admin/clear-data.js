// Admin endpoint: wipe all transactional data for a specific shop
// Shops, entitlements, staff, plan config, and auth users are preserved.
import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  const admin = requireAdmin(req)
  if (!admin) return res.status(401).json({ error: 'Not signed in' })
  if (req.method !== 'POST') return res.status(405).end()

  const { shop_id, confirm_token } = req.body || {}
  if (!shop_id) return res.status(400).json({ error: 'shop_id is required' })
  if (confirm_token !== 'CLEAR_SHOP_DATA') {
    return res.status(400).json({ error: 'Missing or invalid confirmation token.' })
  }

  const db = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    { auth: { persistSession: false } }
  )

  // Verify shop exists
  const { data: shop, error: shopErr } = await db
    .from('shops')
    .select('id, name')
    .eq('id', shop_id)
    .maybeSingle()

  if (shopErr) return res.status(500).json({ error: 'DB error: ' + shopErr.message })
  if (!shop) return res.status(404).json({ error: 'Shop not found' })

  // Tables to clear in order (child records first)
  const CLEAR_TABLES = [
    // Orders App
    { table: 'orders', col: 'shop_id' },
    { table: 'order_customers', col: 'shop_id' },
    { table: 'order_products', col: 'shop_id' },
    // Billing App
    { table: 'bills', col: 'shop_id' },
    { table: 'items', col: 'shop_id' },
    // Cafe QR
    { table: 'cafe_bills', col: 'shop_id' },
    { table: 'cafe_tables', col: 'shop_id' },
    { table: 'cafe_items', col: 'shop_id' },
    // Expense Tracker
    { table: 'transactions', col: 'shop_id' },
    { table: 'lending', col: 'shop_id' },
  ]

  const results = {}
  const errors = []

  for (const { table, col } of CLEAR_TABLES) {
    try {
      const { error } = await db
        .from(table)
        .delete()
        .eq(col, shop_id)

      if (error) {
        errors.push({ table, error: error.message })
      } else {
        results[table] = { cleared: true }
      }
    } catch (e) {
      errors.push({ table, error: e.message })
    }
  }

  // Clear storage files for this shop
  const storageBuckets = ['order-bills', 'cafe-bills', 'bills']
  for (const bucket of storageBuckets) {
    try {
      const { data: files } = await db.storage.from(bucket).list(shop_id)
      if (files && files.length > 0) {
        const paths = files.map(f => `${shop_id}/${f.name}`)
        await db.storage.from(bucket).remove(paths)
      }
    } catch (e) {
      console.warn(`Storage clear warning for bucket ${bucket}:`, e.message)
    }
  }

  // Audit log
  await db.from('audit_log').insert({
    actor: admin,
    action: 'clear_shop_data',
    shop_id,
    detail: {
      shop_name: shop.name,
      tables_cleared: CLEAR_TABLES.map(t => t.table),
      errors: errors.length > 0 ? errors : null,
      timestamp: new Date().toISOString()
    }
  }).catch(() => {})

  if (errors.length > 0) {
    return res.status(207).json({
      ok: false,
      message: 'Some tables could not be cleared.',
      shop_name: shop.name,
      results,
      errors
    })
  }

  res.json({ ok: true, message: `All data for "${shop.name}" has been cleared.`, shop_name: shop.name })
}
