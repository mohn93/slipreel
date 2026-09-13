# App Store review request

Store builds request Apple's native rating/review UI three seconds after the
first successful export opportunity while the app is idle. Cancelled/failed
exports do not schedule it. The output and success feedback are delivered first.
The Store edition no longer stacks the first-export upsell onto this moment;
the ordinary export paywall remains in place when the free allowance runs out.

A local SharedPreferences marker records one request per installation, independent
of sign-in or subscription. Concurrent exports cannot double-request. If the app
is busy, navigating, showing another route/update prompt, inactive, or displaying a
native sheet, skip the request and try after a later successful export. A native
error does not change the successful export outcome. Website builds never invoke
the review bridge, which also independently checks the native Store edition.

Apple decides whether to display the prompt. Calling the API is not evidence of a
shown prompt, submitted rating, or review. Apple suppresses the UI in TestFlight;
use a development-signed Store build to inspect the native dialog. Do not add a
custom satisfaction survey or pre-filter users based on their likely rating.

API: https://developer.apple.com/documentation/storekit/appstore/requestreview(in:)-4r0y9
