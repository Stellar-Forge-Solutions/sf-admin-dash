import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  if (!requireAdmin(req)) return res.status(401).json({ error: 'Not signed in' })
  const statusParam = req.query.status
  const validStatuses = ['pending_review', 'approved', 'suspended', 'rejected']
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  let query = db.from('shops')
    .select(`
      id,
      name,
      owner_name,
      mobile,
      whatsapp,
      email,
      city,
      business_type,
      ref_link,
      signup_product,
      status,
      created_at,
      review_due_at,
      plan,
      plan_start,
      plan_renewal_date,
      billing_cycle,
      custom_order_limit,
      overage_limit_rupees,
      monthly_overage_limit,
      entitlements (
        product,
        plan,
        plan_tier,
        overage_rate,
        trial_started_at,
        trial_ends_at,
        paid_until,
        billing_cycle
      )
    `)
    .is('deleted_at', null)

  if (statusParam && validStatuses.includes(statusParam)) {
    query = query.eq('status', statusParam).order('created_at', { ascending: true })
  } else {
    query = query.order('created_at', { ascending: false })
  }

  const { data, error } = await query.limit(500)
  if (error) return res.status(500).json({ error: 'Could not load shops: ' + error.message })
  res.json({ shops: data })
}
