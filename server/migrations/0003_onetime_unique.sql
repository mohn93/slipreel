-- Prevent duplicate one-time entitlement rows under concurrent delivery of
-- checkout.session.completed events for the same user.
CREATE UNIQUE INDEX entitlements_user_onetime_key
  ON entitlements (user_id) WHERE plan = 'onetime';
