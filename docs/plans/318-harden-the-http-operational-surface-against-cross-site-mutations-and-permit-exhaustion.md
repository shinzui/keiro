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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:24:48Z
      verdict: "changes-requested"
      note: "Schema TTL weakens fail-closed drift policy; unchanged-frame reuse loses fresh timer presentation; 30-second delivery bound cannot satisfy one-second health acceptance under full admission."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-21T13:49:51Z
      mode: "update"
      note: "Preserve fresh schema/snapshot observations; specify bounded delivery recovery and honest retirement refusals."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T04:38:35Z
      mode: "implement"
      note: "Implement shared parsed-origin policy, bounded delivery and retirement refusal."
---

# Harden the HTTP operational surface against cross-site mutations and permit exhaustion

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this plan, HTTP mutations reject foreign origins and non-JSON confirmation bodies,
and stalled delivery cannot retain an inspection permit indefinitely. `/health` shares the
same admission pool: it may return `inspection_busy` while every slot is occupied, then
succeeds after stalled deliveries are cancelled and slots return. The default delivery
bound is 30 seconds, separately configurable from computation deadlines.

Feed refreshes continue to verify current schema agreement inside their admission/deadline.
Clock-only refreshes do not broadcast false changes, but new subscribers receive the latest
successful read's timestamp and timer presentation. The proposed TTL cache and semantic-only
snapshot reuse are withdrawn because they weaken these existing contracts. The guides record
that choice, all refusal codes, and the TLS origin requirement.


## Progress


- [x] M1 (2026-10-25): Shared parsed-origin policy rejects foreign/malformed/repeated
      origins before body reads; JSON media types are required for nonempty bodies,
      including chunked transfer. Real loopback HTTP requests return 403 and 415.
- [x] M2 (2026-10-25): A validated 30-second default delivery deadline bounds respond.
      Four blocked callbacks expire once and return every permit; cancellation also
      releases admission. The real Warp test establishes 32-MiB/4-KiB backpressure,
      termination/truncation and health recovery with a one-second test deadline.
- [x] M3 (2026-10-25): Two active views refuse schema drift and recover after repair;
      timer resubscription receives fresh presentation without a clock-only delta;
      blocked retirement refuses with `view_retiring` until cleanup joins.
- [x] M4 (2026-10-25): Guides, composition example and ADR-53/56 carry the implemented
      policy. The Nix HTTP suite passes 49 examples; strict ADR/user/guide checks pass.


## Surprises & Discoveries


The review found that a timestamped schema result would let a refresh proceed after drift
until the cache expired; shared admission alone does not prevent that. It also found that
`Views.stableItemBody Timers` omits `due_in_seconds`, while `subscribeOnQueue` sends the
retained snapshot. Reusing that snapshot solely when `different` is false would retain old
countdowns and `observed_at`. Both proposed optimizations are removed from the plan.

All HTTP reads, including `/health`, use the same permits. A 30-second delivery limit cannot
promise one-second health availability while four deliveries still own all four permits.
The observable promise is bounded cancellation and recovery; one-byte reads of a 1 MiB
response alone do not prove blocking because the kernel may buffer the entire response.


The existing timer driver enforces a five-second minimum independently of the test's
short fallback configuration. The presentation test therefore waits on the refreshed STM
snapshot with a seven-second bound, rather than weakening cadence or sleeping as proof.

Composition previously cleared the HTTP child's origin list to avoid duplicate CORS
headers. That would erase mutation authorization after this change. Composed children now
retain the full policy; the outer middleware preserves the child's existing header. A
composed preview test proves the allowed console succeeds and a foreign origin refuses.

Mori has no registered network-uri source. The official Hackage version inventory and
upstream tag both identify 2.6.4.2 as the latest nondeprecated release (2.7.0.0 is deprecated).
Its source was inspected directly before adding the bounded `>=2.6.4.2 && <2.7` dependency
for URI authority parsing. Warp source discovered through Mori brackets connection closure
around application execution; the real socket test independently proves that behavior.

## Decision Log

- Decision: Keep configured origin authorization in composed HTTP children even when the
  outer composition supplies CORS. Share normalized URI comparison across all transports.
  Rationale: CORS header ownership must not erase the mutation policy. Existing-header
  preservation prevents duplicate response headers without clearing authorization.
  Date: 2026-10-25


- Decision: Check the request Origin against the configured allow-list or request origin,
  and accept confirmation bodies only as application/json (media-type parameters permitted).
  Rationale: This preserves the explicit confirmation protocol while rejecting cross-origin
  browser requests before execution; empty-body preview remains supported.
  Date: 2026-10-21
