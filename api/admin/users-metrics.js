import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  if (!requireAdmin(req)) return res.status(401).json({ error: 'Not signed in' })

  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // Timestamps in IST (UTC+5:30)
  const now = new Date()
  const istNow = new Date(now.getTime() + 5.5 * 60 * 60 * 1000)

  // Start of today in IST
  const startOfTodayIST = new Date(Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), istNow.getUTCDate(), 0, 0, 0))
  const startOfTodayISO = new Date(startOfTodayIST.getTime() - 5.5 * 60 * 60 * 1000).toISOString()

  // 7 days ago & 30 days ago
  const ms7d = 7 * 24 * 60 * 60 * 1000
  const ms30d = 30 * 24 * 60 * 60 * 1000
  const since7dISO = new Date(now.getTime() - ms7d).toISOString()
  const since30dISO = new Date(now.getTime() - ms30d).toISOString()

  // 1. Fetch all registered shops (Owners)
  const { data: shops, error: shopsErr } = await db
    .from('shops')
    .select('id, name, owner_id, owner_name, email, mobile, city, status, created_at')
    .is('deleted_at', null)

  if (shopsErr) return res.status(500).json({ error: 'Failed to load shops: ' + shopsErr.message })

  // 2. Fetch staff accounts
  const { data: staffList } = await db
    .from('shop_staff')
    .select('id, shop_id, user_id, email, name, role, created_at')

  // 3. Collect active user actions across transactional tables
  // Orders
  const { data: recentOrders } = await db
    .from('orders')
    .select('shop_id, created_by, created_at')
    .gte('created_at', since30dISO)

  // Bills
  const { data: recentBills } = await db
    .from('bills')
    .select('shop_id, created_by, created_at')
    .gte('created_at', since30dISO)

  // Cafe Bills
  const { data: recentCafeBills } = await db
    .from('cafe_bills')
    .select('shop_id, created_by, finalized_by, created_at')
    .gte('created_at', since30dISO)

  // Transactions (Expense Tracker)
  const { data: recentTxns } = await db
    .from('transactions')
    .select('shop_id, created_by, created_at')
    .gte('created_at', since30dISO)

  // Track distinct users active: DAU (today), WAU (7 days), MAU (30 days)
  const dauUsers = new Set() // Today
  const wauUsers = new Set() // 7 Days
  const mauUsers = new Set() // 30 Days

  const dauShops = new Set()
  const wauShops = new Set()
  const mauShops = new Set()

  const shopActivityMap = {} // shop_id -> { last_active, actions_30d, actions_today }

  const recordActivity = (shopId, userIdentifier, timestampStr) => {
    if (!timestampStr) return
    const ts = new Date(timestampStr).getTime()
    const userKey = userIdentifier || `shop_${shopId}`

    if (!shopActivityMap[shopId]) {
      shopActivityMap[shopId] = {
        last_active: timestampStr,
        actions_30d: 0,
        actions_today: 0
      }
    }
    const sAct = shopActivityMap[shopId]
    sAct.actions_30d += 1
    if (new Date(timestampStr) > new Date(sAct.last_active)) {
      sAct.last_active = timestampStr
    }

    // 30 days check
    if (timestampStr >= since30dISO) {
      mauUsers.add(userKey)
      mauShops.add(shopId)
    }

    // 7 days check
    if (timestampStr >= since7dISO) {
      wauUsers.add(userKey)
      wauShops.add(shopId)
    }

    // Today check
    if (timestampStr >= startOfTodayISO) {
      dauUsers.add(userKey)
      dauShops.add(shopId)
      sAct.actions_today += 1
    }
  }

  ;(recentOrders || []).forEach(o => recordActivity(o.shop_id, o.created_by, o.created_at))
  ;(recentBills || []).forEach(b => recordActivity(b.shop_id, b.created_by, b.created_at))
  ;(recentCafeBills || []).forEach(c => {
    recordActivity(c.shop_id, c.created_by, c.created_at)
    if (c.finalized_by && c.finalized_by !== c.created_by) {
      recordActivity(c.shop_id, c.finalized_by, c.created_at)
    }
  })
  ;(recentTxns || []).forEach(t => recordActivity(t.shop_id, t.created_by, t.created_at))

  // Total user accounts registered = Owner accounts (shops with owner_id) + Staff accounts
  const totalOwners = (shops || []).length
  const totalStaff = (staffList || []).length
  const totalUsers = totalOwners + totalStaff

  // New signups in last 30d & 7d
  const newOwners30d = (shops || []).filter(s => s.created_at && s.created_at >= since30dISO).length
  const newOwnersToday = (shops || []).filter(s => s.created_at && s.created_at >= startOfTodayISO).length

  // Build per-shop user and activity list
  const shopListWithUsers = (shops || []).map(s => {
    const sStaff = (staffList || []).filter(st => st.shop_id === s.id)
    const act = shopActivityMap[s.id] || { last_active: null, actions_30d: 0, actions_today: 0 }

    let activityStatus = 'inactive'
    if (act.last_active) {
      if (act.last_active >= startOfTodayISO) activityStatus = 'active_today'
      else if (act.last_active >= since7dISO) activityStatus = 'active_this_week'
      else if (act.last_active >= since30dISO) activityStatus = 'active_this_month'
    }

    return {
      shop_id: s.id,
      shop_name: s.name,
      owner_name: s.owner_name,
      owner_email: s.email,
      owner_mobile: s.mobile,
      city: s.city,
      status: s.status,
      staff_count: sStaff.length,
      total_accounts: 1 + sStaff.length,
      last_active: act.last_active,
      actions_today: act.actions_today,
      actions_30d: act.actions_30d,
      activity_status: activityStatus,
      staff: sStaff.map(st => ({ id: st.id, name: st.name, email: st.email, role: st.role }))
    }
  })

  res.json({
    kpis: {
      total_users: totalUsers,
      total_owners: totalOwners,
      total_staff: totalStaff,
      dau: dauUsers.size,              // Daily Active Users (today)
      wau: wauUsers.size,              // Weekly Active Users (7 days)
      mau: mauUsers.size,              // Monthly Active Users (30 days)
      dau_shops: dauShops.size,        // Active Shops Today
      wau_shops: wauShops.size,        // Active Shops 7 Days
      mau_shops: mauShops.size,        // Active Shops 30 Days
      stickiness_ratio: mauUsers.size ? Math.round((dauUsers.size / mauUsers.size) * 100) : 0, // DAU / MAU %
      new_users_30d: newOwners30d,
      new_users_today: newOwnersToday
    },
    shops_activity: shopListWithUsers
  })
}
