// Creates a Stripe Checkout session for a coin pack purchase.
// The pack catalog lives here on the server so a user can't tamper with prices.

import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

// Prices are in the smallest currency unit (cents for USD).
const COIN_PACKS = {
  starter: { name: 'Starter Pack',  coins: 500,   amount: 199 },
  plus:    { name: 'Plus Pack',     coins: 1500,  amount: 499 },
  pro:     { name: 'Pro Pack',      coins: 4000,  amount: 999 },
  mega:    { name: 'Mega Pack',     coins: 10000, amount: 1999 }
};

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { packId, accessToken } = req.body || {};

    const pack = COIN_PACKS[packId];
    if (!pack) return res.status(400).json({ error: 'Unknown coin pack' });
    if (!accessToken) return res.status(401).json({ error: 'Not signed in' });

    // Verify the caller really is who they claim to be, using their Supabase session token.
    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY
    );
    const { data: userData, error: userError } = await supabase.auth.getUser(accessToken);
    if (userError || !userData || !userData.user) {
      return res.status(401).json({ error: 'Session expired — please sign in again' });
    }
    const user = userData.user;

    const origin = req.headers.origin || ('https://' + req.headers.host);

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [{
        quantity: 1,
        price_data: {
          currency: 'usd',
          unit_amount: pack.amount,
          product_data: {
            name: pack.name,
            description: pack.coins.toLocaleString() + ' Arcadia Coins'
          }
        }
      }],
      // Recorded on the session so the webhook knows who to credit and how much.
      client_reference_id: user.id,
      metadata: {
        user_id: user.id,
        pack_id: packId,
        coins: String(pack.coins)
      },
      success_url: origin + '/shop.html?status=success',
      cancel_url: origin + '/shop.html?status=cancelled'
    });

    return res.status(200).json({ url: session.url });
  } catch (err) {
    console.error('create-checkout-session error:', err);
    return res.status(500).json({ error: 'Could not start checkout' });
  }
}