- Decision: Retain shared admission through bounded delivery; do not reserve a separate
  health slot. Propagate a delivery-expired exception after unwinding the response callback.
  Rationale: A retained permit bounds encoded-body memory. Expiry bounds occupation without
  claiming availability while the shared pool is saturated or attempting a second response.
  Date: 2026-10-21
- Decision: Keep per-refresh schema verification and fresh snapshot preparation.
  Rationale: There is no schema-generation invalidation mechanism or shared atomic refresh
  protocol in this plan. A TTL silently weakens refusal, and semantic equality does not imply
  identical presentation. Measure these costs and document the decision; any future shared
  verification/encoding design must preserve freshness and bounded cancellation first.
  Date: 2026-10-21

Revision note (2026-10-21): Corrected health acceptance, specified timeout termination,
withdrew stale schema/frame caching, and made retirement refusal deterministic.


## Outcomes & Retrospective

Foreign browser mutations are refused before body, verification and execution effects.
Nonempty confirmation bodies require JSON. Computation and delivery have independent
bounds, and health remains shared admission with recovery after cancellation. Tests cover
normal completion, caller cancellation, four occupied slots, one response per expired
request and actual Warp connection truncation. The wire 403/415 checks use the same real
loopback runner as deployments.

No schema TTL or semantic-only snapshot cache was introduced. Tests preserve each view's
fresh agreement check, current timer presentation and clock-only delta suppression. The
retirement code distinguishes cleanup from saturation without releasing capacity early.
ADR-53/56 now retain these durable rules; the guides include TLS proxy and composition
requirements. Runtime interference and the final release gate remain independent obligations.



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


M1 checks mutation admission in `Application.hs` before `readConfirmation`. When `Origin`
is present, parse one serialized origin and compare its scheme/host case-insensitively and
its effective port consistently against configured entries or the request's own scheme and
Host. Reject malformed/multiple/null origins unless an explicit supported policy allows them;
do not treat parse failure as absence. Use the same helper for HTTP, CORS and WebSocket
comparisons. Do not trust arbitrary forwarded headers; behind TLS termination the public
HTTPS origin must be explicitly allow-listed. Add 403 `origin_not_allowed` before any body
read or preview/execution side effect.

Require application/json for any nonempty confirmation body, accepting media-type parameters.
An empty body remains preview without a content type. Unknown/chunked lengths must not bypass
this rule: determine emptiness through the existing bounded body read inside the computation
deadline, and reject a nonempty unsupported type before decoding or executing. Preserve the
1 KiB cap and 400 malformed-confirmation response. Existing JSON confirmation tests must
supply the JSON header. Test allowed and denied origins, empty previews, nonempty no-header
and text/plain bodies, chunked bodies, and a throwing body callback that a foreign-origin
refusal never invokes.

M2 adds `deliveryDeadlineSeconds` to `InspectionLimits`, validates positivity and microsecond
representability in `Budget.hs`, and updates all direct constructors/examples. The computation
deadline still covers verification, execution and bounded encoding. Wrap the subsequent
`respond` callback in the separate delivery timeout inside `withInspectionAdmission`.
On expiry, unwind the callback, release the permit via the existing bracket, and throw a
private delivery-expired exception out of the application. Do not manufacture a
`ResponseReceived`, return normally after an incomplete response, convert it to a computation
504, or call respond again. Network/async exceptions must retain the same unwinding behavior.
Confirm the runner closes the connection on this path with a real socket test; dependency
source lookup through Mori is required before relying on host-server exception semantics.

Use a deterministic blocked respond callback with a one-second test deadline to prove that
four admitted requests occupy four slots, `/health` initially returns 503 inspection_busy,
then returns 200 within a bounded scheduling allowance after the callbacks are cancelled.
Assert exactly one respond invocation per request and no permit leak on normal completion,
expiry or caller cancellation. Separately start Warp on loopback with one slot and a
one-second delivery deadline. Use a small client receive buffer and a test response cap/body
large enough to exceed socket buffers, and explicitly establish the application remains in
delivery before starting the recovery observation. Stop that client from reading. After
expiry, verify termination/truncation and health recovery; do not infer backpressure merely
from reading one byte. Document the test's body/buffer sizes and use bounded synchronization,
not sleeps as proof of admission.

