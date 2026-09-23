# Sender logo for noreply@ezycore.com (BIMI)

The grey silhouette Gmail shows next to our order mails is not something Resend
can change. The logo is published by us in DNS and fetched by the mailbox
provider — the standard is BIMI (Brand Indicators for Message Identification).

Three things have to be true before any provider will draw it:

1. the mail authenticates and DMARC is at **enforcement**,
2. a square **SVG Tiny P/S** logo is reachable over HTTPS,
3. for Gmail, a **VMC or CMC certificate** vouches that the mark is ours.

Steps 1 and 2 are done from this repo. Step 3 is a purchase.

## Where we stand

Measured 2026-08-29:

| Record | State |
| --- | --- |
| `resend._domainkey.ezycore.com` | present — DKIM signs as `ezycore.com`, so DMARC aligns on DKIM |
| `send.ezycore.com` TXT | `v=spf1 include:amazonses.com ~all` (Resend sends over SES) |
| `_dmarc.ezycore.com` | **missing** |
| `default._bimi.ezycore.com` | missing |
| `ezycore.com` MX | none (no mailbox on the apex) |

DNS is on Cloudflare. TXT records are never proxied, so the orange cloud does
not apply to anything below.

## 1. DMARC

Publish this first and leave it alone for two to four weeks. `p=none` changes
nothing about delivery; it only asks receivers to report what they see, which is
how we confirm nothing legitimate breaks before tightening.

```
Type: TXT
Name: _dmarc
Value: v=DMARC1; p=none; rua=mailto:dmarc@ezycore.com; adkim=r; aspf=r
TTL: Auto
```

`rua` needs a mailbox that exists. The apex has no MX, so either point it at a
working address or use a DMARC report service.

Once the reports show only our own senders passing, tighten to enforcement —
BIMI is ignored below `quarantine`:

```
Value: v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc@ezycore.com; adkim=r; aspf=r
```

This step is worth doing on its own merits. With no DMARC record at all, anyone
can send mail as `ezycore.com` today.

## 2. The logo

`easystock-marketing/public/bimi/ezycore-bimi.svg` — the 2x2 mark on the brand
navy, 512x512, SVG Tiny P/S, ~512 bytes. A light variant sits beside it, but the
dark one is the one to publish: Gmail crops the avatar to a circle, and the
white version loses its edge against a white inbox.

The constraints the profile imposes, so the file is not "tidied" into
invalidity later: `version="1.2"`, `baseProfile="tiny-ps"`, `<title>` as the
first child, a square `viewBox`, no `width`/`height`/`x`/`y` on the root, and no
script, animation, external reference, raster `<image>`, `<style>` block, or
embedded font. Under 32KB.

It deploys with the marketing site to `https://ezycore.com/bimi/ezycore-bimi.svg`.
Confirm it is served as `image/svg+xml` before publishing the record.

## 3. The certificate (Gmail's gate)

Gmail will not draw a self-asserted logo. It needs one of:

- **VMC** — requires the mark registered as a trademark,
- **CMC** — no trademark, but the mark must have been in continuous use for
  about a year.

Both are issued by DigiCert or Entrust, roughly USD 1,000–1,500 per year, and
take a few weeks. Yahoo has the same requirement; a few smaller providers will
render a logo without one.

Until a certificate exists, publishing the BIMI record below is harmless but
Gmail keeps showing the silhouette.

## 4. The BIMI record

```
Type: TXT
Name: default._bimi
Value: v=BIMI1; l=https://ezycore.com/bimi/ezycore-bimi.svg; a=https://ezycore.com/bimi/ezycore-vmc.pem
TTL: Auto
```

Without a certificate, drop the `a=` tag and publish `v=BIMI1;
l=https://ezycore.com/bimi/ezycore-bimi.svg;` — valid, and picked up by the
providers that accept self-asserted logos.

## Checking it

```sh
dig +short TXT _dmarc.ezycore.com
dig +short TXT default._bimi.ezycore.com
curl -sI https://ezycore.com/bimi/ezycore-bimi.svg | grep -i content-type
```

Gmail caches aggressively — allow a day or so after the certificate is in place,
and test with a fresh send rather than an old thread.

## A cheaper interim

A Google Workspace mailbox for `noreply@ezycore.com` with a profile photo gets
Gmail to render that photo as the sender avatar, for a seat fee rather than a
certificate. It needs MX records on `ezycore.com`, which we do not have, and it
only helps Gmail recipients — everyone else still sees initials.
