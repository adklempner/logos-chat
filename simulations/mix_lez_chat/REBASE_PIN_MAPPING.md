# Rebase pin mapping — target → our work

When this rebase work was kicked off, the goal was to land the
chat-over-mix stack on a specific set of upstream commits / PRs. This
doc records, for each of those target pins, where it landed in our
forks and what we authored on top.

Companion docs:
- [README.md](README.md) — how to run the sim
- [SIMULATION_STAGES.md](SIMULATION_STAGES.md) — what happens at each stage

---

## The target pins

| # | Target | Status in our stack |
|---|---|---|
| 1 | `nim-libp2p v2.0.0` `c43199378f46` (tagged, merged) | Inherited |
| 2 | `nim-libp2p-mix` master `e314cdd5` | **DIVERGENT — we pin PR #14 (`50c4ab4fa788`)** |
| 3 | `logos-delivery` master `6837ae0c` | Inherited (past — our base is downstream) |
| 4 | `logos-delivery` PR #3931 (DoS plugin wiring + extracted mix) | Inherited via PR #3807 |
| 5 | `logos-delivery` PR #3807 (cover traffic) | Direct base |
| 6 | `mix-rln-spam-protection-plugin` PR #9 (stateless) | Direct base |
| 7 | Combined LEZ-RLN + stateless | Authored — 4 branches |

The rest of this doc expands each row.

---

## 1. nim-libp2p v2.0.0 `c43199378f46`

**Status:** inherited transitively. We did not bump any submodule for
this — both downstream consumers reach the same SHA.

- The mix-rln plugin's nimble file
  (`vendor/nwaku/vendor/mix-rln-spam-protection-plugin/mix_rln_spam_protection.nimble`)
  explicitly pins to this SHA:
  ```nim
  # nim-libp2p — Pinned to the same commit nim-libp2p-mix uses so the
  # diamond dep resolves to a single libp2p source. c43199378 is the
  # release/v2.0.0 tip (3 patch commits past the v2.0.0 bump).
  requires "https://github.com/vacp2p/nim-libp2p.git#c43199378f46d0aaf61be1cad1ee1d63e8f665d6"
  ```
- logos-delivery upstream/master at `6837ae0c` is the commit
  "feat: bump nim-libp2p to v2.0.0 (#3929)" itself, so PR #3807's base
  carries the bump for the nwaku side.
- The nimble diamond-dep collapse makes both consumers see one libp2p
  source, both at this SHA.

**Our work on top:** none directly. Chat-side source updates needed for
libp2p 1.15.3 (the `PrivateKey.random` signature change) are downstream
consequences — see Transitional Work below.

---

## 2. nim-libp2p-mix master `e314cdd5` — DIVERGENT

**Status:** we are NOT on master. We are on PR #14 (`50c4ab4fa788`),
which is a parallel branch.

- The mix-rln plugin's nimble file pins to PR #14 explicitly:
  ```nim
  # libp2p_mix — extracted into its own repo; previously libp2p/protocols/mix.
  # Tip of experiment/drop-nimble-lock (currently PR #14, stacked on top of
  # chore/bump-libp2p-v2.0.0). Pinned to the PR HEAD until the stack lands on
  # master; waku.nimble pins the same SHA to keep the diamond dep collapsed
  # to one libp2p_mix source.
  requires "https://github.com/logos-co/nim-libp2p-mix.git#50c4ab4fa788a33eb12a0a2cecaa708873352b58"
  ```
- Verified the two SHAs are on parallel branches (neither is an
  ancestor of the other) by `git merge-base --is-ancestor` checks
  against the upstream repo.
- Practical impact: PR #14 adds sink overrides, `AddressConfidence.Infinite`,
  deeper move-semantics propagation, and the lockfile-as-build-artefact
  cleanup. Master `e314cdd5` has none of these — it's only
  "chore: bump nix/deps.nix after bumping libp2p to v2.0.0 (#21)".

**Our work on top:** none. We inherit PR #14 via PR #9's nimble pin.

