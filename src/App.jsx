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
  orders: 'Orders'
}

export default function App() {
  const [stage, setStage] = useState('password') // password | code | in
  const [f, setF] = useState({ email: '', password: '', code: '' })
  const [msg, setMsg] = useState('')
  const [page, setPage] = useState('table') // 'review' | 'table' | 'analytics'
  const [reviewTab, setReviewTab] = useState('pending_review')
  const [shops, setShops] = useState(null)
  const [allShops, setAllShops] = useState(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState('all')
  const [productFilter, setProductFilter] = useState('all')
  const [planFilter, setPlanFilter] = useState('all')
  const [updatingId, setUpdatingId] = useState(null)

  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })

  // Load reviews list (for review queue)
  const loadReviews = async (t = reviewTab) => {
    const r = await fetch('/api/admin/shops?status=' + t)
    if (r.status === 401) return setStage('password')
    const json = await r.json()
    setShops(json.shops || [])
    setStage('in')
  }

  // Load all shops (for table & analytics)
  const loadAllShops = async () => {
    const r = await fetch('/api/admin/shops?status=all')
    if (r.status === 401) return setStage('password')
    const json = await r.json()
    setAllShops(json.shops || [])
    setStage('in')
  }

  const reloadData = () => {
    loadReviews(reviewTab)
    loadAllShops()
  }

  useEffect(() => {
    reloadData()
  }, [])

  useEffect(() => {
    if (stage !== 'in') return
    if (page === 'review') loadReviews(reviewTab)
    else loadAllShops()
    const t = setInterval(() => {
      if (page === 'review') loadReviews(reviewTab)
      else loadAllShops()
    }, 60000)
    return () => clearInterval(t)
  }, [page, reviewTab, stage])

  const login = async (e) => {
    e.preventDefault(); setMsg('')
    const r = await post('/api/admin/login', stage === 'password' ? { step: 'password', email: f.email, password: f.password } : { step: 'code', email: f.email, code: f.code })
    if (!r.ok) return setMsg(r.error || 'Invalid details')
    if (stage === 'password') {
      setStage('code')
      setMsg('A 6-digit code was sent to your email.')
    } else {
      reloadData()
    }
  }

  const act = async (id, action) => {
    const note = action === 'reject' || action === 'suspend' ? prompt('Note for the shop (optional):') : ''
    if (note === null) return // User cancelled prompt
    setUpdatingId(id)
    const r = await post('/api/admin/review', { id, action, note })
    setUpdatingId(null)
    setMsg(r.ok ? (r.mailed === false ? 'Action done, but email could not be sent.' : 'Success.') : (r.error || 'Action failed'))
    reloadData()
  }

  const switchPlan = async (shop, newPlan) => {
    const currentPlan = getShopPlan(shop)
    if (currentPlan === newPlan) return
    const conf = window.confirm(`Change plan for "${shop.name}" from ${currentPlan.toUpperCase()} to ${newPlan.toUpperCase()}?`)
    if (!conf) return

    setUpdatingId(shop.id)
    const r = await post('/api/admin/plan', {
      shop_id: shop.id,
      product: shop.signup_product || 'billing',
      plan: newPlan
    })
    setUpdatingId(null)

    if (r.ok) {
      setMsg(`Plan updated to ${newPlan.toUpperCase()} for ${shop.name}`)
      reloadData()
    } else {
      setMsg(r.error || 'Could not update plan')
    }
  }

  const getShopPlan = (shop) => {
    if (!shop.entitlements || !shop.entitlements.length) return 'basic'
    const ent = shop.entitlements.find(e => e.product === shop.signup_product) || shop.entitlements[0]
    return ent?.plan || 'basic'
  }

  // Filtered shops for the Table view
  const filteredShops = useMemo(() => {
    if (!allShops) return []
    return allShops.filter(s => {
      if (statusFilter !== 'all' && s.status !== statusFilter) return false
      if (productFilter !== 'all' && s.signup_product !== productFilter) return false
      if (planFilter !== 'all' && getShopPlan(s) !== planFilter) return false
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

    // Product breakdown
    const products = { billing: 0, expenses: 0, orders: 0 }
    allShops.forEach(s => {
      const p = s.signup_product || 'billing'
      products[p] = (products[p] || 0) + 1
    })

    // Plan breakdown
    let basicCount = 0
    let proCount = 0
    allShops.forEach(s => {
      const pl = getShopPlan(s)
      if (pl === 'pro') proCount++
      else basicCount++
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

    return { total, approved, suspended, pending, rejected, products, basicCount, proCount, topCities, last7d, last30d }
  }, [allShops])

  if (stage !== 'in') {
    return (
      <form className="box login" onSubmit={login}>
        <h2>Stellar <span style={{ color: 'var(--teal-d)' }}>Forge</span> Admin</h2>
        <input type="email" placeholder="Email" value={f.email} onChange={set('email')} required disabled={stage === 'code'} />
        {stage === 'password'
          ? <input type="password" placeholder="Password" value={f.password} onChange={set('password')} required />
          : <input inputMode="numeric" maxLength={6} placeholder="6-digit code from email" value={f.code} onChange={set('code')} required autoFocus />}
        <button>{stage === 'password' ? 'Send me a code' : 'Sign in'}</button>
        {msg && <p className={msg.startsWith('A 6') ? 'muted' : 'err'}>{msg}</p>}
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
                  <option value="billing">Billing</option>
                  <option value="expenses">Expense Tracker</option>
                  <option value="orders">Orders</option>
                </select>
                <select value={planFilter} onChange={(e) => setPlanFilter(e.target.value)}>
                  <option value="all">All Plans</option>
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
                      <th>Product</th>
                      <th>Plan / Tier</th>
                      <th>Status</th>
                      <th>Joined Date</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredShops.map((s) => {
                      const currentPlan = getShopPlan(s)
                      const isBusy = updatingId === s.id
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
                              <a href={wa(s.whatsapp)} target="_blank" rel="noreferrer" style={{ fontSize: '0.82rem' }}>
                                WA: {s.whatsapp}
                              </a>
                            </div>
                            <div className="muted" style={{ fontSize: '0.78rem' }}>{s.email}</div>
                          </td>
                          <td>
                            <span className={`badge badge-${s.signup_product || 'billing'}`}>
                              {PRODUCT_LABELS[s.signup_product] || s.signup_product || 'Billing'}
                            </span>
                          </td>
                          <td>
                            <div className="plan-switcher">
                              <select
                                className="plan-select"
                                value={currentPlan}
                                disabled={isBusy}
                                onChange={(e) => switchPlan(s, e.target.value)}
                              >
                                <option value="basic">Basic</option>
                                <option value="pro">Pro</option>
                              </select>
                              <span className={`badge badge-${currentPlan}`} style={{ marginLeft: 4 }}>
                                {currentPlan.toUpperCase()}
                              </span>
                            </div>
                          </td>
                          <td>
                            <span className={`badge badge-${s.status}`}>
                              {s.status.replace('_', ' ')}
                            </span>
                          </td>
                          <td style={{ fontSize: '0.82rem', whiteSpace: 'nowrap' }}>
                            {new Date(s.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' })}
                            <div className="muted">
                              {new Date(s.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}
                            </div>
                          </td>
                          <td>
                            <div className="actions-cell">
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
                              {s.ref_link && (
                                <a href={s.ref_link} target="_blank" rel="noreferrer" style={{ fontSize: '0.8rem', marginLeft: 4 }}>
                                  Link
                                </a>
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

        {/* 2. EXISTING REVIEW FOR APPROVAL PAGE (RETAINED AS IS) */}
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
                  <b>{s.name}</b> · {s.owner_name} · <span className="muted">{PRODUCT_LABELS[s.signup_product] || 'Billing'}</span><br />
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
                <span className="label">Active / Approved</span>
                <span className="value" style={{ color: 'var(--success)' }}>{analytics.approved}</span>
                <span className="subtext">{analytics.total ? Math.round((analytics.approved / analytics.total) * 100) : 0}% of total</span>
              </div>
              <div className="stat-card">
                <span className="label">Suspended</span>
                <span className="value" style={{ color: 'var(--danger)' }}>{analytics.suspended}</span>
                <span className="subtext">Temporarily inactive</span>
              </div>
              <div className="stat-card">
                <span className="label">Pending Review</span>
                <span className="value" style={{ color: 'var(--warning)' }}>{analytics.pending}</span>
                <span className="subtext">Awaiting admin review</span>
              </div>
            </div>

            <div className="analytics-sections">
              {/* Product Distribution */}
              <div className="chart-box">
                <h3>Product Breakdown</h3>
                {[
                  { key: 'billing', label: 'Billing App', count: analytics.products.billing || 0, color: '' },
                  { key: 'expenses', label: 'Expense Tracker', count: analytics.products.expenses || 0, color: 'warning' },
                  { key: 'orders', label: 'Orders', count: analytics.products.orders || 0, color: 'purple' }
                ].map((item) => {
                  const pct = analytics.total ? Math.round((item.count / analytics.total) * 100) : 0
                  return (
                    <div className="bar-row" key={item.key}>
                      <span className="bar-label">{item.label}</span>
                      <div className="bar-track">
                        <div className={`bar-fill ${item.color}`} style={{ width: `${pct}%` }}></div>
                      </div>
                      <span className="bar-count">{item.count} ({pct}%)</span>
                    </div>
                  )
                })}
              </div>

              {/* Plan Distribution */}
              <div className="chart-box">
                <h3>Plan / Tier Breakdown</h3>
                {[
                  { label: 'Basic Tier', count: analytics.basicCount, color: '' },
                  { label: 'Pro Tier', count: analytics.proCount, color: 'purple' }
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

              {/* Onboarding Growth */}
              <div className="chart-box">
                <h3>Onboarding Momentum</h3>
                <div style={{ display: 'flex', flexDirection: 'column', gap: '14px', marginTop: '10px' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: '1px solid var(--border)', paddingBottom: '8px' }}>
                    <span>Last 7 Days</span>
                    <b>+{analytics.last7d} shops</b>
                  </div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderBottom: '1px solid var(--border)', paddingBottom: '8px' }}>
                    <span>Last 30 Days</span>
                    <b>+{analytics.last30d} shops</b>
                  </div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <span>Rejected Requests</span>
                    <span className="muted">{analytics.rejected}</span>
                  </div>
                </div>
              </div>
            </div>
          </section>
        )}
      </main>

      <footer>Powered by Stellar Forge</footer>
    </>
  )
}
