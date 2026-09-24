# Worked example (excerpt)

Trimmed from the first real flow-review: a family account paying an accepted care placement, walked on web at 1280 and 390 and in the mobile app, against a preview env. Product names and hosts are removed here because this repo is public. The full report, with all 20 screenshots, is the 2026-09-23 Julie payment flow under `~/.notes/ref/`. Read that one when you want the whole shape.

What it shows: a tally a reader can act on before scrolling, one line of "what happens" per step, severity on every note, `file:line` on the fixes that have one, OK notes kept so the reader knows the step was checked, and a caveats section that stops the reader from over-reading test data.

---

# Paying a facility, start to finish

<product> - payment flow review - preview env

A family account pays an accepted $6,800/mo placement, on web at desktop and phone width and in the mobile app. Captured 2026-09-23 against the preview env, running develop 26c09e01. The payment is real in the processor's sandbox, so no money moved.

**10 to fix - 5 polish - 1 to verify in prod**

## Web

The whole payment happens here, including in the mobile app: native iOS and Android load this same checkout inside the app.

### 2. Checkout

Who is being paid, the total, the fee breakdown, the account holder name and the ACH authorization.

- **OK** The strongest screen in the flow: logo, amount and fee split are all clear.
- **POLISH** For the first second the logo slot is empty and the header says "Loading payment system..." (first frame).

![Desktop](shots/03-checkout-desktop.jpg)
![Phone](shots/04-checkout-phone.jpg)

### 4. Processor confirmation

The processor's ACH mandate. Confirm submits the payment.

- **VERIFY** The payee reads "Default Test Account", the sandbox account's name. In production it shows the live account's business name. Check that it says the product name before any family sees it.

### 5. After paying

The page shows "Payment authorized" for 3 seconds, then redirects to the Requests list.

- **FIX** There is no lasting confirmation. The success message disappears after 3 seconds (usePaymentForm.ts:397) and you land on a list with no receipt. Someone who looks away never sees that it worked.

## Mobile app

The browser build of the Expo app at phone size. Native builds share this code but were not run on a device for this review.

### 1. Requests list

- **FIX** Every request shows FLEXIBLE, even urgent ones. The app reads `urgency`, but the field is called `priority` (CareRequestsScreen.tsx:358).

## What this is not

Preview only has test data: the facility is a seeded stand-in and its logo is a stock test image. Layout and behaviour are the same code that runs in production.
