import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  const admin = requireAdmin(req)
  if (!admin) return res.status(401).json({ error: 'Not signed in' })
  if (req.method !== 'POST' && req.method !== 'DELETE') return res.status(405).end()

  const { id } = req.body || req.query || {}
  if (!id) return res.status(400).json({ error: 'Shop ID is required' })

  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // 1. Check if shop exists
  const { data: shop, error: fetchErr } = await db
    .from('shops')
    .select('id, name, owner_id, email, mobile')
    .eq('id', id)
    .maybeSingle()

  if (fetchErr) return res.status(500).json({ error: 'Database error: ' + fetchErr.message })
  if (!shop) return res.status(404).json({ error: 'Shop not found' })

  // 2. Fetch staff user_ids if any to delete from auth
  const { data: staffList } = await db
    .from('shop_staff')
    .select('user_id')
    .eq('shop_id', id)

  // 3. Delete files from storage buckets belonging to this shop
  const storageBuckets = ['order-bills', 'cafe-bills', 'cafe-menu', 'bills', 'logos']
  for (const b of storageBuckets) {
    try {
      const { data: files } = await db.storage.from(b).list(id)
      if (files && files.length > 0) {
        const filePaths = files.map(f => `${id}/${f.name}`)
        await db.storage.from(b).remove(filePaths)
      }
    } catch (e) {
      // Log and continue even if bucket is empty or not configured
      console.warn(`Storage delete warning for bucket ${b}:`, e.message)
    }
  }

  // 4. Delete shop row (Cascades to all tables referencing shops(id) ON DELETE CASCADE)
  const { error: delErr } = await db
    .from('shops')
    .delete()
    .eq('id', id)

  if (delErr) {
    return res.status(500).json({ error: 'Failed to delete shop: ' + delErr.message })
  }

  // 5. Clean up auth user accounts (Owner + Staff)
  const userIdsToDelete = []
  if (shop.owner_id) userIdsToDelete.push(shop.owner_id)
  if (staffList && staffList.length > 0) {
    staffList.forEach(s => {
      if (s.user_id && !userIdsToDelete.includes(s.user_id)) {
        userIdsToDelete.push(s.user_id)
      }
    })
  }

  for (const uid of userIdsToDelete) {
    try {
      await db.auth.admin.deleteUser(uid)
    } catch (authErr) {
      console.warn(`Failed to delete auth user ${uid}:`, authErr.message)
    }
  }

  // 6. Record in audit_log
  await db.from('audit_log').insert({
    actor: admin,
    action: 'delete_shop',
    shop_id: id,
    detail: {
      name: shop.name,
      email: shop.email,
      mobile: shop.mobile,
      owner_id: shop.owner_id,
      deleted_staff_count: staffList ? staffList.length : 0
    }
  })

  res.json({ ok: true, deleted_id: id, name: shop.name })
}
