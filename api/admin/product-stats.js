import { createClient } from '@supabase/supabase-js'
import { requireAdmin } from '../_lib/adminSession.js'

export default async function handler(req, res) {
  if (!requireAdmin(req)) return res.status(401).json({ error: 'Not signed in' })

  const product = req.query.product || 'orders'
  const shopId = req.query.shop_id || null

  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } })

  // Current month bounds in IST (UTC + 5:30)
  const now = new Date()
  const istNow = new Date(now.getTime() + 5.5 * 60 * 60 * 1000)
  const startOfMonthIST = new Date(Date.UTC(istNow.getUTCFullYear(), istNow.getUTCMonth(), 1, 0, 0, 0))
  const startOfMonthISO = new Date(startOfMonthIST.getTime() - 5.5 * 60 * 60 * 1000).toISOString()

  // 1. Fetch shops and their entitlements
  let shopQuery = db.from('shops')
    .select('id, name, owner_name, mobile, email, city, status, plan, custom_order_limit, overage_limit_rupees, created_at, entitlements(product, plan, plan_tier, overage_rate, trial_started_at, trial_ends_at, paid_until)')
    .is('deleted_at', null)

  if (shopId) {
    shopQuery = shopQuery.eq('id', shopId)
  }

  const { data: allShops, error: shopsErr } = await shopQuery
  if (shopsErr) return res.status(500).json({ error: 'Failed to load shops: ' + shopsErr.message })

  const result = {
    product,
    shop_id: shopId,
    kpis: {},
    breakdowns: {},
    shops_data: []
  }

  // --------------------------------------------------------------------------
  // PRODUCT 1: ORDERS
  // --------------------------------------------------------------------------
  if (product === 'orders') {
    let orderQuery = db.from('orders')
      .select('id, shop_id, total, amount_paid, stage_key, payment_status, discount_amount, freight, created_at, delivered_at')
    if (shopId) orderQuery = orderQuery.eq('shop_id', shopId)
    const { data: orders } = await orderQuery

    let custQuery = db.from('order_customers').select('id, shop_id')
    if (shopId) custQuery = custQuery.eq('shop_id', shopId)
    const { data: customers } = await custQuery

    let prodQuery = db.from('order_products').select('id, shop_id')
    if (shopId) prodQuery = prodQuery.eq('shop_id', shopId)
    const { data: productsList } = await prodQuery

    const stages = {}
    const payments = {}
    let grossRev = 0
    let collectedRev = 0
    let deliveredCount = 0
    let totalDiscount = 0
    let monthOrders = 0

    const shopStatsMap = {}

    ;(orders || []).forEach(o => {
      const tot = Number(o.total) || 0
      const paid = Number(o.amount_paid) || 0
      const disc = Number(o.discount_amount) || 0
      const isDelivered = o.stage_key === 'delivered'
      const isThisMonth = o.created_at && o.created_at >= startOfMonthISO

      grossRev += tot
      collectedRev += paid
      totalDiscount += disc
      if (isDelivered) deliveredCount += 1
      if (isThisMonth) monthOrders += 1

      stages[o.stage_key || 'other'] = (stages[o.stage_key || 'other'] || 0) + 1
      payments[o.payment_status || 'unpaid'] = (payments[o.payment_status || 'unpaid'] || 0) + 1

      if (!shopStatsMap[o.shop_id]) {
        shopStatsMap[o.shop_id] = {
          orders_count: 0,
          delivered_count: 0,
          month_orders: 0,
          gross: 0,
          collected: 0,
          discount: 0
        }
      }
      const sStat = shopStatsMap[o.shop_id]
      sStat.orders_count += 1
      sStat.gross += tot
      sStat.collected += paid
      sStat.discount += disc
      if (isDelivered) sStat.delivered_count += 1
      if (isThisMonth) sStat.month_orders += 1
    })

    const custCountMap = {}
    ;(customers || []).forEach(c => {
      custCountMap[c.shop_id] = (custCountMap[c.shop_id] || 0) + 1
    })

    const prodCountMap = {}
    ;(productsList || []).forEach(p => {
      prodCountMap[p.shop_id] = (prodCountMap[p.shop_id] || 0) + 1
    })

    const totalOrdersCount = orders?.length || 0
    result.kpis = {
      total_orders: totalOrdersCount,
      delivered_orders: deliveredCount,
      fulfillment_rate: totalOrdersCount ? Math.round((deliveredCount / totalOrdersCount) * 100) : 0,
      gross_revenue: Math.round(grossRev),
      collected_revenue: Math.round(collectedRev),
      outstanding: Math.max(0, Math.round(grossRev - collectedRev)),
      avg_order_value: totalOrdersCount ? Math.round(grossRev / totalOrdersCount) : 0,
      total_customers: customers?.length || 0,
      total_catalog_products: productsList?.length || 0,
      month_orders: monthOrders
    }

    result.breakdowns = {
      stages,
      payments
    }

    result.shops_data = (allShops || []).map(s => {
      const stat = shopStatsMap[s.id] || { orders_count: 0, delivered_count: 0, month_orders: 0, gross: 0, collected: 0, discount: 0 }
      const ent = (s.entitlements || []).find(e => e.product === 'orders') || {}
      const curPlan = ent.plan_tier || ent.plan || s.plan || 'free'
      const quota = s.custom_order_limit !== null && s.custom_order_limit !== undefined
        ? s.custom_order_limit
        : (curPlan === 'pro' ? 999999 : 100)

      // Lifetime order cap: evaluate against total lifetime orders
      const overageOrders = quota !== 999999 ? Math.max(0, stat.orders_count - quota) : 0
      const rate = ent.overage_rate !== null && ent.overage_rate !== undefined ? ent.overage_rate : 0.30
      const overageFee = Math.round(overageOrders * rate)

      return {
        id: s.id,
        name: s.name,
        owner_name: s.owner_name,
        city: s.city,
        status: s.status,
        plan: curPlan,
        quota,
        month_orders: stat.month_orders,
        quota_used_pct: quota && quota !== 999999 ? Math.min(100, Math.round((stat.orders_count / quota) * 100)) : 0,
        overage_orders: overageOrders,
        overage_fee: overageFee,
        total_orders: stat.orders_count,
        delivered_orders: stat.delivered_count,
        gross_revenue: Math.round(stat.gross),
        collected_revenue: Math.round(stat.collected),
        customers_count: custCountMap[s.id] || 0,
        products_count: prodCountMap[s.id] || 0
      }
    })
  }

  // --------------------------------------------------------------------------
  // PRODUCT 2: BILLING
  // --------------------------------------------------------------------------
  else if (product === 'billing') {
    let billsQuery = db.from('bills')
      .select('id, shop_id, total_amount, status, discount_amount, discount_percent, billing_date, created_at')
    if (shopId) billsQuery = billsQuery.eq('shop_id', shopId)
    const { data: bills } = await billsQuery

    let itemsQuery = db.from('items').select('id, shop_id')
    if (shopId) itemsQuery = itemsQuery.eq('shop_id', shopId)
    const { data: items } = await itemsQuery

    const statusBreakdown = {}
    let grossRev = 0
    let totalDiscount = 0
    let monthBills = 0
    const shopStatsMap = {}

    ;(bills || []).forEach(b => {
      const tot = Number(b.total_amount) || 0
      const disc = Number(b.discount_amount) || 0
      const isThisMonth = b.created_at && b.created_at >= startOfMonthISO
      statusBreakdown[b.status || 'draft'] = (statusBreakdown[b.status || 'draft'] || 0) + 1

      if (b.status !== 'cancelled') {
        grossRev += tot
        totalDiscount += disc
        if (isThisMonth) monthBills += 1
      }

      if (!shopStatsMap[b.shop_id]) {
        shopStatsMap[b.shop_id] = { total_bills: 0, final_bills: 0, cancelled_bills: 0, month_bills: 0, revenue: 0, discount: 0 }
      }
      const sStat = shopStatsMap[b.shop_id]
      sStat.total_bills += 1
      if (b.status === 'final') sStat.final_bills += 1
      if (b.status === 'cancelled') sStat.cancelled_bills += 1
      if (b.status !== 'cancelled') {
        sStat.revenue += tot
        sStat.discount += disc
        if (isThisMonth) sStat.month_bills += 1
      }
    })

    const itemCountMap = {}
    ;(items || []).forEach(i => {
      itemCountMap[i.shop_id] = (itemCountMap[i.shop_id] || 0) + 1
    })

    const totalBillsCount = bills?.length || 0
    result.kpis = {
      total_bills: totalBillsCount,
      active_bills: totalBillsCount - (statusBreakdown.cancelled || 0),
      month_bills: monthBills,
      total_revenue: Math.round(grossRev),
      avg_bill_amount: totalBillsCount ? Math.round(grossRev / totalBillsCount) : 0,
      total_discount: Math.round(totalDiscount),
      catalog_items: items?.length || 0
    }

    result.breakdowns = {
      status: statusBreakdown
    }

    result.shops_data = (allShops || []).map(s => {
      const stat = shopStatsMap[s.id] || { total_bills: 0, final_bills: 0, cancelled_bills: 0, month_bills: 0, revenue: 0, discount: 0 }
      const ent = (s.entitlements || []).find(e => e.product === 'billing') || {}
      return {
        id: s.id,
        name: s.name,
        owner_name: s.owner_name,
        city: s.city,
        status: s.status,
        plan: ent.plan_tier || ent.plan || s.plan || 'basic',
        trial_ends_at: ent.trial_ends_at,
        paid_until: ent.paid_until,
        total_bills: stat.total_bills,
        final_bills: stat.final_bills,
        month_bills: stat.month_bills,
        revenue: Math.round(stat.revenue),
        items_count: itemCountMap[s.id] || 0
      }
    })
  }

  // --------------------------------------------------------------------------
  // PRODUCT 3: CAFE QR
  // --------------------------------------------------------------------------
  else if (product === 'cafe') {
    let cafeBillsQuery = db.from('cafe_bills')
      .select('id, shop_id, total, status, source, payment_mode, cgst_amt, sgst_amt, discount_amount, created_at')
    if (shopId) cafeBillsQuery = cafeBillsQuery.eq('shop_id', shopId)
    const { data: cafeBills } = await cafeBillsQuery

    let tablesQuery = db.from('cafe_tables').select('id, shop_id')
    if (shopId) tablesQuery = tablesQuery.eq('shop_id', shopId)
    const { data: tables } = await tablesQuery

    let menuQuery = db.from('cafe_items').select('id, shop_id')
    if (shopId) menuQuery = menuQuery.eq('shop_id', shopId)
    const { data: menuItems } = await menuQuery

    const sourceBreakdown = { customer: 0, staff: 0 }
    const paymentModes = {}
    let grossSales = 0
    let totalTax = 0
    let monthBills = 0
    const shopStatsMap = {}

    ;(cafeBills || []).forEach(b => {
      const tot = Number(b.total) || 0
      const cgst = Number(b.cgst_amt) || 0
      const sgst = Number(b.sgst_amt) || 0
      const isThisMonth = b.created_at && b.created_at >= startOfMonthISO

      sourceBreakdown[b.source || 'staff'] = (sourceBreakdown[b.source || 'staff'] || 0) + 1
      if (b.payment_mode) {
        paymentModes[b.payment_mode] = (paymentModes[b.payment_mode] || 0) + 1
      }

      if (b.status !== 'cancelled') {
        grossSales += tot
        totalTax += (cgst + sgst)
        if (isThisMonth) monthBills += 1
      }

      if (!shopStatsMap[b.shop_id]) {
        shopStatsMap[b.shop_id] = { total_orders: 0, month_orders: 0, revenue: 0, tax: 0, qr_orders: 0, staff_orders: 0 }
      }
      const sStat = shopStatsMap[b.shop_id]
      sStat.total_orders += 1
      if (b.source === 'customer') sStat.qr_orders += 1
      else sStat.staff_orders += 1
      if (b.status !== 'cancelled') {
        sStat.revenue += tot
        sStat.tax += (cgst + sgst)
        if (isThisMonth) sStat.month_orders += 1
      }
    })

    const tableCountMap = {}
    ;(tables || []).forEach(t => {
      tableCountMap[t.shop_id] = (tableCountMap[t.shop_id] || 0) + 1
    })

    const menuCountMap = {}
    ;(menuItems || []).forEach(m => {
      menuCountMap[m.shop_id] = (menuCountMap[m.shop_id] || 0) + 1
    })

    result.kpis = {
      total_orders: cafeBills?.length || 0,
      month_orders: monthBills,
      total_sales: Math.round(grossSales),
      total_tax: Math.round(totalTax),
      total_tables: tables?.length || 0,
      total_menu_items: menuItems?.length || 0,
      customer_qr_pct: cafeBills?.length ? Math.round(((sourceBreakdown.customer || 0) / cafeBills.length) * 100) : 0
    }

    result.breakdowns = {
      source: sourceBreakdown,
      payment_modes: paymentModes
    }

    result.shops_data = (allShops || []).map(s => {
      const stat = shopStatsMap[s.id] || { total_orders: 0, month_orders: 0, revenue: 0, tax: 0, qr_orders: 0, staff_orders: 0 }
      const ent = (s.entitlements || []).find(e => e.product === 'cafe') || {}
      const curPlan = ent.plan_tier || ent.plan || s.plan || 'free'
      const quota = s.custom_order_limit !== null && s.custom_order_limit !== undefined
        ? s.custom_order_limit
        : (curPlan === 'pro' ? 999999 : 100)

      return {
        id: s.id,
        name: s.name,
        owner_name: s.owner_name,
        city: s.city,
        status: s.status,
        plan: curPlan,
        quota,
        month_orders: stat.month_orders,
        quota_used_pct: quota !== 999999 ? Math.min(100, Math.round((stat.total_orders / quota) * 100)) : 0,
        total_orders: stat.total_orders,
        qr_orders: stat.qr_orders,
        staff_orders: stat.staff_orders,
        revenue: Math.round(stat.revenue),
        tax: Math.round(stat.tax),
        tables_count: tableCountMap[s.id] || 0,
        menu_count: menuCountMap[s.id] || 0
      }
    })
  }

  // --------------------------------------------------------------------------
  // PRODUCT 4: EXPENSE TRACKER
  // --------------------------------------------------------------------------
  else if (product === 'expenses') {
    let txQuery = db.from('transactions').select('id, shop_id, type, amount, source, txn_date, created_at')
    if (shopId) txQuery = txQuery.eq('shop_id', shopId)
    const { data: txns } = await txQuery

    let lendQuery = db.from('lending').select('id, shop_id, amount, paid_amount, type')
    if (shopId) lendQuery = lendQuery.eq('shop_id', shopId)
    const { data: lendings } = await lendQuery

    let staffQuery = db.from('staff').select('id, shop_id')
    if (shopId) staffQuery = staffQuery.eq('shop_id', shopId)
    const { data: staffList } = await staffQuery

    const typeBreakdown = { sale: 0, expense: 0, purchase: 0 }
    let totalSales = 0
    let totalExpenses = 0
    let totalPurchases = 0
    const shopStatsMap = {}

    ;(txns || []).forEach(t => {
      const amt = Number(t.amount) || 0
      if (t.type === 'sale') totalSales += amt
      if (t.type === 'expense') totalExpenses += amt
      if (t.type === 'purchase') totalPurchases += amt
      typeBreakdown[t.type] = (typeBreakdown[t.type] || 0) + 1

      if (!shopStatsMap[t.shop_id]) {
        shopStatsMap[t.shop_id] = { tx_count: 0, sales: 0, expenses: 0, purchases: 0 }
      }
      const sStat = shopStatsMap[t.shop_id]
      sStat.tx_count += 1
      if (t.type === 'sale') sStat.sales += amt
      if (t.type === 'expense') sStat.expenses += amt
      if (t.type === 'purchase') sStat.purchases += amt
    })

    let totalLent = 0
    let totalLentRecovered = 0
    const shopLendMap = {}
    ;(lendings || []).forEach(l => {
      const amt = Number(l.amount) || 0
      const paid = Number(l.paid_amount) || 0
      totalLent += amt
      totalLentRecovered += paid
      shopLendMap[l.shop_id] = (shopLendMap[l.shop_id] || 0) + (amt - paid)
    })

    const staffCountMap = {}
    ;(staffList || []).forEach(st => {
      staffCountMap[st.shop_id] = (staffCountMap[st.shop_id] || 0) + 1
    })

    result.kpis = {
      total_transactions: txns?.length || 0,
      total_sales: Math.round(totalSales),
      total_expenses: Math.round(totalExpenses),
      total_purchases: Math.round(totalPurchases),
      net_margin: Math.round(totalSales - (totalExpenses + totalPurchases)),
      total_lent: Math.round(totalLent),
      lent_outstanding: Math.max(0, Math.round(totalLent - totalLentRecovered)),
      active_staff: staffList?.length || 0
    }

    result.breakdowns = {
      types: typeBreakdown
    }

    result.shops_data = (allShops || []).map(s => {
      const stat = shopStatsMap[s.id] || { tx_count: 0, sales: 0, expenses: 0, purchases: 0 }
      const ent = (s.entitlements || []).find(e => e.product === 'expenses') || {}
      return {
        id: s.id,
        name: s.name,
        owner_name: s.owner_name,
        city: s.city,
        status: s.status,
        plan: ent.plan_tier || ent.plan || s.plan || 'free',
        tx_count: stat.tx_count,
        sales: Math.round(stat.sales),
        expenses: Math.round(stat.expenses),
        net_profit: Math.round(stat.sales - (stat.expenses + stat.purchases)),
        khata_outstanding: Math.round(shopLendMap[s.id] || 0),
        staff_count: staffCountMap[s.id] || 0
      }
    })
  }

  res.json(result)
}
