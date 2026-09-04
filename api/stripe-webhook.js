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

  const supabaseAdmin = () => createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );

  // --- Subscription lifecycle -------------------------------------------
  // The Pass is not a balance, so it is not credited; its state is mirrored
  // from Stripe. Renewals, cancellations and failed payments all arrive as
  // subscription events rather than as checkout sessions, which is why the
  // benefit has to be driven from here rather than from the moment of sale.
  if (event.type === 'customer.subscription.created' ||
      event.type === 'customer.subscription.updated' ||
      event.type === 'customer.subscription.deleted') {
    const sub = event.data.object;
    const subUser = sub.metadata && sub.metadata.user_id;

    if (!subUser) {
      console.error('Subscription event without user_id:', sub.id);
      return res.status(200).send('No user on subscription');
    }

    // A deleted subscription is over regardless of what status it carries.
    const status = event.type === 'customer.subscription.deleted' ? 'canceled' : sub.status;

    // Stripe moved current_period_end off the subscription and onto its items
    // in the 2025-03-31 API version, and a webhook payload is serialised with
    // whatever version the endpoint is pinned to -- not the version this SDK
    // defaults to. Reading only the old field would quietly store no expiry at
    // all, which makes a lapsed subscription look like it never ends.
    const periodEndUnix = sub.current_period_end
      || (sub.items && sub.items.data || [])
           .map(i => i.current_period_end)
           .filter(Boolean)
           .sort((a, b) => b - a)[0]
      || null;

    const periodEnd = periodEndUnix ? new Date(periodEndUnix * 1000).toISOString() : null;
    if (!periodEnd) {
      console.warn('Subscription', sub.id, 'carried no period end; membership will ' +
                   'rely on status alone until the next event.');
    }

    try {
      const { data, error } = await supabaseAdmin().rpc('set_subscription', {
        p_user_id: subUser,
        p_customer_id: typeof sub.customer === 'string' ? sub.customer : null,
        p_subscription_id: sub.id,
        p_status: status,
        p_period_end: periodEnd,
        p_cancel_at_period_end: !!sub.cancel_at_period_end
      });
      if (error) throw error;
      console.log('Subscription', sub.id, '->', status, 'for', subUser, 'active:', data && data.active);
      return res.status(200).send('Subscription recorded');
    } catch (err) {
      console.error('Failed to record subscription:', err);
      return res.status(500).send('Subscription update failed');
    }
  }

  if (event.type !== 'checkout.session.completed') {
    // Acknowledge anything we don't handle so Stripe stops retrying it.
    return res.status(200).send('Ignored');
  }

  const session = event.data.object;

  // The subscription's own events carry the state, and they arrive for every
  // later renewal too. Recording the sale here as well would add nothing and
  // would risk writing a period end this session does not actually know.
  if (session.mode === 'subscription') {
    return res.status(200).send('Subscription start — handled by subscription events');
  }

  // Only credit fully-paid sessions.
  if (session.payment_status !== 'paid') {
    return res.status(200).send('Not paid yet');
  }

  const userId = session.metadata && session.metadata.user_id;
  // Older sessions predate token packs and carry no `tokens` key at all, so a
  // missing value has to read as zero rather than as a broken payment.
  const coins = parseInt((session.metadata && session.metadata.coins) || '0', 10) || 0;
  const tokens = parseInt((session.metadata && session.metadata.tokens) || '0', 10) || 0;

  if (!userId || (coins <= 0 && tokens <= 0)) {
    console.error('Webhook missing usable metadata:', session.id);
    return res.status(200).send('Nothing to credit');
  }

  const supabase = supabaseAdmin();

  try {
    // One database call does the whole thing atomically: it claims the payment
    // by inserting the ledger row (the unique index on stripe_session_id is the
    // gate) and only then increments the balance.
    //
    // This used to be a check, then a credit, then a record. Two Stripe
    // deliveries arriving together could both pass the check and both pay out
    // before either recorded anything — one payment, double the coins.
    const { data: result, error } = await supabase.rpc('credit_coin_purchase', {
      p_user_id: userId,
      p_session_id: session.id,
      p_coins: coins,
      p_amount: session.amount_total,
      p_currency: session.currency,
      p_tokens: tokens
    });

    if (error) throw error;
    if (!result || !result.ok) throw new Error(result ? result.error : 'no result from credit_coin_purchase');

    if (result.already_credited) {
      return res.status(200).send('Already credited');
    }

    console.log('Credited', coins, 'coins /', tokens, 'tokens to', userId,
                '- balances now', result.coins, '/', result.tokens);
    return res.status(200).send('Credited');
  } catch (err) {
    // Return 500 so Stripe retries — better than silently losing a paid purchase.
    console.error('Failed to credit coins:', err);
    return res.status(500).send('Crediting failed');
  }
}