**Unwind path:** when PR #14 lands on master, both PR #9 (mix-rln
plugin) and any downstream nimble consumer can switch the pin from
`50c4ab4fa788` to whatever master tip carries the PR #14 stack — a
trivial bump.

---

## 3. logos-delivery master `6837ae0c`

**Status:** inherited (past). Our base is downstream of this commit.

- upstream/master HEAD at the time of the rebase: `6837ae0c feat: bump
  nim-libp2p to v2.0.0 (#3929)`.
- Our `rebase/lez-rln-on-3807` branch is parented on PR #3807 tip
  `92f1950e`, which contains 6 commits past `6837ae0c`:
  ```
  92f1950e chore(mix): use MixRlnSpamProtection.new constructor, bump plugin pin
  96907f5a fixup(mix): address PR #3807 review + sim alignment
  24f28cd9 feat(mix): cover traffic with constant rate
  8a7e02dc chore(deps): bump nim-json-rpc to upstream v0.6.1
  4ed6a1bf chore(mix): use MixRlnSpamProtection.new constructor, bump plugin pin
  d529be14 feat(mix): DoS protection + libp2p v2.0.0 + stateless RLN + tests (rebased onto #3935)
  ```
- The first three are the PR #3807 cover-traffic stack; the last three
  are the PR #3931 DoS-extracted-mix stack. Both are inherited.

**Our work on top:** none for this target specifically. Our work on the
nwaku side is layered on PR #3807's superset — see entries 5 and 7.

---

## 4. logos-delivery PR #3931 (DoS plugin wiring + extracted mix)

**Status:** inherited via PR #3807. PR #3807 is stacked on PR #3931.

PR #3931 contributes the bottom 3 commits of the 6-commit stack listed
above:
- `d529be14 feat(mix): DoS protection + libp2p v2.0.0 + stateless RLN + tests (rebased onto #3935)`
- `4ed6a1bf chore(mix): use MixRlnSpamProtection.new constructor, bump plugin pin`
- `8a7e02dc chore(deps): bump nim-json-rpc to upstream v0.6.1`

Notice the middle commit renames `newMixRlnSpamProtection` →
`MixRlnSpamProtection.new`. That rename ripples into the chat source —
see Transitional Work.

**Our work on top:** none directly. The chat-side source rename to
match the new constructor name happens as a Transitional Work item.

---

## 5. logos-delivery PR #3807 (cover traffic)

**Status:** direct base. Our `rebase/lez-rln-on-3807` branch starts here.

PR #3807 is a strict superset of PR #3931 — the top 3 commits of the
6-commit stack are PR #3807's cover-traffic-with-constant-rate plus
review fixups.

Our `rebase/lez-rln-on-3807` branch is one commit on top of PR #3807:
```
2ba4db45 deps: bump mix-rln plugin to feat/lez-rln-stateless (ba32e9f)
```

Just the nimble pin bump for the mix-rln plugin (see entry 6 for what
that plugin tip carries).

**Our work on top:** the 1-commit pin bump, plus the gifter port that
sits above this — see entry 7.

---

## 6. mix-rln-spam-protection-plugin PR #9 (stateless)

**Status:** direct base. Our `feat/lez-rln-stateless` branch starts at
PR #9 tip (`61ee3e5`).

PR #9 (in `logos-co/mix-rln-spam-protection-plugin`) replaces the
pmtree backend with a Nim-IMT stateless implementation, migrates to
zerokit 2.0.2, and bumps libp2p / libp2p_mix to the v2.0.0 line. It is
the foundation of the new stack on the plugin side.

Our `feat/lez-rln-stateless` adds 4 commits on top:
```
ba32e9f fix(onchain-lez): defensive add of witness-implied root at proof-gen time
b40a84a feat(rln): info-level proof markers + atomic root+proof refresh in pollLoop
607db30 cleanup(06-try-catch): remove dead try/except around {.raises: [].} await in pollLoop
deef3c4 feat(onchain-lez): LEZ-backed RLN spam protection for mix
```

