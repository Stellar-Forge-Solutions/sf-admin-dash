// Sends transactional emails using Brevo (formerly Sendinblue) v3 REST API.
// Secrets: BREVO_API_KEY, BREVO_SENDER_EMAIL

export async function sendMail({ to, subject, html }) {
  const apiKey = process.env.BREVO_API_KEY
  const senderEmail = process.env.BREVO_SENDER_EMAIL

  if (!apiKey) {
    throw new Error('BREVO_API_KEY is not set')
  }
  if (!senderEmail) {
    throw new Error('BREVO_SENDER_EMAIL is not set')
  }

  // Normalize recipients to array of { email: string, name?: string }
  const recipientsList = (Array.isArray(to) ? to : [to]).map(recipient => {
    if (typeof recipient === 'string') {
      return { email: recipient.trim() }
    }
    return recipient
  })

  const payload = {
    sender: {
      name: 'Stellar Forge Team',
      email: senderEmail.trim()
    },
    to: recipientsList,
    subject: String(subject || ''),
    htmlContent: String(html || '')
  }

  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: {
      'accept': 'application/json',
      'api-key': apiKey,
      'content-type': 'application/json'
    },
    body: JSON.stringify(payload)
  })

  if (!res.ok) {
    const errorBody = await res.json().catch(() => ({}))
    throw new Error(`Brevo send failed (${res.status}): ${errorBody.message || res.statusText}`)
  }

  return await res.json().catch(() => ({ ok: true }))
}
