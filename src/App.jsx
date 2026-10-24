import { useEffect, useState, useMemo } from 'react'

const post = async (url, body) => {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  return { ok: r.ok, status: r.status, ...(await r.json().catch(() => ({}))) }
}

const wa = (n) => {
  const d = String(n || '').replace(/\D/g, '')
  return 'https://wa.me/' + (d.length === 10 ? '91' + d : d)
}

const REVIEW_TABS = [
  ['pending_review', 'Pending Review'],
  ['approved', 'Approved'],
  ['suspended', 'Suspended'],
  ['rejected', 'Rejected']
]

const PRODUCT_LABELS = {
  billing: 'Billing',
  expenses: 'Expense Tracker',
  orders: 'Orders',
  cafe: 'Cafe QR'
}

export default function App() {
  const [stage, setStage] = useState('password') // password | in
  const [f, setF] = useState({ email: '', password: '' })
  const [msg, setMsg] = useState('')
  const [page, setPage] = useState('table') // 'review' | 'table' | 'analytics'
  const [reviewTab, setReviewTab] = useState('pending_review')
  const [shops, setShops] = useState(null)
  const [allShops, setAllShops] = useState(null)
  const [metricsData, setMetricsData] = useState(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState('all')
  const [productFilter, setProductFilter] = useState('all')
  const [planFilter, setPlanFilter] = useState('all')
  const [updatingId, setUpdatingId] = useState(null)

  // Edit Modal State
  const [editModal, setEditModal] = useState({
    open: false,
    shop: null,
    plan: 'free',
    product: 'orders',
    custom_order_limit: '',
    overage_limit_rupees: '300',
    overage_rate: '0.30'
  })

  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })

  // Load reviews list
  const loadReviews = async (t = reviewTab) => {
    const r = await fetch('/api/admin/shops?status=' + t)
    if (r.status === 401) return setStage('password')
    const json = await r.json()
    setShops(json.shops || [])
    setStage('in')
  }

  // Load all shops
  const loadAllShops = async () => {
    const r = await fetch('/api/admin/shops?status=all')
    if (r.status === 401) return setStage('password')
    const json = await r.json()
    setAllShops(json.shops || [])
    setStage('in')
  }

  // Load metrics from 0015 migration table
  const loadMetrics = async () => {
    const r = await fetch('/api/admin/metrics')
    if (!r.ok) return
    const json = await r.json()
    setMetricsData(json)
  }

  const reloadData = () => {
    loadReviews(reviewTab)
    loadAllShops()
    loadMetrics()
  }

  useEffect(() => {
    reloadData()
  }, [])

  useEffect(() => {
    if (stage !== 'in') return
    if (page === 'review') loadReviews(reviewTab)
    else {
      loadAllShops()
      loadMetrics()
    }
    const t = setInterval(() => {
      if (page === 'review') loadReviews(reviewTab)
      else {
        loadAllShops()
        loadMetrics()
      }
    }, 60000)
    return () => clearInterval(t)
  }, [page, reviewTab, stage])

  const login = async (e) => {
    e.preventDefault(); setMsg('')
    const r = await post('/api/admin/login', { email: f.email, password: f.password })
    if (!r.ok) return setMsg(r.error || 'Invalid details')
    reloadData()
  }

  const act = async (id, action) => {
    const note = action === 'reject' || action === 'suspend' ? prompt('Note for the shop (optional):') : ''
    if (note === null) return
    setUpdatingId(id)
    const r = await post('/api/admin/review', { id, action, note })
    setUpdatingId(null)
    setMsg(r.ok ? (r.mailed === false ? 'Action done, but email could not be sent.' : 'Success.') : (r.error || 'Action failed'))
    reloadData()
  }

  const openPlanModal = (shop) => {
    const defaultProduct = shop.signup_product || (shop.entitlements && shop.entitlements[0]?.product) || 'orders'
    const ent = (shop.entitlements || []).find(e => e.product === defaultProduct) || {}
    setEditModal({
      open: true,
      shop,
      product: defaultProduct,
      plan: ent.plan_tier || ent.plan || shop.plan || 'free',
      custom_order_limit: shop.custom_order_limit !== null && shop.custom_order_limit !== undefined ? shop.custom_order_limit : '',
      overage_limit_rupees: shop.overage_limit_rupees !== null && shop.overage_limit_rupees !== undefined ? shop.overage_limit_rupees : '300',
      overage_rate: ent.overage_rate !== null && ent.overage_rate !== undefined ? ent.overage_rate : '0.30'
    })
  }

  const onProductSelectChange = (newProd) => {
    if (!editModal.shop) return
    const ent = (editModal.shop.entitlements || []).find(e => e.product === newProd) || {}
    setEditModal(prev => ({
      ...prev,
      product: newProd,
      plan: ent.plan_tier || ent.plan || prev.plan,
      overage_rate: ent.overage_rate !== null && ent.overage_rate !== undefined ? ent.overage_rate : '0.30'
    }))
  }

  const savePlanAndLimits = async (e) => {
    e.preventDefault()
    if (!editModal.shop) return
    setUpdatingId(editModal.shop.id)

    const r = await post('/api/admin/plan', {
      shop_id: editModal.shop.id,
      product: editModal.product,
      plan: editModal.plan,
      custom_order_limit: editModal.custom_order_limit,
      overage_limit_rupees: editModal.overage_limit_rupees,
      overage_rate: editModal.overage_rate
    })

    setUpdatingId(null)
    if (r.ok) {
      setMsg(`Updated ${editModal.shop.name}: Plan [${editModal.plan.toUpperCase()}], Limit [${editModal.custom_order_limit || 'Default'}], Overage [₹${editModal.overage_rate}/order]`)
      setEditModal({ open: false, shop: null, plan: 'free', product: 'orders', custom_order_limit: '', overage_limit_rupees: '300', overage_rate: '0.30' })
      reloadData()
    } else {
      setMsg(r.error || 'Failed to update plan/limits')
    }
  }

  // Quick switch plan from dropdown directly
  const quickSwitchPlan = async (shop, newPlan) => {
    const curPlan = shop.plan || 'free'
    if (curPlan === newPlan) return
    if (!window.confirm(`Switch ${shop.name} from ${curPlan.toUpperCase()} to ${newPlan.toUpperCase()}?`)) return

    setUpdatingId(shop.id)
    const r = await post('/api/admin/plan', {
      shop_id: shop.id,
      product: shop.signup_product || 'orders',
      plan: newPlan
    })
    setUpdatingId(null)
    if (r.ok) {
      setMsg(`Plan switched to ${newPlan.toUpperCase()} for ${shop.name}`)
      reloadData()
    } else {
      setMsg(r.error || 'Could not update plan')
    }
  }

  // Map of shop metrics from metricsData
  const shopMetricsMap = useMemo(() => {
    const map = {}
    if (!metricsData?.all_metrics) return map
    metricsData.all_metrics.forEach(m => {
      if (!map[m.shop_id]) {
        map[m.shop_id] = { orders: 0, revenue: 0, overage: 0 }
      }
      map[m.shop_id].orders += Number(m.orders_created) || 0
      map[m.shop_id].revenue += Number(m.gross_revenue) || 0
      map[m.shop_id].overage += Number(m.overage_amount) || 0
    })
    return map
  }, [metricsData])

  // Filtered shops for the Table view
  const filteredShops = useMemo(() => {
    if (!allShops) return []
    return allShops.filter(s => {
      if (statusFilter !== 'all' && s.status !== statusFilter) return false
      if (productFilter !== 'all') {
        const hasProd = s.signup_product === productFilter || (s.entitlements || []).some(e => e.product === productFilter)
        if (!hasProd) return false
      }
      if (planFilter !== 'all') {
        const curPlan = s.plan || 'free'
        const hasEntPlan = (s.entitlements || []).some(e => (e.plan_tier || e.plan) === planFilter)
        if (curPlan !== planFilter && !hasEntPlan) return false
      }
      if (search.trim()) {
        const q = search.toLowerCase()
        const matchName = (s.name || '').toLowerCase().includes(q)
        const matchOwner = (s.owner_name || '').toLowerCase().includes(q)
        const matchCity = (s.city || '').toLowerCase().includes(q)
        const matchEmail = (s.email || '').toLowerCase().includes(q)
        const matchMobile = (s.mobile || '').includes(q)
        if (!matchName && !matchOwner && !matchCity && !matchEmail && !matchMobile) return false
      }
      return true
    })
  }, [allShops, search, statusFilter, productFilter, planFilter])

  // Analytics aggregations
  const analytics = useMemo(() => {
    if (!allShops) return null
    const total = allShops.length
    const approved = allShops.filter(s => s.status === 'approved').length
    const suspended = allShops.filter(s => s.status === 'suspended').length
    const pending = allShops.filter(s => s.status === 'pending_review').length
    const rejected = allShops.filter(s => s.status === 'rejected').length

    // Product breakdown across all entitlements
    const products = { billing: 0, expenses: 0, orders: 0, cafe: 0 }
    allShops.forEach(s => {
      const activeProducts = new Set()
      if (s.signup_product) activeProducts.add(s.signup_product)
      ;(s.entitlements || []).forEach(e => { if (e.product) activeProducts.add(e.product) })
      activeProducts.forEach(p => {
        products[p] = (products[p] || 0) + 1
      })
    })

    // Plan breakdown
    const plans = { free: 0, basic: 0, pro: 0 }
    allShops.forEach(s => {
      const p = s.plan || 'free'
      plans[p] = (plans[p] || 0) + 1
    })

    // City breakdown (top 8)
    const cityMap = {}
    allShops.forEach(s => {
      const c = (s.city || 'Not specified').trim()
      const formatted = c.charAt(0).toUpperCase() + c.slice(1).toLowerCase()
      cityMap[formatted] = (cityMap[formatted] || 0) + 1
    })
    const topCities = Object.entries(cityMap)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8)

    // Growth: last 7 days vs 30 days
    const now = Date.now()
    const ms7d = 7 * 86400000
    const ms30d = 30 * 86400000
    const last7d = allShops.filter(s => now - new Date(s.created_at).getTime() < ms7d).length
    const last30d = allShops.filter(s => now - new Date(s.created_at).getTime() < ms30d).length

    return { total, approved, suspended, pending, rejected, products, plans, topCities, last7d, last30d }
  }, [allShops])

  if (stage !== 'in') {
    return (
      <form className="box login" onSubmit={login}>
        <h2>Stellar <span style={{ color: 'var(--teal-d)' }}>Forge</span> Admin</h2>
        <input type="email" placeholder="Email" value={f.email} onChange={set('email')} required />
        <input type="password" placeholder="Password" value={f.password} onChange={set('password')} required />
        <button>Sign in</button>
        {msg && <p className="err">{msg}</p>}
      </form>
    )
  }

  return (
    <>
      <header>
        <div className="brand"><b>Stellar <span>Forge</span> Admin</b></div>
        <div className="nav-links">
          <button className={`nav-btn ${page === 'table' ? 'active' : ''}`} onClick={() => setPage('table')}>All Shops</button>
          <button className={`nav-btn ${page === 'review' ? 'active' : ''}`} onClick={() => setPage('review')}>Review Queue</button>
          <button className={`nav-btn ${page === 'analytics' ? 'active' : ''}`} onClick={() => setPage('analytics')}>Analytics</button>
          <button className="alt sm" onClick={() => { document.cookie = 'sf_admin=; Max-Age=0; Path=/'; setStage('password') }}>Sign out</button>
        </div>
      </header>

      <main>
        {msg && (
          <div className="box" style={{ padding: '10px 16px', background: 'var(--teal-light)', borderColor: 'var(--teal)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span>{msg}</span>
            <button className="sm alt" onClick={() => setMsg('')} style={{ margin: 0 }}>Dismiss</button>
          </div>
        )}

        {/* 1. ALL ONBOARDED SHOPS TABLE PAGE */}
        {page === 'table' && (
          <section>
            {/* Top Revenue & Orders quick highlight */}
            {metricsData?.totals && (
              <div className="analytics-grid" style={{ marginBottom: 16 }}>
                <div className="stat-card" style={{ padding: '14px 18px' }}>
                  <span className="label">Total Orders Processed</span>
                  <span className="value" style={{ fontSize: '1.6rem' }}>
                    {metricsData.totals.all_time.orders_created.toLocaleString()}
                  </span>
                  <span className="subtext">
                    This month: {metricsData.totals.current_month.orders_created.toLocaleString()}
                  </span>
                </div>
                <div className="stat-card" style={{ padding: '14px 18px' }}>
                  <span className="label">Total Gross Revenue</span>
                  <span className="value" style={{ fontSize: '1.6rem', color: 'var(--teal-d)' }}>
                    ₹{Math.round(metricsData.totals.all_time.gross_revenue).toLocaleString()}
                  </span>
                  <span className="subtext">
                    This month: ₹{Math.round(metricsData.totals.current_month.gross_revenue).toLocaleString()}
                  </span>
                </div>
                <div className="stat-card" style={{ padding: '14px 18px' }}>
                  <span className="label">Collected Revenue</span>
                  <span className="value" style={{ fontSize: '1.6rem', color: 'var(--success)' }}>
                    ₹{Math.round(metricsData.totals.all_time.collected_revenue).toLocaleString()}
                  </span>
                  <span className="subtext">
                    Outstanding: ₹{Math.round(metricsData.totals.all_time.outstanding).toLocaleString()}
                  </span>
                </div>
                <div className="stat-card" style={{ padding: '14px 18px' }}>
                  <span className="label">Platform Overage Billed</span>
                  <span className="value" style={{ fontSize: '1.6rem', color: 'var(--purple)' }}>
                    ₹{Math.round(metricsData.totals.all_time.overage_amount).toLocaleString()}
                  </span>
                  <span className="subtext">
                    This month: ₹{Math.round(metricsData.totals.current_month.overage_amount).toLocaleString()}
                  </span>
                </div>
              </div>
            )}

            <div className="table-toolbar">
              <div className="table-filters">
                <input
                  type="search"
                  placeholder="Search shop, owner, city, email..."
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
                <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
                  <option value="all">All Statuses</option>
                  <option value="approved">Approved</option>
                  <option value="suspended">Suspended</option>
                  <option value="pending_review">Pending Review</option>
                  <option value="rejected">Rejected</option>
                </select>
                <select value={productFilter} onChange={(e) => setProductFilter(e.target.value)}>
                  <option value="all">All Products</option>
                  <option value="orders">Orders</option>
                  <option value="billing">Billing</option>
                  <option value="expenses">Expense Tracker</option>
                  <option value="cafe">Cafe QR</option>
                </select>
                <select value={planFilter} onChange={(e) => setPlanFilter(e.target.value)}>
                  <option value="all">All Plans</option>
                  <option value="free">Free</option>
                  <option value="basic">Basic</option>
                  <option value="pro">Pro</option>
                </select>
              </div>
              <div>
                <button className="alt sm" onClick={reloadData}>↻ Refresh</button>
              </div>
            </div>

            <div className="table-container">
              {allShops === null ? (
                <div style={{ padding: '24px', textAlign: 'center' }}>Loading shops…</div>
              ) : filteredShops.length === 0 ? (
                <div style={{ padding: '24px', textAlign: 'center' }} className="muted">No shops match the selected filters.</div>
              ) : (
                <table className="shops-table">
                  <thead>
                    <tr>
                      <th>Shop & Owner</th>
                      <th>City</th>
                      <th>Contact</th>
                      <th>Products & Entitlements</th>
                      <th>Plan / Tier</th>
                      <th>Order Limit & Price</th>
                      <th>Total Orders</th>
                      <th>Total Revenue</th>
                      <th>Status</th>
                      <th>Joined</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredShops.map((s) => {
                      const curPlan = s.plan || 'free'
                      const isBusy = updatingId === s.id
                      const m = shopMetricsMap[s.id] || { orders: 0, revenue: 0, overage: 0 }
                      const entitlements = s.entitlements || []

                      return (
                        <tr key={s.id}>
                          <td>
                            <b>{s.name}</b>
                            <div className="muted">{s.owner_name} {s.business_type ? `· ${s.business_type}` : ''}</div>
                          </td>
                          <td>{s.city || '—'}</td>
                          <td>
                            <div><a href={`tel:${s.mobile}`}>{s.mobile}</a></div>
                            <div>
                              <a href={wa(s.whatsapp)} target="_blank" rel="noreferrer" style={{ fontSize: '0.8rem' }}>
                                WA: {s.whatsapp}
                              </a>
                            </div>
                            <div className="muted" style={{ fontSize: '0.75rem' }}>{s.email}</div>
                          </td>
                          <td>
                            <div className="prod-tag-list">
                              {entitlements.length > 0 ? (
                                entitlements.map((e, idx) => (
                                  <div key={idx} className="prod-tag-row">
                                    <span className={`badge badge-${e.product}`}>
                                      {PRODUCT_LABELS[e.product] || e.product}
                                    </span>
                                    <span className="muted">
                                      ₹{e.overage_rate !== null && e.overage_rate !== undefined ? e.overage_rate : '0.30'}/extra
                                    </span>
                                  </div>
                                ))
                              ) : (
                                <span className={`badge badge-${s.signup_product || 'orders'}`}>
                                  {PRODUCT_LABELS[s.signup_product] || s.signup_product || 'Orders'}
                                </span>
                              )}
                            </div>
                          </td>
                          <td>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                              <select
                                style={{ padding: '3px 6px', fontSize: '0.78rem', width: 'auto', margin: 0 }}
                                value={curPlan}
                                disabled={isBusy}
                                onChange={(e) => quickSwitchPlan(s, e.target.value)}
                              >
                                <option value="free">Free</option>
                                <option value="basic">Basic</option>
                                <option value="pro">Pro</option>
                              </select>
                              <span className={`badge badge-${curPlan}`}>
                                {curPlan.toUpperCase()}
                              </span>
                            </div>
                          </td>
                          <td>
                            <div>
                              <b>{s.custom_order_limit !== null && s.custom_order_limit !== undefined ? s.custom_order_limit : (curPlan === 'pro' ? 'Unlimited' : (curPlan === 'basic' ? '300' : '100'))}</b>
                              <span className="muted" style={{ fontSize: '0.75rem' }}> free</span>
                            </div>
                            <div className="muted" style={{ fontSize: '0.75rem' }}>
                              Cap: ₹{s.overage_limit_rupees || s.monthly_overage_limit || 300}
                            </div>
                          </td>
                          <td>
                            <b>{m.orders.toLocaleString()}</b>
                          </td>
                          <td>
                            <b style={{ color: 'var(--teal-d)' }}>₹{Math.round(m.revenue).toLocaleString()}</b>
                            {m.overage > 0 && (
                              <div className="muted" style={{ fontSize: '0.72rem', color: 'var(--purple)' }}>
                                +₹{Math.round(m.overage)} fee
                              </div>
                            )}
                          </td>
                          <td>
                            <span className={`badge badge-${s.status}`}>
                              {s.status.replace('_', ' ')}
                            </span>
                          </td>
                          <td style={{ fontSize: '0.78rem', whiteSpace: 'nowrap' }}>
                            {new Date(s.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' })}
                          </td>
                          <td>
                            <div className="actions-cell">
                              <button
                                className="alt sm"
                                disabled={isBusy}
                                onClick={() => openPlanModal(s)}
                                title="Edit free order quota and overage price"
                              >
                                ⚙ Plan & Quota
                              </button>
                              {s.status === 'approved' && (
                                <button
                                  className="bad sm"
                                  disabled={isBusy}
                                  onClick={() => act(s.id, 'suspend')}
                                  title="Suspend this shop's access"
                                >
                                  Suspend
                                </button>
                              )}
                              {s.status === 'suspended' && (
                                <button
                                  className="sm"
                                  disabled={isBusy}
                                  onClick={() => act(s.id, 'reinstate')}
                                  title="Restore this account back to normal (approved)"
                                >
                                  Reinstate
                                </button>
                              )}
                              {s.status === 'pending_review' && (
                                <>
                                  <button className="sm" disabled={isBusy} onClick={() => act(s.id, 'approve')}>Approve</button>
                                  <button className="bad sm" disabled={isBusy} onClick={() => act(s.id, 'reject')}>Reject</button>
                                </>
                              )}
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              )}
            </div>
            <p className="muted" style={{ marginTop: 8 }}>
              Showing {filteredShops.length} of {allShops ? allShops.length : 0} shops.
            </p>
          </section>
        )}

        {/* 2. EXISTING REVIEW FOR APPROVAL PAGE */}
        {page === 'review' && (
          <section>
            <div className="tabs">
              {REVIEW_TABS.map(([k, l]) => (
                <button key={k} className={reviewTab === k ? 'on' : ''} onClick={() => setReviewTab(k)}>{l}</button>
              ))}
            </div>
            {shops === null ? (
              <p>Loading…</p>
            ) : shops.length === 0 ? (
              <p className="muted">No shops in this review category.</p>
            ) : (
              shops.map((s) => (
                <div className="box" key={s.id}>
                  <b>{s.name}</b> · {s.owner_name} · <span className="muted">{PRODUCT_LABELS[s.signup_product] || 'Orders'}</span><br />
                  <span className="muted">{s.city || '—'} · {s.business_type || '—'} · {s.email}</span><br />
                  Mobile {s.mobile} · <a href={wa(s.whatsapp)} target="_blank" rel="noreferrer">WhatsApp {s.whatsapp}</a>
                  {s.ref_link && <> · <a href={s.ref_link} target="_blank" rel="noreferrer">Link</a></>}
                  <div className="muted">
                    Signed up {new Date(s.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })} IST
                    {s.review_due_at && s.status === 'pending_review' && (
                      <> · review by {new Date(s.review_due_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</>
                    )}
                  </div>
                  <div style={{ marginTop: 10 }}>
                    {s.status === 'pending_review' && (
                      <>
                        <button onClick={() => act(s.id, 'approve')}>Approve</button>
                        <button className="bad" onClick={() => act(s.id, 'reject')}>Reject</button>
                      </>
                    )}
                    {s.status === 'approved' && <button className="bad" onClick={() => act(s.id, 'suspend')}>Suspend</button>}
                    {s.status === 'suspended' && <button onClick={() => act(s.id, 'reinstate')}>Reinstate</button>}
                  </div>
                </div>
              ))
            )}
          </section>
        )}

        {/* 3. ANALYTICS PAGE */}
        {page === 'analytics' && analytics && (
          <section>
            <div className="analytics-grid">
              <div className="stat-card">
                <span className="label">Total Onboarded Shops</span>
                <span className="value">{analytics.total}</span>
                <span className="subtext">All time registered</span>
              </div>
              <div className="stat-card">
                <span className="label">Total Orders Handled</span>
                <span className="value" style={{ color: 'var(--ink)' }}>
                  {metricsData?.totals?.all_time?.orders_created?.toLocaleString() || 0}
                </span>
                <span className="subtext">
                  Delivered: {metricsData?.totals?.all_time?.orders_delivered?.toLocaleString() || 0}
                </span>
              </div>
              <div className="stat-card">
                <span className="label">Total Platform Revenue</span>
                <span className="value" style={{ color: 'var(--teal-d)' }}>
                  ₹{Math.round(metricsData?.totals?.all_time?.gross_revenue || 0).toLocaleString()}
                </span>
                <span className="subtext">
                  Collected: ₹{Math.round(metricsData?.totals?.all_time?.collected_revenue || 0).toLocaleString()}
                </span>
              </div>
              <div className="stat-card">
                <span className="label">Active / Approved</span>
                <span className="value" style={{ color: 'var(--success)' }}>{analytics.approved}</span>
                <span className="subtext">{analytics.total ? Math.round((analytics.approved / analytics.total) * 100) : 0}% of total</span>
              </div>
            </div>

            <div className="analytics-sections">
              {/* Product Distribution */}
              <div className="chart-box">
                <h3>Multi-Product Distribution</h3>
                {[
                  { key: 'orders', label: 'Orders App', count: analytics.products.orders || 0, color: 'purple' },
                  { key: 'billing', label: 'Billing App', count: analytics.products.billing || 0, color: 'blue' },
                  { key: 'expenses', label: 'Expense Tracker', count: analytics.products.expenses || 0, color: 'warning' },
                  { key: 'cafe', label: 'Cafe QR', count: analytics.products.cafe || 0, color: 'danger' }
                ].map((item) => {
                  const pct = analytics.total ? Math.round((item.count / analytics.total) * 100) : 0
                  return (
                    <div className="bar-row" key={item.key}>
                      <span className="bar-label">{item.label}</span>
                      <div className="bar-track">
                        <div className={`bar-fill ${item.color}`} style={{ width: `${pct}%` }}></div>
                      </div>
                      <span className="bar-count">{item.count}</span>
                    </div>
                  )
                })}
              </div>

              {/* Plan Distribution */}
              <div className="chart-box">
                <h3>Plan / Tier Breakdown</h3>
                {[
                  { label: 'Free Tier', count: analytics.plans.free, color: '' },
                  { label: 'Basic Tier', count: analytics.plans.basic, color: 'blue' },
                  { label: 'Pro Tier', count: analytics.plans.pro, color: 'purple' }
                ].map((item) => {
                  const pct = analytics.total ? Math.round((item.count / analytics.total) * 100) : 0
                  return (
                    <div className="bar-row" key={item.label}>
                      <span className="bar-label">{item.label}</span>
                      <div className="bar-track">
                        <div className={`bar-fill ${item.color}`} style={{ width: `${pct}%` }}></div>
                      </div>
                      <span className="bar-count">{item.count} ({pct}%)</span>
                    </div>
                  )
                })}
              </div>

              {/* City Distribution */}
              <div className="chart-box">
                <h3>Top Cities</h3>
                {analytics.topCities.length === 0 ? (
                  <p className="muted">No city data available yet.</p>
                ) : (
                  analytics.topCities.map(([city, count]) => {
                    const pct = analytics.total ? Math.round((count / analytics.total) * 100) : 0
                    return (
                      <div className="bar-row" key={city}>
                        <span className="bar-label" title={city}>{city}</span>
                        <div className="bar-track">
                          <div className="bar-fill" style={{ width: `${pct}%` }}></div>
                        </div>
                        <span className="bar-count">{count}</span>
                      </div>
                    )
                  })
                )}
              </div>

              {/* Revenue & Growth Overview */}
              <div className="chart-box">
                <h3>Revenue & Usage Overview</h3>
                <div style={{ display: 'flex', flexDirection: 'column', gap: '12px', marginTop: '6px' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: '1px solid var(--border)', paddingBottom: '8px' }}>
                    <span>Gross Revenue (All Time)</span>
                    <b>₹{Math.round(metricsData?.totals?.all_time?.gross_revenue || 0).toLocaleString()}</b>
                  </div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: '1px solid var(--border)', paddingBottom: '8px' }}>
                    <span>This Month's Revenue</span>
                    <b style={{ color: 'var(--teal-d)' }}>₹{Math.round(metricsData?.totals?.current_month?.gross_revenue || 0).toLocaleString()}</b>
                  </div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: '1px solid var(--border)', paddingBottom: '8px' }}>
                    <span>Platform Overage Fees</span>
                    <b style={{ color: 'var(--purple)' }}>₹{Math.round(metricsData?.totals?.all_time?.overage_amount || 0).toLocaleString()}</b>
                  </div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: '1px solid var(--border)', paddingBottom: '8px' }}>
                    <span>New Shops (Last 30 Days)</span>
                    <b>+{analytics.last30d} shops</b>
                  </div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <span>Suspended Accounts</span>
                    <span className="badge badge-suspended">{analytics.suspended}</span>
                  </div>
                </div>
              </div>
            </div>
          </section>
        )}
      </main>

      {/* PLAN, QUOTA & PRICE MODAL */}
      {editModal.open && editModal.shop && (
        <div className="modal-backdrop" onClick={() => setEditModal(prev => ({ ...prev, open: false }))}>
          <div className="modal-card" onClick={(e) => e.stopPropagation()}>
            <h3>Manage Plan, Price & Quota: {editModal.shop.name}</h3>

            <form onSubmit={savePlanAndLimits}>
              <div className="form-group">
                <label>Target Product</label>
                <select
                  value={editModal.product}
                  onChange={(e) => onProductSelectChange(e.target.value)}
                >
                  <option value="orders">Orders</option>
                  <option value="billing">Billing</option>
                  <option value="expenses">Expense Tracker</option>
                  <option value="cafe">Cafe QR</option>
                </select>
              </div>

              <div className="form-group">
                <label>Plan / Tier</label>
                <select
                  value={editModal.plan}
                  onChange={(e) => setEditModal(prev => ({ ...prev, plan: e.target.value }))}
                >
                  <option value="free">Free (Default 100 free orders)</option>
                  <option value="basic">Basic (Default 300 free orders)</option>
                  <option value="pro">Pro (Unlimited / Custom)</option>
                </select>
              </div>

              <div className="form-group">
                <label>Custom Free Order Quota (custom_order_limit)</label>
                <input
                  type="number"
                  placeholder="e.g. 150, 500 (blank = plan default)"
                  value={editModal.custom_order_limit}
                  onChange={(e) => setEditModal(prev => ({ ...prev, custom_order_limit: e.target.value }))}
                />
                <span className="muted" style={{ fontSize: '0.75rem' }}>
                  Overrides the plan default quota. Leave blank to use plan default (100 for Free, 300 for Basic).
                </span>
              </div>

              <div className="form-group">
                <label>Custom Price per Extra Order (overage_rate)</label>
                <input
                  type="number"
                  step="0.01"
                  placeholder="Default: 0.30"
                  value={editModal.overage_rate}
                  onChange={(e) => setEditModal(prev => ({ ...prev, overage_rate: e.target.value }))}
                />
                <span className="muted" style={{ fontSize: '0.75rem' }}>
                  Charged in rupees per extra order exceeding the free quota (from 0015 migration).
                </span>
              </div>

              <div className="form-group">
                <label>Monthly Overage Limit Cap (₹)</label>
                <input
                  type="number"
                  placeholder="Default: 300"
                  value={editModal.overage_limit_rupees}
                  onChange={(e) => setEditModal(prev => ({ ...prev, overage_limit_rupees: e.target.value }))}
                />
                <span className="muted" style={{ fontSize: '0.75rem' }}>
                  Safety cap on overage charges per month in rupees (e.g. 100, 300, 500).
                </span>
              </div>

              <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 18 }}>
                <button
                  type="button"
                  className="alt"
                  onClick={() => setEditModal(prev => ({ ...prev, open: false }))}
                >
                  Cancel
                </button>
                <button type="submit" disabled={updatingId === editModal.shop.id}>
                  {updatingId === editModal.shop.id ? 'Saving…' : 'Save Changes'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      <footer>Powered by Stellar Forge</footer>
    </>
  )
}
