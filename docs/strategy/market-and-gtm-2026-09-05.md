# Slipreel product, pricing, and go-to-market strategy

Date: 2026-09-05
Owner: Mohanned / Becoming Ventures, LLC
Status: Approved direction; implementation and validation in progress.

## Decision and objective

Build a sustainable indie product by helping Mac-based developers publish polished product demos. Focus the next six weeks on first-export success, purchase clarity, customer evidence, and a repeatable way to reach buyers. This is a market hypothesis, not established product-market fit.

**User decision: change the one-time license from $129 to $69 now.** This supersedes the earlier recommendation to hold $129 and possibly test $99 later. Keep one year of updates, perpetual use of the purchased eligible version, and two Macs. Do not promise lifetime updates. Existing purchased rights and subscriptions remain intact. **Updated decision, September 6: new monthly purchases are $9/month, with $69 one-time recommended. Yearly is removed from new-purchase choices and rejected by new checkout; existing monthly/yearly subscriptions keep their current billing terms.** Older yearly links default to the one-time offer. Existing customers retain account/billing management.

At $69, approximately 58 new one-time purchases produce $4,002 gross revenue, before processing fees, refunds, support, and other costs. This is not MRR. Matching revenue from $129 requires approximately 87% more purchases. Compare revenue per qualified visitor as well as conversion; lower pricing alone does not prove a better business.

## Evidence and its limits

Verified public pages on September 5, 2026:

- Screen Studio: $29/month or $9/month billed annually ($108/year). Automatic zoom, cursor smoothing, device frames, local transcription, and sharing. https://screen.studio/
- Screen Charm: $79 one-time with lifetime updates, three devices, shareable links, and substantial core feature overlap. https://screencharm.com/
- TrustMRR reports Screen Charm cumulative revenue of $52,058, verified through Stripe, and lists its founder with approximately 10,700 X followers. Revenue does not establish profit; audience size does not establish acquisition causality. https://trustmrr.com/startup/screen-charm
- ScreenRun: $19.99/year and a limited-time $49 lifetime offer; pricing lists 1080p output. Its browser workflow is not a like-for-like native app benchmark. https://screenrun.app/pricing
- FocuSee: advertised Standard $49.99/year and Advanced $199.99 one-time access to version 2.x at the time of review. https://focusee.imobie.com/pricing.htm
- Cap offers free personal use and paid commercial licensing with a local Studio workflow. https://cap.so/

These are advertised capabilities, not independently tested quality rankings. Neither a feature matrix nor a landing-page inspection proves Slipreel's output quality, reliability, retention, acquisition cost, or profitability. Prices and offers need periodic verification before publishing comparisons.

The market supports smaller paid products, but ownership and local processing are not exclusive advantages. At $69 Slipreel has a lower upfront price than Screen Charm's current $79, with a shorter included update period. Explain both facts honestly.

## Initial audience and positioning

Initial audience: independent Mac developers and small app agencies actively preparing a launch, feature announcement, tutorial, or client demo. Qualify by an immediate project and recurring need, not only job title.

Flutter/FlutterFlow communities are an initial recruitment hypothesis because the founder understands their workflows. Do not assume they are underserved or rebuild the brand around that stack without evidence. Screen Studio already shows a FlutterFlow-related testimonial.

Proposed audience landing-page copy:

> Turn your next feature into a demo worth sharing.
> Record your app, refine the automatic zooms, add captions, and export for your website or launch post.

Longer-term workflow hypothesis:

> One recording, ready for your launch.

Produce landscape, square, and vertical deliverables from one recording with consistent styling. Demonstrate this using existing controls before investing in batch workflows. Aspect-ratio switching alone is already available elsewhere; less work across the entire job is the proposed benefit. Do not advertise unbuilt batch export or unmeasured speed claims.

## Immediate purchase and website changes

