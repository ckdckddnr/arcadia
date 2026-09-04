/* The shop catalogue, in one place.
 *
 * These are display values only -- api/create-checkout-session.js holds the
 * prices Stripe is actually charged, and a browser cannot change those. This
 * file exists so the landing page and the shop cannot drift apart: the same
 * numbers were already written twice, and a third copy on the home page was
 * how the "500 Coins" on one page quietly becomes 400 on another.
 *
 * Keep the ids identical to the keys in COIN_PACKS / SUBSCRIPTIONS on the
 * server. The id is what gets posted to checkout.
 */
window.ARCADIA_PACKS = {
  coins: [
    { id:'starter', icon:'🪙', coins:500,   price:'$1.99',  badge:null },
    { id:'plus',    icon:'💰', coins:1500,  price:'$4.99',  badge:'Popular' },
    { id:'pro',     icon:'💎', coins:4000,  price:'$9.99',  badge:'Best Value' },
    { id:'mega',    icon:'👑', coins:10000, price:'$19.99', badge:null }
  ],
  tokens: [
    { id:'tokens150', icon:'⚔', tokens:150, price:'$1.99', badge:null }
  ],
  pass: {
    id:'pass', icon:'🎫', name:'Arcadia Pass', price:'$2.99', period:'month',
    blurb:'Doubles your daily check-in reward. Cancel any time.'
  }
};
