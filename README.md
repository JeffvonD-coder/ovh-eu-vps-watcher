# OVH EU VPS stock watcher

Checks every 5 minutes whether an OVHcloud VPS is orderable in an **EU
datacenter**, and sends a push notification the moment one comes back in stock.

This is the always-on **backstop** to a local watcher that polls every 30
seconds. The local one is faster; this one keeps running when that machine is
asleep.

## How it works

The OVHcloud configurator page is a JavaScript app, but underneath it calls a
single unauthenticated JSON endpoint — the same one this repo polls:

```
https://www.ovhcloud.com/eu/engine/api/v1/vps/order/rule/datacenter/?ovhSubsidiary=NL&planCode=vps-2027-model4
```

It returns `available` / `out-of-stock` per datacenter. No browser, no scraping,
no login. The response is sent `cache-control: no-cache, no-store`, so each poll
reads live backend state.

## Datacenters treated as EU

`eu-west-gra` (Gravelines), `eu-west-rbx` (Roubaix), `eu-west-sbg` (Strasbourg),
`eu-west-lim` (Limburg), `eu-south-mil` (Milan), `eu-central-waw` (Warsaw).

`eu-west-eri` (Erith, UK) is deliberately **excluded** — despite the `eu-` prefix
it sits outside the EU post-Brexit, covered only by an adequacy decision. Set
`notifyOnNonEu: true` in `config.json` to include it. Non-European regions
(`ca-east-bhs`, `ap-southeast-sgp`, `ap-southeast-syd`, `ap-south-mum`) are never
alerted on.

## Setup

One secret is required:

| Secret | Purpose |
|---|---|
| `NTFY_TOPIC` | Your private [ntfy.sh](https://ntfy.sh) topic. Subscribe to it in the ntfy app to receive alerts. |
| `NTFY_EMAIL` | *Optional.* ntfy forwards each alert to this address too. |

The topic is kept in a secret rather than in `config.json` because anyone who
knows a topic name can read and post to it. It is masked in workflow logs.

## Anti-spam behaviour

Alerts fire on the **transition** out-of-stock → available, not on every run.
While stock persists you get one reminder every `reNotifyAfterHours` (default
12). If stock disappears and returns, that is a fresh transition and alerts
again.

State lives in `state.json` and is committed back **only when it changes**, so
the history stays readable rather than one commit every five minutes.

## Notes and limitations

- GitHub's shortest cron interval is 5 minutes, and scheduled runs are
  best-effort: they can be delayed by 5–15 minutes when Actions is busy, and
  occasionally dropped. This is a safety net, not a precision instrument.
- GitHub disables scheduled workflows in repositories with no activity for 60
  days. `state.json` carries a `keepalive` field that changes once a month,
  which produces a commit and keeps the schedule alive.
- Public repository, so Actions minutes are free and unlimited. On a private
  repo this cadence would exceed the 2,000 minute monthly allowance about four
  times over.
- Stock on popular OVH models can be gone in minutes. Have your payment method
  saved on the OVH account so checkout is as short as possible.

## Running it by hand

Actions → *OVH EU VPS stock check* → **Run workflow**. Each run writes a summary
table of the current EU stock picture.

Watching a different model: change `planCode` in `config.json` (find it in the
configurator URL as `?planCode=...`).
