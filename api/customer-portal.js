// Opens Stripe's own billing portal so a subscriber can see what they are
// paying, change the card, or cancel — without emailing us and waiting.
//
// This is not a nicety. A subscription that renews automatically has to be as
// easy to stop as it was to start, so the cancel path ships with the sell path
// rather than after it.

import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { accessToken } = req.body || {};
    if (!accessToken) return res.status(401).json({ error: 'Not signed in' });

    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY
    );

    const { data: userData, error: userError } = await supabase.auth.getUser(accessToken);
    if (userError || !userData || !userData.user) {
      return res.status(401).json({ error: 'Session expired — please sign in again' });
    }

    const { data: sub } = await supabase
      .from('subscriptions')
      .select('stripe_customer_id')
      .eq('user_id', userData.user.id)
      .maybeSingle();

    if (!sub || !sub.stripe_customer_id) {
      return res.status(404).json({
        error: 'no_subscription',
        message: 'No subscription found on this account.'
      });
    }

    const origin = req.headers.origin || ('https://' + req.headers.host);

    const portal = await stripe.billingPortal.sessions.create({
      customer: sub.stripe_customer_id,
      return_url: origin + '/shop.html'
    });

    return res.status(200).json({ url: portal.url });
  } catch (err) {
    console.error('customer-portal error:', err);
    return res.status(500).json({ error: 'Could not open the billing portal' });
  }
}