1. Preserve chosen plans: a one-time CTA opens `pricing.html?plan=onetime`, yearly uses `?plan=yearly`, direct or invalid-plan visits default to one-time. Preserve device, state, and device-name activation parameters.
2. Show $69 consistently in homepage, checkout, comparison pages, machine-readable metadata, and actual Stripe checkout. Create a new immutable Stripe price; do not alter historical licenses or subscriptions.
3. Use “One-time purchase,” followed by “Includes one year of updates; keep using your purchased version.” State that later updates are an optional paid renewal. Do not invent a renewal price before one exists.
4. Bring the existing 14-day refund promise beside purchase buttons and checkout. Refund requests go to hello@slipreel.app.
5. State the current trial limits before installation. Until the trial-enabled app is released, say recording/editing are free and export requires purchase. After release, say “Three free full-quality exports. No credit card. Record and edit without a time limit.”
6. Correct Screen Studio pricing to $29/month and acknowledge both apps offer on-device transcription. Avoid claiming broad tested parity.
7. Keep the visual design; prioritize offer clarity and real output over a complete redesign.
8. Add three finished examples and raw-versus-finished demonstrations: SaaS feature, mobile app walkthrough, developer tutorial. Attribute customer work with permission, and use measured editing times only.

## Trial and onboarding

Implement three full-quality trial exports without an account or credit card. Count successful delivery only; failed or cancelled exports do not spend allowance. Share the allowance across projects/windows and persist it across launches. Paid exports do not consume it. Avoid conflating trial eligibility with a paid entitlement or entitlement-activation analytics.

The local allowance follows the app's existing offline licensing threat model. It is not abuse-proof: deleting local application data can reset it, and it is not an account-wide cross-device quota. Do not build invasive identification solely to prevent occasional free usage.

Show remaining allowance before export settings. Preserve project work if payment or activation fails. A user should be able to inspect their final file before purchasing.

Onboarding target: choose source → record a short demo → review automatic edits → export → open the finished file. Explain permissions in context. Evaluate a sample project for exploring the editor before capture permission, based on observed friction.

## Product-quality comparison and priorities

Run the same tasks in Slipreel, Screen Studio, and Screen Charm:

- 45-second SaaS feature walkthrough.
- Mobile simulator demo.
- Three-minute narrated tutorial.

Record hardware, app versions, capture resolution/frame rate, and equivalent output settings. Compare manual correction time, incorrect zooms, cursor motion, text sharpness, audio sync, export duration, failures, and recovery. Separate automatic output from output after manual edits. Do not publish superiority claims until evidence supports them.

Prioritize the largest obstacle to a publishable file: reliability, zoom correction, audio sync, or export fidelity before cosmetic breadth.

If customers repeatedly need multiple launch formats, consider saved brand presets, per-output composition, and batch export. Defer cloud hosting, Windows expansion, AI avatars, and general-purpose editor breadth until customer demand justifies them.

## GTM execution

### Direct recruitment

Build a list of 20 relevant developers/agencies with upcoming releases. Personally invite them to make a real demo. Observe the first 10 sessions without coaching initially; then help them finish. Record their prior tool, intended output, friction, willingness to pay, and whether they return. Assistance must not hide inability to use the product independently.

No outreach is automatically authorized by this document. Draft messages first; sending requires the user's explicit instruction.

### Demonstration content

Publish two useful videos per week: raw recording, finished result, actual editing time, and a specific audience task. Start on the platform where the founder already has relevant relationships; X, LinkedIn, or a relevant community are candidates, not a requirement to operate every channel.

Teach an actual workflow, rather than posting generic launch announcements. Link to a focused landing page and tag acquisition sources. Reuse effective demonstrations on the homepage and comparison pages.

### Creator partnerships

After initial customers succeed, approach a small set of relevant app-development, no-code, or Mac-workflow tutorial creators. Offer evaluation access. Negotiate disclosed sponsorships or tracked commissions only when audience fit and economics support them. Evaluate purchases, refunds, and returning users, not views alone. No commission rate or paid spend is approved here.

### Search and launch channels

Develop original demonstrations for query hypotheses such as “record Flutter simulator demo,” “make a FlutterFlow app demo,” and “Mac screen recorder without subscription.” These are not validated search-volume opportunities. Improve existing comparison pages with accurate pricing, matching-task examples, and limitations.

Defer broad paid advertising until qualified visitors reliably activate and buy. Product Hunt can amplify a launch after examples and satisfied users exist; do not depend on it for ongoing acquisition.

## Six-week schedule