These are the 4 LEZ-RLN commits that previously lived on
`feat/onchain-lez-group-manager` + the defensive root-add bug fix
(`d06aad7` / `7a05e6e` in the pre-rebase plugin history).

**Conflicts during the cherry-pick:** 2 manual resolutions on
`spam_protection.nim`:
- import block — UNION of HEAD's `std/[math, options, deques, times]` +
  ours' `std/[options, sequtils]` → `std/[math, options, deques, sequtils, times]`.
- 4 conflict regions resolved by taking our LEZ additions (export of
  `onchain_group_manager`, self-verify block in `generateProof`,
  `OffchainGroupManager`-guarded `loadTree`/`saveTree`).

Also dropped redundant `sp.messageIdCounter += 1` since PR #9's freed-id
reuse logic already handles increment in the allocation branch.

---

## 7. Combined LEZ-RLN + stateless

**Status:** authored. Four branches across four repos.

The original goal note said this branch "still doesn't exist on any
branch" — closing that gap was the bulk of the work.

| Branch | Repo | Tip | What it adds |
|---|---|---|---|
| `feat/lez-rln-stateless` | mix-rln-spam-protection-plugin (adklempner) | `ba32e9f` | PR #9 + 4 LEZ commits — see entry 6 |
| `rebase/lez-rln-gifter-on-3807` | logos-delivery (adklempner) | `81dd0b3` | PR #3807 + 4 commits |
| `feat/rln-stateless-v2.0.2` | logos-lez-rln (logos-co) | `cbac992` | rln 2.0.1→2.0.2 + stateless features |
| `rebase/sim-rln-gifter-on-new-stack` | logos-chat (adklempner) | `49c05e9` | submodule bumps + chat-side adaptation + sim infra |

### `rebase/lez-rln-gifter-on-3807` (nwaku)

4 commits on top of PR #3807 base `92f1950e`:
```
81dd0b37 fix(option_shims): import wherever valueOr is called on std/Option
ce04f936 cleanup: DRY bytesToHexUpper + dead-code removal + narrowed exception handling
f9313f37 feat(mix,rln-gifter): LEZ-backed RLN mix + 2-phase gifter protocol (rebased onto PR #3807; plugin via nimble)
2ba4db45 deps: bump mix-rln plugin to feat/lez-rln-stateless (ba32e9f)
```

- `2ba4db45` — plugin pin bump (entry 5).
- `f9313f37` — port of upstream `14562878` (42 files / 2774 insertions).
  Adapts the LEZ-RLN gifter protocol + `OnchainLEZGroupManager` wiring +
  5 new C FFI exports (`logosdelivery_set_rln_fetcher`, `_set_rln_config`,
  `_set_rln_identity`, `_push_roots`, `_push_proof`) onto PR #3807's
  `logos_delivery/*` layout. Key adaptation: the original commit added
  the plugin as a submodule; PR #3807 made it a nimble dep, so the
  `.gitmodules` add was dropped. `mountMix` signature now carries BOTH
  PR #3807's `disableSpamProtection` AND our `useOnchainLEZ`. Three
  3-way merges (node_factory.nim, waku_node.nim,
  waku_mix/protocol.nim).
- `ce04f936` — port of upstream `d7ccffc1` (cleanup commit, applied
  via cherry-pick).
- `81dd0b37` — fix for a latent PR #3807 bug surfaced when liblogoschat
  consumes the wider nwaku source (option_shims imports added across ~30
  files where `Option.valueOr` is called). See Transitional Work.

### `feat/rln-stateless-v2.0.2` (logos-lez-rln)

1 commit:
```
cbac992 feat(rln): bump rln crate to 2.0.2 + stateless feature only
```

Pinned in both `lez-rln/Cargo.toml` and `lez-rln/lez-rln-ffi/Cargo.toml`:
```toml
rln = { version = "2.0.2", default-features = false, features = ["stateless"] }
```

- No source changes needed — all call sites use stable rln APIs
  (`poseidon_hash`, `Fr`, `fr_to_bytes_le`, `bytes_le_to_fr`,
  `seeded_keygen`, `RLNWitnessInput`, `RLN`, `hash_to_field_le`) that
  are identical 2.0.1 → 2.0.2.
