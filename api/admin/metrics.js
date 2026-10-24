// Admin metrics endpoint: aggregated revenue, order counts, and per-shop metrics
import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  if (!requireAdmin(req)) return res.status(401).json({ error: 'Not signed in' })
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // Current month in IST
  const now = new Date()
  const istNow = new Date(now.getTime() + 5.5 * 60 * 60 * 1000)
  const yearMonth = istNow.toISOString().slice(0, 7) // 'YYYY-MM'

  // Fetch all-time platform totals from shop_monthly_metrics
  const { data: allMetrics, error: metricsErr } = await db
    .from('shop_monthly_metrics')
    .select('shop_id,product,year_month,orders_created,orders_delivered,gross_revenue,collected_revenue,outstanding,overage_amount,overage_orders,plan_tier,is_billed')

  if (metricsErr) return res.status(500).json({ error: 'Could not load metrics: ' + metricsErr.message })

  // Current month metrics
  const { data: currentMonthMetrics, error: cmErr } = await db
    .from('shop_monthly_metrics')
    .select('shop_id,product,orders_created,orders_delivered,gross_revenue,collected_revenue,outstanding,overage_amount,overage_orders,plan_tier')
    .eq('year_month', yearMonth)

  if (cmErr) return res.status(500).json({ error: 'Could not load current month metrics' })

  // Aggregate platform totals
  const totals = {
    all_time: { gross_revenue: 0, collected_revenue: 0, outstanding: 0, orders_created: 0, orders_delivered: 0, overage_amount: 0 },
    current_month: { gross_revenue: 0, collected_revenue: 0, outstanding: 0, orders_created: 0, orders_delivered: 0, overage_amount: 0 }
  }

  ;(allMetrics || []).forEach(m => {
    totals.all_time.gross_revenue += Number(m.gross_revenue) || 0
    totals.all_time.collected_revenue += Number(m.collected_revenue) || 0
    totals.all_time.outstanding += Number(m.outstanding) || 0
    totals.all_time.orders_created += Number(m.orders_created) || 0
    totals.all_time.orders_delivered += Number(m.orders_delivered) || 0
    totals.all_time.overage_amount += Number(m.overage_amount) || 0
  })

  ;(currentMonthMetrics || []).forEach(m => {
    totals.current_month.gross_revenue += Number(m.gross_revenue) || 0
    totals.current_month.collected_revenue += Number(m.collected_revenue) || 0
    totals.current_month.outstanding += Number(m.outstanding) || 0
    totals.current_month.orders_created += Number(m.orders_created) || 0
    totals.current_month.orders_delivered += Number(m.orders_delivered) || 0
    totals.current_month.overage_amount += Number(m.overage_amount) || 0
  })

  res.json({
    year_month: yearMonth,
    totals,
    current_month_metrics: currentMonthMetrics || [],
    all_metrics: allMetrics || []
  })
}
