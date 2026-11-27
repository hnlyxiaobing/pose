# Project Card: pose (hnlyxiaobing/pose)

> Cache of measured state. Re-verify dated facts against the repo before trusting.
> Methodology lives in the skill; this card holds only per-project derived inputs + measured state.

## Docs
- Dev plan: `docs/2026-11-17-backend-neutral-facade-dev-plan.md`
- Test-system design: `docs/2026-11-17-test-system-design.md`
- CHANGELOG: `docs/CHANGELOG.md` (W1 created; W1 + W3 entries recorded)
- Stale doc references (`docs/API.md`, `docs/DECISIONS.md`) removed in W1 — no longer referenced anywhere.

## Gates (authoritative list per dev-plan §1 & test-design §9)
Five gates (wasm):
1. `moon check --deny-warn`
2. `moon build`
3. `moon test`
4. `moon fmt --check`
5. `moon info && git diff --exit-code -- pkg.generated.mbti cmd/main/pkg.generated.mbti`
- No sixth gate: `cmd/main` is a template (prints "Hello"), no CLI contract.
- `moon test --target native` is part of W2 parity, not a commit gate.

## Snapshot paths
- `pkg.generated.mbti`
- `cmd/main/pkg.generated.mbti`
(Enumerate with `git ls-files "*pkg.generated.mbti"`; currently 2.)

## Dependency map (work packages → acceptance)
- W1 (M0, P0, LANDED 2026-11-27): drift cleanup & self-containment. B2,B17,B18,B19,B20,B21. No API. T-W1-1..5. Commit ed6d066.
- W3 (M1, P1, LANDED 2026-11-27): fail-closed input hardening. B22 (nms non-finite), B23 (Int32 overflow, max_poses budget). No API. T-W3-1..5. max_poses_upper_bound=65536; Int64 in letterbox length/plan/sample + detect_multi budget. Commit b31766d.
- W2 (M2, P1, LANDED 2026-11-27): contract golden + dual-target equivalence. B4,B24. No API. T-W2-1..6. New `pose_golden_test.mbt` (8 golden), `tests/golden/README.md` registry, `pose_wbtest.mbt` truncation/mutation scans (1000 mutants, seeds 0x9E3779B97F4A7C15 / 0xD1B54A32D192ED03), `tools/verify.sh`.
- W4 (M2, P2, LANDED 2026-11-27): ROI firewall extension. B16 (partial). Additive API: `RoiRect`, `RoiTransform` (11 fields), `letterbox_roi`, `detect_roi`, `PoseResult::restore_roi`. T-W4-1..5. 9 tests. `letterbox_roi` is aspect-preserving only (detect_roi dispatches both modes).
- W5 (landed, P2): external oracle runner. `tools/numeric-oracle.sh` + `.sha256`. Acceptance T-W5-1..4. (Done: SKIPPED 78 path verified.)
- W6 (landed, P2): async facade. AsyncPoseBackend + detect_async/detect_multi_async. Acceptance T-W6-1..3. (Done.)

## Milestones
- M0: W1 — LANDED
- M1: W3 — LANDED
- M2: W2 (golden + dual-target) — LANDED; W4 (ROI) — LANDED
- ALL WORK PACKAGES W1–W6 DELIVERED 2026-11-27

## Measured state (verified 2026-11-27)
- HEAD: af74b8c (W2) → W4 commit pending
- `moon test`: 87/87 (wasm) and 87/87 (native), 0 skip
- All five gates green; `bash tools/verify.sh` → exit 78 = all green except oracle SKIPPED
- Snapshot: W4 diff is pure addition (5 new pub decls: detect_roi, letterbox_roi, restore_roi, RoiRect, RoiTransform); error variants still 8
- core.autocrlf=true; `git diff` empty after `moon info`; `.mbti` `M` status is EOL/stat noise
- Test files: pose_test.mbt (40), pose_golden_test.mbt (8), pose_async_test.mbt (2 async), pose_roi_test.mbt (9), pose_wbtest.mbt (28) = 87
- `docs/CHANGELOG.md` has W1 + W3 + W2 + W4 entries

## Next milestone
None — all work packages delivered. Remaining optional external work: run `tools/numeric-oracle.sh` with a legal out-of-repo model to record a real <1e-4 diff (explicitly SKIPPED by default).
