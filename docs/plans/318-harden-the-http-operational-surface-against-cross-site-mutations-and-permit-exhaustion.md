---
id: 318
slug: harden-the-http-operational-surface-against-cross-site-mutations-and-permit-exhaustion
title: "Harden the HTTP operational surface against cross-site mutations and permit exhaustion"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
---

# Harden the HTTP operational surface against cross-site mutations and permit exhaustion

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, a Keiro operator can mount `keiro-ops-http` with mutations enabled behind a
proxy that authenticates with cookies and know that a page on another origin cannot make the
operator's browser execute a confirmed mutation, because the surface refuses a mutation whose
`Origin` is foreign or whose body is not declared as JSON. A few slow or stalled clients can
no longer hold every inspection permit and take `/health`, every read, every websocket upgrade,
and every feed refresh down with `inspection_busy`, because response delivery has its own
bound. Feeds verify the schema once per handle tick rather than once per view per refresh, and
they stop re-encoding an unchanged snapshot every second. The three HTTP guides describe every
error code the surface emits and the TLS caveat for same-origin websockets.


## Progress

- [ ] M1: Confirmed mutations are origin-gated. A `POST` with an `Origin` header that is
      neither allow-listed nor same-origin is refused with HTTP 403 and code `origin_not_allowed`
      before the body is read; a `POST` whose non-empty body is not `Content-Type:
      application/json` is refused with 415 and code `unsupported_media_type`; the existing
      preview and confirm tests still pass; new tests in `keiro-ops-http/test/` cover both
      refusals and the allowed cases (no `Origin`, allow-listed origin, same-origin).
- [ ] M2: Delivery is bounded. A new `deliveryDeadlineSeconds` limit (default 30) wraps
      response delivery; a client that stops reading loses its permit when it expires, and a
      test with a deliberately slow consumer shows `/health` answering 200 while the slow
      consumer is still draining. ADR-53 is revised to say that admission spans computation
      and bounded delivery.
- [ ] M3: Feed schema verification runs once per handle tick. `readView` no longer calls
      `checkFeedSchema` per view per refresh; the handle verifies once per fallback interval
      inside the same admission deadline (ADR-56 requires it inside the deadline) and every
      driver consults that result; drift still stops publication; a test with two views and a
      counting pool shows one verification per tick. The unchanged-snapshot re-encode in
      `refresh` is skipped and the retiring-view refusal uses a distinct code
      (`view_retiring`) or waits for retirement.
- [ ] M4: The guides are complete. `docs/guides/stream-keiro-inspection-views.md` lists every
      error code in `keiro-ops-http/src/Keiro/Ops/Http/Protocol.hs` and the TLS same-origin
      caveat; `docs/guides/serve-keiro-ops-over-http.md` lists `exit_code`, 409
      `cursor_generation_mismatch`, the 400 codes `invalid_cursor`, `invalid_page_size`,
      `inspection_header_inconsistent`, and the new 403 and 415 codes;
      `just user-documentation-validate` passes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Gate by `Origin` presence plus allow-list or same-origin, and by `Content-Type`,
  rather than adding a CSRF token or nonce to the confirmation.
  Rationale: The confirmation is a fixed JSON body by design (ADR-53); browsers send `Origin`
  on every cross-site `POST`, and a non-JSON content type is exactly what a no-preflight
  cross-site request looks like. A nonce would change the documented protocol for every client
  and is listed as a later option, not a requirement.
  Date: 2026-10-21
- Decision: Bound delivery with a deadline rather than releasing the permit after encoding.
  Rationale: The permit is held through delivery so that slow clients cannot retain an
  unbounded number of encoded bodies (`Budget.hs` comment); a deadline keeps that property and
  adds an upper bound on how long one client can hold a slot.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`keiro-ops-http` is the opt-in HTTP and WebSocket transport over the `keiro-ops` command tree
