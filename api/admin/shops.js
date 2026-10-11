import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  if (!requireAdmin(req)) return res.status(401).json({ error: 'Not signed in' })
  const status = ['pending_review', 'approved', 'suspended', 'rejected'].includes(req.query.status) ? req.query.status : 'pending_review'
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })
  const { data, error } = await db.from('shops')
    .select('id,name,owner_name,mobile,whatsapp,email,city,business_type,ref_link,signup_product,status,created_at,review_due_at')
    .eq('status', status).is('deleted_at', null).order('created_at', { ascending: true }).limit(200)
  if (error) return res.status(500).json({ error: 'Could not load shops' })
  res.json({ shops: data })
}
