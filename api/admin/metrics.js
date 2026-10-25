// Admin metrics endpoint: aggregates live orders & revenue directly from orders, bills, and cafe_bills
import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  if (!requireAdmin(req)) return res.status(401).json({ error: 'Not signed in' })
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // Current month bounds in IST (UTC + 5:30)
  const now = new Date()
  const istNow = new Date(now.getTime() + 5.5 * 60 * 60 * 1000)
  const yearMonth = istNow.toISOString().slice(0, 7) // 'YYYY-MM'
  const startOfMonthIST = new Date(Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), 1, 0, 0, 0))
  // convert to ISO string for query
  const startOfMonthISO = new Date(startOfMonthIST.getTime() - 5.5 * 60 * 60 * 1000).toISOString()

  // 1. Fetch live orders from Orders product
  const { data: liveOrders, error: ordersErr } = await db
    .from('orders')
    .select('id, shop_id, total, amount_paid, stage_key, payment_status, created_at')

  // 2. Fetch live bills from Billing product (exclude cancelled bills)
  const { data: liveBills, error: billsErr } = await db
    .from('bills')
    .select('id, shop_id, total_amount, status, created_at')
    .neq('status', 'cancelled')

  // 3. Fetch live cafe bills from Cafe QR product (exclude cancelled)
  const { data: liveCafeBills, error: cafeErr } = await db
    .from('cafe_bills')
    .select('id, shop_id, total, status, created_at')
    .neq('status', 'cancelled')

  // 4. Also fetch snapshot table for any overage calculations if available
  const { data: snapshotMetrics } = await db
    .from('shop_monthly_metrics')
    .select('shop_id, product, overage_amount, overage_orders')

  const totals = {
    all_time: {
      gross_revenue: 0,
      collected_revenue: 0,
      outstanding: 0,
      orders_created: 0,
      orders_delivered: 0,
      overage_amount: 0,
      breakdown: { orders_app: 0, billing_app: 0, cafe_app: 0 }
    },
    current_month: {
      gross_revenue: 0,
      collected_revenue: 0,
      outstanding: 0,
      orders_created: 0,
      orders_delivered: 0,
      overage_amount: 0,
      breakdown: { orders_app: 0, billing_app: 0, cafe_app: 0 }
    }
  }

  // Map to hold aggregated figures per shop_id
  const shopTotals = {}

  const ensureShop = (shopId) => {
    if (!shopTotals[shopId]) {
      shopTotals[shopId] = {
        orders: 0,
        revenue: 0,
        collected: 0,
        overage: 0,
        breakdown: {
          orders_count: 0,
          orders_revenue: 0,
          bills_count: 0,
          bills_revenue: 0,
          cafe_count: 0,
          cafe_revenue: 0
        }
      }
    }
    return shopTotals[shopId]
  }

  // Process live Orders
  ;(liveOrders || []).forEach(o => {
    const shop = ensureShop(o.shop_id)
    const tot = Number(o.total) || 0
    const paid = Number(o.amount_paid) || 0
    const isThisMonth = o.created_at && o.created_at >= startOfMonthISO

    shop.orders += 1
    shop.revenue += tot
    shop.collected += paid
    shop.breakdown.orders_count += 1
    shop.breakdown.orders_revenue += tot

    totals.all_time.orders_created += 1
    totals.all_time.gross_revenue += tot
    totals.all_time.collected_revenue += paid
    totals.all_time.breakdown.orders_app += tot
    if (o.stage_key === 'delivered') totals.all_time.orders_delivered += 1

    if (isThisMonth) {
      totals.current_month.orders_created += 1
      totals.current_month.gross_revenue += tot
      totals.current_month.collected_revenue += paid
      totals.current_month.breakdown.orders_app += tot
      if (o.stage_key === 'delivered') totals.current_month.orders_delivered += 1
    }
  })

  // Process live Bills (Billing App)
  ;(liveBills || []).forEach(b => {
    const shop = ensureShop(b.shop_id)
    const tot = Number(b.total_amount) || 0
    const isThisMonth = b.created_at && b.created_at >= startOfMonthISO

    shop.orders += 1
    shop.revenue += tot
    shop.collected += tot // in billing, bills are direct invoices
    shop.breakdown.bills_count += 1
    shop.breakdown.bills_revenue += tot

    totals.all_time.orders_created += 1
    totals.all_time.gross_revenue += tot
    totals.all_time.collected_revenue += tot
    totals.all_time.breakdown.billing_app += tot

    if (isThisMonth) {
      totals.current_month.orders_created += 1
      totals.current_month.gross_revenue += tot
      totals.current_month.collected_revenue += tot
      totals.current_month.breakdown.billing_app += tot
    }
  })

  // Process live Cafe Bills (Cafe App)
  ;(liveCafeBills || []).forEach(c => {
    const shop = ensureShop(c.shop_id)
    const tot = Number(c.total) || 0
    const isThisMonth = c.created_at && c.created_at >= startOfMonthISO

    shop.orders += 1
    shop.revenue += tot
    shop.collected += tot
    shop.breakdown.cafe_count += 1
    shop.breakdown.cafe_revenue += tot

    totals.all_time.orders_created += 1
    totals.all_time.gross_revenue += tot
    totals.all_time.collected_revenue += tot
    totals.all_time.breakdown.cafe_app += tot

    if (isThisMonth) {
      totals.current_month.orders_created += 1
      totals.current_month.gross_revenue += tot
      totals.current_month.collected_revenue += tot
      totals.current_month.breakdown.cafe_app += tot
    }
  })

  // Add overages from snapshot if any
  ;(snapshotMetrics || []).forEach(m => {
    const shop = ensureShop(m.shop_id)
    const ovAmt = Number(m.overage_amount) || 0
    shop.overage += ovAmt
    totals.all_time.overage_amount += ovAmt
  })

  totals.all_time.outstanding = Math.max(0, totals.all_time.gross_revenue - totals.all_time.collected_revenue)
  totals.current_month.outstanding = Math.max(0, totals.current_month.gross_revenue - totals.current_month.collected_revenue)

  res.json({
    year_month: yearMonth,
    totals,
    shop_totals: shopTotals
  })
}