| Period | Work | Deliverable |
| --- | --- | --- |
| Week 1 | Purchase fixes, $69 billing alignment, analytics verification, comparison recordings, recruitment | Clear offer and first observations |
| Week 2 | Observe first-use sessions; fix repeated blockers | Independent successful exports |
| Weeks 3–4 | Release/test trial exports, publish demonstrations, gather permissioned examples | Initial buyers and reusable proof |
| Weeks 5–6 | Repeat strongest outreach, evaluate creator fit, review objections and repeat use | Decision on audience, offer, and next product investment |

Customer recruitment can begin while fixes are underway. Do not postpone learning until the site is perfect.

## Measurement and decision rules

Audit existing analytics before adding infrastructure. The repo already includes web/app analytics hooks, recording/export events, and entitlement activation. Source presence does not prove production collection works.

Funnel: attributed visit → download → first completed recording → successful trial export → purchase → successful paid export → second project. Track paywall/checkout abandonment, failed exports, refunds, support effort, and revenue per qualified visitor. A download click is not a confirmed installation. Keep screen content, captions, typed keys, file paths, and recordings out of telemetry. Honor existing disclosure/consent behavior.

Initial learning target: 10 independently completed exports, five unrelated paying customers, and several second projects. These are proposed qualitative decision gates, not industry benchmarks or statistical proof.

- Cannot finish: improve product/onboarding.
- Finishes but has no recurring need: revisit audience.
- Wants ongoing use but rejects price: investigate offer and willingness to pay; $69 is already the approved starting price.
- Pays but does not return: examine use frequency, quality, and fit.
- Repeated success and purchases from one source: increase effort there before spreading channels.

## Rollout checklist and current status

- [x] Strategy saved, including approved $69 decision.
- [x] Working-copy pricing and checkout selection changes.
- [x] Trial allowance and export integration implemented in source.
- [x] Production Stripe price created and server configured.
- [x] Website deployed and live checkout amount/plan verified.
- [ ] Trial-enabled signed/notarized app released and tested on a Mac.
- [ ] Trial marketing copy activated after the compatible app is available.
- [ ] Production analytics receipt verified.
- [ ] Comparative app benchmark and first-user sessions completed.

User confirmed deployment target: **185.203.116.117 (the big server), not trader-vps or Localely**. Historical landing-page setup notes were corrected.

Initial SSH authentication failed; after the user authenticated, root access succeeded. The approved one-time price and website were then deployed. Existing licenses and subscriptions were not changed.

Roll out the price coherently: run the updated Stripe bootstrap using the intended account/mode; verify the new `slipreel_onetime_usd69_v1` price is USD 6900 cents, active, non-recurring; repoint `STRIPE_PRICE_ONETIME`; restart the API; verify checkout; deploy the site; verify the live plan/amount without charging a card. Keep prior price IDs for historical records and rollback. The bootstrap retains monthly/yearly lookup keys and validates returned price amounts.

Do not advertise three free exports to users downloading the old app. Publish the app release first, then update homepage, checkout, FAQ, and comparison trial language together. Existing users need the compatible update to use the new allowance.

### Implementation validation (2026-09-05)

- 27 website JavaScript tests passed, including valid/invalid plan selection.
- 24 targeted Flutter tests passed: persisted trial quota, concurrent reservation protection, paid-license gate, successful delivery, failures, and cancellation.
- Dart analysis passed for the changed runtime files.
- API TypeScript typecheck and separate Stripe bootstrap typecheck passed.
- Website lint and deployment-script safety tests passed.
- Browser preview verified $69, default one-time selection, explicit yearly selection, refund/update language, and desktop layout.
- Actual native capture/export and release signing/notarization remain to be exercised before distributing the trial-enabled app.
- Live pricing deployment completed after the user authenticated SSH. The API is healthy, and its running process uses the new $69 price. A live Stripe checkout was verified at USD 6900 cents, unpaid, then expired without charging a card.

### Production price rollout