M3 keeps `readView` calling `checkFeedSchema` for every refresh and keeps WebSocket upgrade
verification. Use two active views and induce schema drift or loss of visibility between
successful reads; each subsequent refresh must check, refuse publication under RefuseOnDrift,
and recover only after successful verification. Keep failure results local to that failed
refresh, not cached success or an indefinite failure cache. The tests count completed
refresh verifications, not a fictional global handle tick. Retain the existing deadline and
cancellation tests and record the verification-cost rationale in the guide.

Keep preparing the fresh snapshot in `Feed/Driver.hs` even when semantic comparison yields no
update. Test two reads with identical timer identity/state but different database timestamps
and countdowns: the existing subscriber receives no delta and the sequence stays stable;
a new subscriber receives the second timestamp/countdown. This proves semantic diffing and
presentation freshness independently; pointer identity is not acceptance evidence.

Add a `FeedRetiring` acquire error mapped to the wire code `view_retiring` in the feed/socket
protocol path for a zero-reference retiring entry. Keep the entry and capacity accounting
until cancellation joins; do not wait under the registry lock. Test unsubscribe/resubscribe
while cleanup is deliberately blocked, then successful acquisition after cleanup. Update
`Protocol.hs`, WebSocket mapping and exhaustive matches together.

M4 completes the serve, stream and composition guides, including all Protocol.hs codes,
HTTP structured errors, the TLS allow-list requirement, configurable delivery bound and
shared health admission, per-refresh schema verification, fresh snapshots and retirement retry.
ADR-53's implementation wording changes only when bounded delivery actually lands; ADR-56
retains the per-refresh/fresh-presentation policy. Plan 320 owns changelog wording.


## Concrete Steps


From the repository root inside `nix develop`:

```bash
cabal build keiro-ops-http
cabal test keiro-ops-http-test --test-show-details=direct
just user-documentation-validate
just adr-validate
```

For a configured standalone test server with mutations enabled, exercise a known mutation
route (the queue need not exist because refusals precede command execution):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Origin: https://evil.example' \
  -H 'Content-Type: application/json' --data '{"confirm":"execute"}' \
  'http://127.0.0.1:8090/pgmq/dlq/read?queue=billing'
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: text/plain' \
  --data '{"confirm":"execute"}' 'http://127.0.0.1:8090/pgmq/dlq/read?queue=billing'
```

Expected codes are 403 and 415. The socket fixture in M2 is the reproducible delivery proof;
curl alone does not prove that response delivery is blocked.


## Validation and Acceptance


M1 requires refusal/allowed-case tests, no body or command side effects for foreign origins,
and the manual 403/415 check. M2 requires bounded delivery cancellation, exact permit return,
no second response, and real Warp connection termination. Under saturation health may return
503 before expiry; it must recover after the bounded work unwinds. The test uses a short
explicit deadline rather than assuming a 30-second default expires within one second.

M3 requires fresh verification on each of two views, drift/failure refusal and recovery,
clock-only refresh without a delta but with fresh resubscription presentation, and a distinct
retirement refusal followed by recovery. M4 requires complete guides and passing validators.
Existing composition and HTTP mapping tests must still pass after plan 317 removes the old
workflow work-limit error. No TTL/frame-cache performance result is claimed by this plan.


## Idempotence and Recovery

Source and documentation edits only; `git checkout` restores any file. The origin gate is
additive: a deployment that sets no `allowedOrigins` and receives no `Origin` header is
unaffected; one that is called cross-site from an allow-listed console keeps working because
the allow-list is consulted first. The delivery deadline defaults to 30 seconds and can be
raised by the host configuration if a legitimate client needs longer. Shared health admission
can refuse during that interval; the guide must state this. No successful schema observation
or clock-bearing snapshot is reused on the basis of elapsed time or semantic equality alone.


## Interfaces and Dependencies

`keiro-ops-http/src/Keiro/Ops/Http/{Application,Budget,Config,Cors,WebSocket,Feed,Feed/Driver,Protocol}.hs`;
`keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` (`verifyExpectedSchemaSession`, read
only); `warp`, `wai`, `websockets`; the HTTP test suite in `keiro-ops-http/test/`. The
`InspectionLimits` record gains `deliveryDeadlineSeconds`, which direct constructors must
supply; plan 320 records that in the changelog. The three HTTP guides are owned by this plan.
No prerequisite blocks this plan. It owns admission/delivery in Application.hs; plan 317
owns only workflow-error removal there. Plan 320 final acceptance and plan 303 tagging require
this plan Complete. ADR-40/53/56 retain fresh schema and presentation constraints.