(ADR-53, `docs/adr/0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md`).
A request is parsed into a command, classified as a read (`GET`) or a mutation (`POST`), and
run under an "inspection budget": a fixed number of permits (`maxConcurrentReads`, default 4 in
`keiro-ops-http/src/Keiro/Ops/Http/Config.hs`, `defaultInspectionLimits`) with no waiting
queue, so the fifth concurrent request is refused with HTTP 503 and code `inspection_busy`. The
budget is implemented in `keiro-ops-http/src/Keiro/Ops/Http/Budget.hs`: `withInspectionAdmission`
takes a permit and releases it in `bracket`, and `withInspectionDeadline` wraps only the
computation. In `keiro-ops-http/src/Keiro/Ops/Http/Application.hs` (around line 128) the permit
is held through `respond`, so a client that reads its response slowly keeps the permit as long
as Warp keeps the connection alive, and Warp resets its inactivity timer on every chunk it
sends. Four such clients exhaust the surface, including `/health` (which also takes a permit)
and the websocket upgrade check in `keiro-ops-http/src/Keiro/Ops/Http/WebSocket.hs` (line 55)
and every feed refresh in `keiro-ops-http/src/Keiro/Ops/Http/Feed/Driver.hs` (`bounded`).

Mutation confirmation is in `Application.hs`: `budgetedCommand` reads the body with
`readConfirmation` (at most 1 KiB, must decode to exactly `{"confirm":"execute"}`), and
`force = mutation && confirmed`. Nothing inspects `Origin`, `Sec-Fetch-Site`, or
`Content-Type`. `keiro-ops-http/src/Keiro/Ops/Http/Cors.hs` (`corsMiddleware`) only adds
`Access-Control-Allow-Origin` for allow-listed origins and answers preflights; it never refuses.
The websocket path does enforce the allow-list (`originAllowed`, `WebSocket.hs` lines 81 to 90)
and lowercases origins, while HTTP compares them case-sensitively. A browser can therefore send
`fetch(url, {method: "POST", mode: "no-cors", body: '{"confirm":"execute"}'})` from any page:
no preflight is sent for a `text/plain` body, and the surface executes.

Feeds (ADR-56, `docs/adr/0056-inspection-feeds-own-bounded-shared-drivers-and-an-active-only-wake-cursor.md`)
are in `keiro-ops-http/src/Keiro/Ops/Http/Feed.hs` and `Feed/Driver.hs`. `readView` (Feed.hs
line 124) calls `checkFeedSchema`, which runs `verifyExpectedSchemaSession` from
`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` (three statements, including the
catalog comparison against the embedded expected snapshot), on every refresh of every view;
drivers refresh on notification at the configured minimum interval (`defaultFeedConfig`,
Driver.hs line 61: one second, five for timers). Thirty-two views can issue thirty verifications
a second, each holding a permit. `refresh` (Driver.hs around line 167) re-encodes the snapshot
frame unconditionally even when `different` is false, up to the 1 MiB frame cap per view per
second. `acquireDriver` (Feed.hs around line 180) refuses a new subscriber of an entry that is
retiring with `FeedBusy`, which clients see as `inspection_busy` although capacity is free.

The error codes the socket emits are in `keiro-ops-http/src/Keiro/Ops/Http/Protocol.hs`
(lines 66 to 78); the stream guide lists three of them. The serve guide's error table omits
several HTTP codes that `Application.hs` and `keiro-ops/src/Keiro/Ops/Workflow.hs`
(`inspectionError`) emit. The same-origin websocket fallback computes the expected origin from
`isSecure`, which is false on a plain listener behind a TLS proxy, so `https://host` never
matches and must be allow-listed explicitly.

Relevant local ADRs: ADR-53 and ADR-56 above (both revised by this plan), ADR-40
(`docs/adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md`) for the
boundary that no runtime package gains a web dependency, and ADR-57
(`docs/adr/0057-compose-allocated-inspection-applications-without-changing-their-routes.md`),
whose composition must keep working with the new refusals (the CORS middleware is applied once
by the composer). No cross-repository ADR applies.


## Plan of Work

Milestone 1 adds origin and content-type gating in `Application.hs` before `readConfirmation`:
if the request is a mutation and carries an `Origin` header, the origin must be in
`config.allowedOrigins` (compared case-insensitively on scheme and host, the way
`WebSocket.hs` does) or equal the request's own origin (`Host` with the scheme from `isSecure`
or a configured public origin, see M4's TLS caveat); otherwise answer 403 `origin_not_allowed`
without reading the body. If the body is non-empty and `Content-Type` is not
`application/json` (parameters such as `charset` allowed), answer 415 `unsupported_media_type`.
Move the HTTP origin comparison into a shared helper so CORS and websocket agree on case
handling. Add the two codes to the error table and tests: a `POST` with `Origin:
https://evil.example` to a mutation route returns 403 and runs nothing (assert the mutation's
preview counter did not move); a `POST` with `Content-Type: text/plain` and the confirmation
body returns 415; the existing allow-listed and header-less cases keep returning preview or
execution.

