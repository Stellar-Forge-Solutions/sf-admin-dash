import { useEffect, useState } from 'react'

const post = async (url, body) => {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  return { ok: r.ok, status: r.status, ...(await r.json().catch(() => ({}))) }
}
const wa = (n) => { const d = String(n || '').replace(/\D/g, ''); return 'https://wa.me/' + (d.length === 10 ? '91' + d : d) }
const TABS = [['pending_review', 'Pending'], ['approved', 'Approved'], ['suspended', 'Suspended'], ['rejected', 'Rejected']]

export default function App() {
  const [stage, setStage] = useState('password') // password | code | in
  const [f, setF] = useState({ email: '', password: '', code: '' })
  const [msg, setMsg] = useState('')
  const [tab, setTab] = useState('pending_review')
  const [shops, setShops] = useState(null)
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })

  const load = async (t = tab) => {
    const r = await fetch('/api/admin/shops?status=' + t)
    if (r.status === 401) return setStage('password')
    setShops((await r.json()).shops || []); setStage('in')
  }
  useEffect(() => { load() }, [])
  useEffect(() => { if (stage !== 'in') return; load(); const t = setInterval(load, 60000); return () => clearInterval(t) }, [tab, stage])

  const login = async (e) => {
    e.preventDefault(); setMsg('')
    const r = await post('/api/admin/login', stage === 'password' ? { step: 'password', email: f.email, password: f.password } : { step: 'code', email: f.email, code: f.code })
    if (!r.ok) return setMsg(r.error || 'Invalid details')
    if (stage === 'password') { setStage('code'); setMsg('A 6-digit code was sent to your email.') } else load()
  }
  const act = async (id, action) => {
    const note = action === 'reject' || action === 'suspend' ? prompt('Note for the shop (optional)') : ''
    if (note === null) return
    const r = await post('/api/admin/review', { id, action, note })
    setMsg(r.ok ? (r.mailed === false ? 'Done, but the email could not be sent.' : 'Done.') : r.error || 'Failed'); load()
  }

  if (stage !== 'in') return (
    <form className="box login" onSubmit={login}>
      <h2>Stellar <span style={{ color: 'var(--teal-d)' }}>Forge</span> Admin</h2>
      <input type="email" placeholder="Email" value={f.email} onChange={set('email')} required disabled={stage === 'code'} />
      {stage === 'password'
        ? <input type="password" placeholder="Password" value={f.password} onChange={set('password')} required />
        : <input inputMode="numeric" maxLength={6} placeholder="6-digit code from email" value={f.code} onChange={set('code')} required autoFocus />}
      <button>{stage === 'password' ? 'Send me a code' : 'Sign in'}</button>
      <p className={msg.startsWith('A 6') ? 'muted' : 'err'}>{msg}</p>
    </form>)

  return (<>
    <header><b>Stellar <span>Forge</span> Admin</b>
      <button className="alt" onClick={() => { document.cookie = 'sf_admin=; Max-Age=0; Path=/'; setStage('password') }}>Sign out</button></header>
    <main>
      <div className="tabs">{TABS.map(([k, l]) => <button key={k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>{l}</button>)}</div>
      {msg && <p className="muted">{msg}</p>}
      {shops === null ? <p>Loading…</p> : shops.length === 0 ? <p className="muted">No shops here.</p> : shops.map((s) => (
        <div className="box" key={s.id}>
          <b>{s.name}</b> · {s.owner_name} · <span className="muted">{s.signup_product === 'expenses' ? 'Expense Tracker' : 'Billing'}</span><br />
          <span className="muted">{s.city || '—'} · {s.business_type || '—'} · {s.email}</span><br />
          Mobile {s.mobile} · <a href={wa(s.whatsapp)} target="_blank" rel="noreferrer">WhatsApp {s.whatsapp}</a>
          {s.ref_link && <> · <a href={s.ref_link} target="_blank" rel="noreferrer">Link</a></>}
          <div className="muted">Signed up {new Date(s.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })} IST
            {s.review_due_at && s.status === 'pending_review' && <> · review by {new Date(s.review_due_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</>}</div>
          {s.status === 'pending_review' && <><button onClick={() => act(s.id, 'approve')}>Approve</button><button className="bad" onClick={() => act(s.id, 'reject')}>Reject</button></>}
          {s.status === 'approved' && <button className="bad" onClick={() => act(s.id, 'suspend')}>Suspend</button>}
          {s.status === 'suspended' && <button onClick={() => act(s.id, 'reinstate')}>Reinstate</button>}
        </div>))}
    </main>
    <footer>Powered by Stellar Forge</footer>
  </>)
}