- Server: 185.203.116.117; site owner/mode preserved as deploy:deploy 755.
- New one-time Stripe price: `price_1UCMQKJa6q311aT71bdEj06u`, lookup key `slipreel_onetime_usd69_v1`, USD 6900 cents, non-recurring, live.
- Prior price retained: `price_1UA8OKJa6q311aT7ZZixKioR`.
- Configuration backup on server: `/etc/slipreel-api.env.before-usd69-20260905` (contains secrets; do not copy into repo).
- Website backup on server: `/root/slipreel-backups/site-before-usd69-20260905.tar.gz`.
- Updated only the nine pricing-related HTML/text/JS files. Downloads, appcast, and analytics config were excluded.
- Confirmed the active API process uses the new price and health reports database up.
- Browser verified live $69 one-time selection. Trial marketing remains unchanged until the new app is released.

### Export button follow-up

User requested a visible remaining allowance on the export CTA. The source now shows “3 free exports,” “2 free exports,” or “1 free export,” then a crown + “Unlock export” + lock when depleted. Paid licenses show the normal Export CTA. The shared quota notifies open editors after a successful export; cancelled/failed exports do not decrement. Native app testing is reserved for the user. This follow-up was made after the initial 1.0.9 build began, so that earlier artifact must not be used to verify the new button; rebuild before testing/distribution.

### Sign-in feedback follow-up

The app now retains and presents explicit callback results: active subscription, active one-time license, no active license, update ceiling, inactive subscription, invalid/expired link, device limit, and activation/storage failure. Results include fixed actions for account management, plans, or a new sign-in. The recorder bar expands for the dialog and restores afterward. Auth nonce and signed-token checks remain required; duplicate delivery of the same callback is ignored.

The web sign-in flow now distinguishes an authenticated device-limit/activation failure from an invalid magic link and provides a nonce-bound error callback to the app. Network failure while requesting email is shown explicitly. Native account lookup for the supplied email could not be completed because SSH authentication had expired; no account status is asserted. Web changes need deployment after SSH reauthentication. App/UI testing remains with the user.

### Sign-in follow-up deployment (2026-09-06)

Browser sign-in fixes deployed to 185.203.116.117: login/success HTML and their scripts plus shared flow.js, preserving unrelated site files. Backup: `/root/slipreel-backups/site-before-signin-feedback-20260906.tar.gz`. Public script contents and API health verified. Static Dart analysis and JavaScript syntax checks passed. Native tests remain with the user. After SSH reauthentication, the requested read-only account check succeeded; no account or billing records were changed.

### Approved pricing simplification (2026-09-06)

- New monthly offer: $9/month (supersedes $12 and the rejected $4.99 suggestion).
- One-time: $69, recommended, one year of updates and perpetual eligible-version use.
- Yearly: not offered for new checkout; existing subscriptions and webhooks are preserved.
- Existing monthly subscribers are not automatically migrated to the new price.
- Eight monthly payments at $9 exceed $69. Matching $12 revenue requires about 33% more paid subscriber-months. Monitor revenue per visitor and whether subscriptions substitute for one-time purchases.
- Source and staged-live pricing, metadata, comparison pages, and two-card checkout layout updated. Deploy from staged live files to preserve unpublished trial-copy changes.

### Monthly pricing deployment (2026-09-06)

- Published $9/month and $69 one-time on the live site; removed yearly from new offers and checkout selection.
- Live monthly Stripe price: `price_1UCe7HJa6q311aT7QTZ5A6PO`, lookup `slipreel_monthly_usd9_v1`, USD 900 cents/month. Previous price `price_1UA8OJJa6q311aT7sVcN4czA` retained; existing subscriptions unchanged.
- Verified a live Stripe checkout at USD 900 cents, unpaid, then expired it without a charge. One-time price remains USD 6900 cents.
- API rebuilt and restarted successfully; public health reports database up. Public `/v1/checkout` rejects yearly with HTTP 400 before customer/session creation.
- Public pricing page verified at $9 and $69 without the $89 offer. Published ten staged pricing files, preserving current trial wording, downloads, appcast, and analytics configuration.
- Rollback backups on server: `/etc/slipreel-api.env.before-monthly9-20260906`, `/root/slipreel-backups/site-before-monthly9-20260906.tar.gz`, and `/root/slipreel-backups/monthly9-20260906/`. The environment backup contains secrets and must stay off the repository.
- Website plan-selection checks, site lint, JSON-LD parsing, TypeScript checks, and server build passed. Native app testing remains with the user.