Milestone 2 bounds delivery. Add `deliveryDeadlineSeconds` to `InspectionLimits` (default 30)
and wrap the `respond` call inside `withInspectionAdmission` with `timeout`; on expiry the
permit is released by the existing `bracket`, the connection is closed by Warp when the
response body is abandoned, and nothing else is written (a second response is never attempted;
the existing comment "Network exceptions must propagate; never attempt a second response"
holds). Test it with a real socket: start the server on a loopback port in a test (the HTTP
test suite already has the pattern), open a client that reads one byte of a 1 MiB page and
stops, do that four times, and assert `/health` still answers 200 within a second; then assert
the stalled clients are disconnected after the deadline. Revise ADR-53's admission paragraph.

Milestone 3 changes feed verification cadence. Give `FeedHandle` one schema-check result with a
timestamp; `readView` consults it and triggers a new verification only when it is older than
the fallback interval, running the verification inside the same `bounded` admission so ADR-56's
"inside the deadline" rule holds. Keep the websocket upgrade check as it is (it is per
connection, not per refresh). Skip the snapshot `prepare` in `refresh` when `different` is false
and a snapshot already exists. Return `view_retiring` (or wait for `stopDriver` to join) in
`acquireDriver` for a zero-reference entry. Tests: two views on the same handle with a pool
wrapper that counts `verifyExpectedSchemaSession` calls show one call per tick; a refresh with
no change does not allocate a new snapshot frame (compare the `IORef`/TVar identity); a quick
unsubscribe and resubscribe does not return `inspection_busy`.

Milestone 4 completes the guides: enumerate every socket code from `Protocol.hs` in the stream
guide, add the TLS caveat (allow-list the public `https://` origin explicitly when terminating
TLS in front of the listener), and complete the serve guide's error table with the codes named
in Progress. Run `just user-documentation-validate`.


## Concrete Steps

From the repository root inside `nix develop`:

```bash
cabal build keiro-ops-http
cabal test keiro-ops-http-test --test-show-details=direct
just user-documentation-validate
just adr-validate
```

Manual check of the origin gate against a running standalone server (replace the connection
string with the project database from `just postgres-start`):

```bash
cabal run keiro-ops-http -- --database-url "host=$PWD/db dbname=keiro" --enable-mutations --listen 127.0.0.1:8090 &
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Origin: https://evil.example' \
  -H 'Content-Type: application/json' --data '{"confirm":"execute"}' \
  http://127.0.0.1:8090/pgmq/dlq/read?queue=billing          # expect 403
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: text/plain' \
  --data '{"confirm":"execute"}' http://127.0.0.1:8090/pgmq/dlq/read?queue=billing   # expect 415
```

Expected output of the two `curl` lines:

```text
403
415
```


## Validation and Acceptance

M1: the four new tests pass and the two `curl` lines print 403 and 415. M2: the slow-consumer
test passes and the revised ADR-53 validates. M3: the counting-pool test shows one verification
per tick for two views, the no-change refresh allocates no new frame, and the resubscribe test
does not see `inspection_busy`. M4: the validator passes and the two guides list the codes.
Beyond compilation, the proof is the standalone server refusing the cross-site `POST` and
answering `/health` while four stalled clients hold connections.


## Idempotence and Recovery

Source and documentation edits only; `git checkout` restores any file. The origin gate is
additive: a deployment that sets no `allowedOrigins` and receives no `Origin` header is
unaffected; one that is called cross-site from an allow-listed console keeps working because
the allow-list is consulted first. The delivery deadline defaults to 30 seconds and can be
raised by the host configuration if a legitimate client needs longer.


## Interfaces and Dependencies

`keiro-ops-http/src/Keiro/Ops/Http/{Application,Budget,Config,Cors,WebSocket,Feed,Feed/Driver,Protocol}.hs`;
`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` (`verifyExpectedSchemaSession`, read
only); `warp`, `wai`, `websockets`; the HTTP test suite in `keiro-ops-http/test/`. The
`InspectionLimits` record gains `deliveryDeadlineSeconds`, which direct constructors must
supply; plan 320 records that in the changelog. The three HTTP guides are owned by this plan.
No parent milestone must be accepted before this plan begins.
