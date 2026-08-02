// Stripe webhook: the ONLY place coins actually get credited.
// Never trust the browser's "payment succeeded" redirect — Stripe tells us here.

import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

// Stripe signs the raw request body, so Vercel must not parse it for us.
export const config = {
  api: { bodyParser: false }
};

function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).send('Method not allowed');
  }

  let event;
  try {
    const rawBody = await readRawBody(req);
    const signature = req.headers['stripe-signature'];
    event = stripe.webhooks.constructEvent(
      rawBody,
      signature,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    return res.status(400).send('Webhook signature verification failed');
  }

  if (event.type !== 'checkout.session.completed') {
    // Acknowledge anything we don't handle so Stripe stops retrying it.
    return res.status(200).send('Ignored');
  }

  const session = event.data.object;

  // Only credit fully-paid sessions.
  if (session.payment_status !== 'paid') {
    return res.status(200).send('Not paid yet');
  }

  const userId = session.metadata && session.metadata.user_id;
  const coins = parseInt(session.metadata && session.metadata.coins, 10);

  if (!userId || !Number.isFinite(coins) || coins <= 0) {
    console.error('Webhook missing usable metadata:', session.id);
    return res.status(200).send('Nothing to credit');
  }

  const supabase = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );

  try {
    // Idempotency: Stripe retries webhooks, so make sure one payment credits coins once.
    const { data: alreadyDone } = await supabase
      .from('coin_purchases')
      .select('id')
      .eq('stripe_session_id', session.id)
      .maybeSingle();

    if (alreadyDone) {
      return res.status(200).send('Already credited');
    }

    const { data: profile } = await supabase
      .from('profiles')
      .select('coins')
      .eq('user_id', userId)
      .maybeSingle();

    const currentCoins = profile ? (profile.coins || 0) : 100;
    const newCoins = currentCoins + coins;

    if (profile) {
      const { error } = await supabase
        .from('profiles')
        .update({ coins: newCoins })
        .eq('user_id', userId);
      if (error) throw error;
    } else {
      const { error } = await supabase
        .from('profiles')
        .insert({ user_id: userId, coins: newCoins });
      if (error) throw error;
    }

    // Record it so a retry of this same session won't double-credit.
    await supabase.from('coin_purchases').insert({
      user_id: userId,
      stripe_session_id: session.id,
      coins_granted: coins,
      amount_paid: session.amount_total,
      currency: session.currency
    });

    console.log('Credited', coins, 'coins to', userId);
    return res.status(200).send('Credited');
  } catch (err) {
    // Return 500 so Stripe retries — better than silently losing a paid purchase.
    console.error('Failed to credit coins:', err);
    return res.status(500).send('Crediting failed');
  }
}