- C++ FFI surface (9 `rln_ffi_*` exports consumed by `logos-rln-module`)
  unchanged.
- The stateless feature flag is the load-bearing part: matches what the
  mix-rln plugin (Nim-IMT) expects, avoiding duplicate-symbol link
  errors at the chat dylib stage. PR #3807's Makefile comment
  ("Single zerokit archive (stateless features) for both relay and
  mix plugin") spells out why both archives must share the same feature
  set.

### `rebase/sim-rln-gifter-on-new-stack` (logos-chat)

The top-of-stack consumer. From `feat/sim-rln-gifter-auth-v2` diverged.
Significant commits (most recent first):
```
49c05e9 docs(sim): consolidate setup + README + stages
17cccd0 sim(setup): one-shot idempotent bootstrap from fresh clone
7a82ee5 docs(sim): reproducible setup guide from fresh clone to 4/4 PASS
1adde6c deps(nwaku): bump to 81dd0b3 (option_shims fixes across PR #3807)
707673f sim(mix_lez_chat): match plugin's renamed verify log line (PR #9)
5c8cc29 build(chat): wire up PR #3807 + zerokit 2.0.2 stateless + dedup pass
f20f71b refactor(chat): adapt imports + nim path for PR #3807 nwaku layout
d3ad696 deps: bump submodules to LEZ-RLN gifter + rln-stateless-v2.0.2
68a5e8b deps(nwaku): bump to rebase/lez-rln-on-3807 (2ba4db4)
```

These break down as:
- `68a5e8b` + `d3ad696` + `1adde6c` — submodule bumps (vendor/nwaku,
  vendor/logos-lez-rln).
- `f20f71b` + `5c8cc29` — chat-side source + build infra adaptation.
- `707673f` — sim marker grep update for PR #9's renamed log line.
- `7a82ee5` + `17cccd0` + `49c05e9` — sim infra + docs.

---

## Transitional work catalog

This is the work that the rebase forced us to do but doesn't belong to
any single target pin. Each item exists because a change in one of the
target pins surfaced an inconsistency, a latent bug, or a build-infra
mismatch elsewhere.

### Latent PR #3807 bugs surfaced by the chat consumer

- **`option_shims` imports across ~30 nwaku files.** `Option.valueOr` is
  called without the `waku/common/option_shims` import in many files
  PR #3807 ships. PR #3807's own `liblogosdelivery` build doesn't reach
  all those call sites, so the bug only surfaces when `liblogoschat`
  pulls a wider slice. Shipped as commit `81dd0b37` on
  `rebase/lez-rln-gifter-on-3807`.

### Build-infra changes from PR #3807's "single zerokit archive" design

- **Chat Makefile drops `vendor/nwaku/scripts/build_rln_mix.sh`.** PR #3807
  removes the separate `mix-librln` archive (see its Makefile comment:
  "Single zerokit archive (stateless features) for both relay and mix
  plugin. ... including a second archive built with different features
  causes duplicate-symbol link errors."). Our chat Makefile now copies
  the prebuilt `librln_v2.0.2.a` from
  `vendor/logos-lez-rln/logos-delivery/` (a side product of building
  `logos-rln-module` via nix) and runs `fix_mix_librln_dupes.sh` against
  it.
- **rust-bundle drops the `rln` rlib.** Both `libchat/double-ratchets`
  and zerokit's `rln` crate define `ffi_c_string_free`; rust-bundle was
  embedding both. Now it embeds only libchat.
- **`fix_mix_librln_dupes.sh` extended.** The dedup loop used to only
  cover symbols visible to system `nm`. Newer-rustc rcgu objects (LLVM
  bitcode produced by rustc 1.96+) aren't parseable by the bundled
  macOS `nm`, so `_rust_eh_personality` and other runtime symbols
  weren't being localized. Now we run `nmedit -R` directly with a
  fixed symbol list on the std-*.rcgu.o objects.

### PR #3807 reorg consequences in chat source

- **`waku/*` → `logos_delivery/waku/*`.** PR #3935 (a dep of PR #3807)
  reorganized the nwaku source tree into a `logos_delivery/` package.
  Chat source imports updated: `src/chat/utils.nim`,
  `src/chat/delivery/waku_client.nim`, `library/declare_lib.nim`,
  `config.nims`.
- **`libp2p/protocols/mix/*` → `libp2p_mix/*`.** PR #3807 / PR #3931
  extracted the mix protocol from `nim-libp2p` into its own
  `libp2p_mix` nimble package. Chat source updated:
  `src/chat/delivery/waku_client.nim`.
- **libp2p 1.15.3 `PrivateKey.random` signature change.** The new
  signature is `PrivateKey.random(T, libp2p_rng.newBearSslRng(rng))`
  rather than `(Secp256k1, crypto.newRng()[])`. Chat source updated:
  `src/chat/delivery/waku_client.nim` (now imports `bearssl/rand` +
  `libp2p/crypto/rng`).

### PR #3807 nimble lockfile drift on macOS / nimble 0.22.3

PR #3807's `nimble.lock` ships two entries that nimble 0.22.3's URL
handling fails to resolve on macOS (a bug where a `#`-prefix version
gets mangled into a tempdir path that's never created):

- **`nim` package sha1.** Our local checkout sees what nimble actually
  computes from the fetched tree (`a092a045d3a4...`), not what the
  lockfile claims (`68bb85cbfb18...`).
- **`bearssl_pkey_decoder` version revert.** PR #3807 ships
  `d34aa46bf9d0...` which triggers the URL bug. We revert to the prior
  pin `21dd3710df93...` (a clang-15 compile-only delta — semantically
  inert).

Both patches are LOCAL — never committed back. The
`patch_delivery_nimble_lock` helper in `setup_from_scratch.sh`
re-applies them idempotently.

### Stale-state cleanup hooks

PR #3807 dropped a swath of `vendor/nwaku/vendor/*` submodules in
favor of nimble deps. The OLD checkouts linger as untracked
directories in pre-PR-3807 working clones and confuse nim's path
resolution:

- **`rename_libp2p_carcass`.** Moves `vendor/nwaku/vendor/nim-libp2p`
  aside so chat's `config.nims` walker picks the nimble-resolved
  v2.0.0 libp2p instead.
- **`mirror_chat_nimbledeps`.** Mirrors the delivery-side
  `nimbledeps/pkgs2/` (populated by `make liblogosdelivery`) into
  `vendor/nwaku/` so the chat-side nim build can see nwaku's nimble
  deps on the import path. Strips obsolete-pin libp2p / websock
  variants.

### Plugin-side log-line rename

PR #9's stateless plugin emits the verify-success line as
`Proof verified successfully` instead of the legacy
`Spam protection proof verified successfully`. The sim's marker (3b)
grep was updated to match (commit `707673f` on
`rebase/sim-rln-gifter-on-new-stack`).

### Bootstrap automation

The above transitional fixes plus the existing per-build dependencies
were folded into `simulations/mix_lez_chat/setup_from_scratch.sh` —
idempotent + sourced by `run_simulation_lgx.sh` so its auto-build paths
get the prep for free.

---

## Quick-reference: branch tips

For grep-friendliness:

```
logos-chat         rebase/sim-rln-gifter-on-new-stack    49c05e9
logos-delivery     rebase/lez-rln-gifter-on-3807         81dd0b3
logos-lez-rln      feat/rln-stateless-v2.0.2             cbac992
mix-rln-plugin     feat/lez-rln-stateless                ba32e9f
```

Upstream pin SHAs we depend on (transitively or via nimble):

```
nim-libp2p (vacp2p)              c43199378f46    [target, hit]
nim-libp2p-mix (logos-co)        50c4ab4fa788    [via PR #14 — NOT master e314cdd5]
logos-delivery base (PR #3807)   92f1950e        [past upstream/master 6837ae0c]
mix-rln plugin base (PR #9)      61ee3e5         [feat/stateless-rln]
```
