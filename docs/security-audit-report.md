# NexaAid — Security and Privacy Audit Report

**Date:** 24 October 2026 (F-25, F-26 and K-7 added 26 October 2026)
**System:** NexaAid (disaster relief coordination for Mandaue City) — FastAPI backend, Flutter app (web + Android), hosted on Render (backend), Neon (database) and Netlify (web app).
**Scope:** 26 findings (F-01 to F-26) covering security, privacy, data integrity and legal/compliance.

---

## 1. Executive summary (for the adviser)

We reviewed the NexaAid backend and app for security and privacy problems, one finding at a time. Each finding was investigated first, discussed, then fixed only after approval, with the full test suite run after every change. No change was deployed; this report is the hand-off before deployment.

**What was audited:** account sign-in and tokens, who can see and change which records, how donations and reports move through the system, file uploads and ID photos, guest-donor data, the public web pages, the server's settings, its logs, its third-party software, delivery records, and the privacy rights of the people whose data we hold.

**Findings by severity (26 total):**

| Severity      | Count | Finding numbers                                                              |
| ------------- | ----- | ---------------------------------------------------------------------------- |
| High          | 1     | F-02                                                                         |
| Medium        | 10    | F-01, F-03, F-04, F-06, F-07, F-08, F-09, F-10, F-11, F-13                   |
| Low           | 13    | F-05, F-12, F-14, F-15, F-16, F-17, F-18, F-19, F-21, F-23, F-24, F-25, F-26 |
| Informational | 2     | F-20, F-22                                                                   |

**What was fixed (code written, tested, awaiting deployment):** 19 findings fully, and 2 more in part. In plain terms, we closed the one high-severity issue (no limit on sign-in attempts, which let passwords and reset codes be guessed), stopped internal records and other people's data from leaking to the wrong users, made sign-in tokens stop working after a password change, encrypted the login token on phones, stopped guests from quietly changing the public data, tightened file uploads, added a server-wide limit on the public address search, locked down the public web settings and added a Content-Security-Policy, fixed how the server records who did what and from where, kept personal data out of the logs, updated and pinned all third-party software (removing 38 known vulnerabilities), and stopped staff email addresses from showing to barangay representatives.

**What is deferred, and why:**

- **F-11 (donor ID mandatory):** the adviser confirmed the government-ID requirement stays, because the manuscript declares it. No change. We verified ID photos are not reachable by public link and can only be viewed by Administrators.
- **F-18 (personal details in report descriptions):** needs Mandaue's input on how reports are validated and whether names belong in a public field. Deferred until the visit.
- **F-13 Part C (release signing key and final app ID):** pending the team's own build decisions. The insecure-connection risk itself is already fixed.
- **F-23 parts (a) and (b):** delivery destination flexibility and whether an Administrator may confirm receipt on a barangay's behalf — both are process questions for Mandaue.
- **F-24 (self-service data rights):** mostly a documentation task — a written data-privacy process — not a code problem. Recorded for the team and adviser.
- **F-25 and F-26 (found 26 October 2026, after the main audit):** database migrations applied to production before their pull request was reviewed, and older differences between the production database and our migrations. Neither affects the app today; both need team decisions (section 6, items 13–16).

**Overall:** NexaAid is in good shape. The security fixes are complete and tested; what remains is a planned deployment (with one data-cleanup review that must happen first), a short list of process questions for the Mandaue visit, and a few documentation and policy decisions for the team and adviser.

---

## 2. All 26 findings

| #    | Finding (plain English)                                                                                                                    | Severity | Status                              | Decision made                                                                                                                                                      |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| F-01 | The public reference list exposed internal records (donations, deliveries, requests).                                                      | Medium   | **Fixed**                           | Internal lists now go only to the staff role that uses them.                                                                                                       |
| F-02 | No limit on sign-in or password-reset attempts, so passwords and reset codes could be guessed.                                             | **High** | **Fixed**                           | 5 failed attempts, then a 15-minute wait, counted the same for unknown accounts.                                                                                   |
| F-03 | The "forgot password" page revealed whether an email had an account.                                                                       | Medium   | **Fixed**                           | Same answer whether or not the account exists.                                                                                                                     |
| F-04 | Any Disaster Unit member could replace the e-wallet payment details on any report.                                                         | Medium   | **Fixed**                           | Restricted to the right role/owner.                                                                                                                                |
| F-05 | Barangay representatives could read other barangays' unvalidated reports.                                                                  | Low      | **Fixed**                           | A rep sees only their own barangay's.                                                                                                                              |
| F-06 | Inventory counts could go wrong when two updates happened at once.                                                                         | Medium   | **Fixed**                           | Updates are now safe under concurrency.                                                                                                                            |
| F-07 | A report-edit endpoint accepted any status change and kept no audit trail.                                                                 | Medium   | **Fixed**                           | Status is changed only by validate/reject/withdraw; every edit is logged.                                                                                          |
| F-08 | Deleting an account left some of the person's data behind.                                                                                 | Medium   | **Fixed**                           | Deletion now anonymizes the person and removes ID photos; relief records stay under "Deleted User". Cleanup of older deleted accounts is a team decision.          |
| F-09 | Guest donor data was taken without consent, validation or a retention rule.                                                                | Medium   | **Fixed**                           | Consent is recorded (RA 10173); wording and retention period are for the team.                                                                                     |
| F-10 | Sign-in tokens stayed valid after a password change; the temporary-password rule was only enforced in the app.                             | Medium   | **Fixed**                           | A password change ends every old session; the rule is enforced on the server.                                                                                      |
| F-11 | Every donor must upload a government ID, even though accounts are approved automatically.                                                  | Medium   | **Deferred**                        | Adviser: ID stays mandatory (declared in the manuscript). Verified ID photos are Administrator-only and not publicly linkable.                                     |
| F-12 | The login token was stored unencrypted on the device.                                                                                      | Low      | **Fixed**                           | Stored in the Android Keystore / iOS Keychain.                                                                                                                     |
| F-13 | Release builds allowed insecure (non-HTTPS) connections and exposed developer settings.                                                    | Medium   | **Fixed (A, B)** / **Deferred (C)** | Insecure connections and dev settings are blocked in release builds. The release signing key and final app ID are pending the team.                                |
| F-14 | Anyone could upload files without logging in, and orphan files were cleared only by hand.                                                  | Low      | **Fixed**                           | Automatic cleanup after 25 hours (the 24-hour claim window plus 1 hour), and a 200 MB cap. A one-time review of production orphan files must happen before deploy. |
| F-15 | Guests could add new items to the public item list.                                                                                        | Low      | **Fixed**                           | New items wait for CSWS Main Office / Administrator review.                                                                                                        |
| F-16 | The old single-donation endpoint accepted any report, not just validated ones.                                                             | Low      | **Fixed**                           | It now follows the same validated-only rule as the newer endpoints.                                                                                                |
| F-17 | Smaller sign-in weaknesses: donation references could be listed, guest cancellation could be probed, the cron token was compared unsafely. | Low      | **Fixed**                           | QR-by-id is owner/staff only; one uniform answer plus a limit on guest cancel attempts; constant-time token check.                                                 |
| F-18 | Public report descriptions could expose names or household details of affected people.                                                     | Low      | **Deferred — Mandaue**              | Needs Mandaue's validation process; see the questions list.                                                                                                        |
| F-19 | The public address-search proxy had no login and no limit, risking the free map provider blocking us.                                      | Low      | **Fixed**                           | A shared limit of 60 calls per minute; cached results don't count.                                                                                                 |
| F-20 | API documentation and loose web settings were enabled in production; the web app had no content-security policy.                           | Info     | **Fixed**                           | Docs hidden in production; credentials disabled in CORS; a tested Content-Security-Policy for the web app.                                                         |
| F-21 | Error messages and recorded visitor IP addresses depended on deployment settings we couldn't see.                                          | Low      | **Fixed**                           | Errors are generic in production; the real visitor IP is recorded safely behind the proxy. One check to run after deploy.                                          |
| F-22 | Personal data could reach the logs, and third-party software wasn't pinned or up to date.                                                  | Info     | **Fixed**                           | Email addresses masked in logs; search terms kept out of the access log; all packages pinned to one list; 38 known vulnerabilities removed.                        |
| F-23 | Delivery records had a few loose rules.                                                                                                    | Low      | **Fixed (c)** / **Mandaue (a, b)**  | Staff emails no longer shown to barangay reps. Destination flexibility (a) and Administrator confirming for a barangay (b) are Mandaue questions.                  |
| F-24 | Users can't view, correct, export or delete their own data in the app.                                                                     | Low      | **Documentation**                   | Record a data-privacy (DPO) process; a "request deletion" button is a possible future enhancement. The deletion mechanism itself already exists and is tested.     |
| F-25 | Two database changes were applied to the production database before their pull request was reviewed or merged, by someone other than the person who applies migrations. | Low      | **Process (team rule)**             | The changes (PR #95) are harmless and their author is known. New rule: one person applies migrations to Neon, and only after their pull request is merged. |
| F-26 | The production database has rules (checks, indexes, column sizes, delete rules) that our migrations don't create, so the tests can't catch code that breaks them. | Low      | **Planned (after deploy)**          | No effect on the app today. A follow-up migration will add the missing rules so every test database matches production; the team decides the notification-type length. |

### F-25 and F-26 (added 26 October 2026)

**F-25: Migrations applied to production before review (Low).** While preparing the deploy, we found the production database (Neon) at migration version `a1d4e7c9b2f5`, which was in no merged branch. Comparing Neon with a local copy at the last merged version (`7f4d2b9e6a31`) showed two added columns on donations (`pickup_dates`, `addition_no`) and one index. A team member then confirmed they come from two migrations in their open pull request #95 (`f2a9c4e7b1d3`, then `a1d4e7c9b2f5`). The migrations were applied to Neon while the pull request was still under review, and not by the person who normally applies migrations.

The changes only add columns and an index, and the live app is unaffected. The risk is the process:

- **Production can run ahead of reviewed code.** A mistake in an unreviewed migration (a dropped column, a wrong default) reaches real data before anyone has looked at it. If the pull request changes during review, production is left at a version no branch describes.
- **Nobody else could tell what production contained.** Until the author came forward, the version on Neon was unexplained. The audit nearly recorded a rebuilt file under the same version number, which would have broken migrations for everyone once #95 was merged.
- **Other work was blocked.** The audit migrations must run after `a1d4e7c9b2f5`, so they could not be finalized until #95 was merged into `copy-develop` (merged 26 October 2026).

We rate it Low because the changes are additive, their author is known, and no one outside the team was involved. It would rate higher if a migration applied this way had removed or rewritten data.

*Recommendation:* a team rule for production migrations, and a review of who holds database access (section 6, items 13–14).

**F-26: Production database rules our migrations don't reproduce (Low).** Neon was created by hand, before the team used migrations, and that original SQL was never saved. The tests' copy of that starting point (`backend/app/tests/sql/baseline_e837b545b195.sql`) was rebuilt on 3 October 2026 from the code, so it misses rules that existed only in the hand-made database. Comparing the two on 26 October 2026 found, on Neon only:

- extra checks on reports (allowed priority values, a rejection needs a reason, a validated or rejected report needs the staff member who decided, an extra "On Hold" status), on CMO decisions, and on DRRMO request statuses;
- 12 extra indexes (audit log, deliveries, CMO decisions, inventory, DRRMO requests, notifications);
- different column sizes: notification type 50 characters (the code says 100), notification title 255 (code: 200), CMO notes unlimited (code: 200);
- different delete rules on five links (audit log, CMO decisions ×2, notifications, delivery receipts).

Nothing the app does today breaks these rules. We checked every status the code writes and every delete it performs. The risk is that no test can see them: the tests build their database from the code, so a change that breaks a production-only rule passes every test and fails only after deploy. This has already happened once: withdrawing a report failed in production because of a status check no migration knew about (fixed by migration `a7c3e5f19b42`).

*Recommendation:* after the audit deploy, add one reconciliation migration that creates the missing checks and indexes only where they don't already exist. It changes nothing on Neon and makes every local and test database match production. Settle the column sizes in the same migration (section 6, item 16). Don't edit the frozen baseline file. Before each later deploy, repeat the same comparison: Neon's structure against a freshly migrated local copy.

---

## 3. Known pre-existing issues (K-1 to K-7)

These are separate from the audit findings. K-1 to K-5 were already present before the audit; K-6 was discovered during the F-20 web test; K-7 came in with PR #93 after the audit. None blocks the security fixes.

- **K-1:** A Flutter test, "Organization form: document upload and type dropdown," fails. Pre-existing UI test.
- **K-2:** A Flutter test, "account numbers follow provider standards," fails. Pre-existing.
- **K-3:** A Flutter test, "Edit fields: Other blocks letters," fails. Pre-existing.
- **K-4:** A Flutter test, "Edit fields: Bank number stops at 16 digits," fails. Pre-existing.
- **K-5:** A backend test about a not-home pickup stop fails only when run on a Wednesday (Manila time); a test-date quirk, not a real bug.
- **K-6:** On the **web app**, the camera stays on after leaving the QR scanner until the page is reloaded. The cause is in the third-party scanner library's web code; the Android/iOS apps are not affected. For now: on the web, reload after scanning, or scan with the Android app. Not reported to the library's maintainers (that is the team's call). To be raised with Mandaue (below).
- **K-7:** Three backend tests fail on `copy-develop` since PR #93 (`test_runthrough_gaps::test_main_office_hears_when_drrmo_completes_the_support`, `test_testing_fixes_oct19::test_7_5_drrmo_completes_only_after_in_transit_and_barangay_receipt`, `test_shared_logistics_notifications::test_both_teams_hear_every_logistics_step`). They still use the old flow where CSWS marks a DRRMO delivery In Transit, which PR #93's new rule blocks. Confirmed on `copy-develop` alone (at `41b0f66`), without the audit. Reported to the PR's author; not changed in the audit branch to avoid conflicts.

---

## 4. Deployment checklist

Do these in order. The migrations must be applied to the database **before** the new backend goes live, and one data-cleanup review must be agreed **before** deploying.

### A. Before touching the production database (Neon)

0. **Render deploys automatically on every push to the `copy-develop` branch.** Do not push the audit work to `copy-develop` until the database migrations (step 8) are done — a push would put the new backend against the old database and requests would fail. Commit the audit work on its own branch and keep it off `copy-develop` until then. (Optionally, turn Auto-Deploy off during the change and deploy manually.)
1. Commit the work, keeping the `.claude/` folder out of the commit, and agree on the branch.
2. Make a Neon backup or branch.
3. Confirm the database is at the expected pre-audit version, `a1d4e7c9b2f5` (PR #95's two migrations, on top of `7f4d2b9e6a31`; see F-25).
4. Run the read-only checks (queries the team runs themselves):
   - orphan upload files and storage used (F-14);
   - items in the "Other" category awaiting review (F-15);
   - accounts deleted before the F-08 fix;
   - validated report descriptions that may contain phone numbers or names (F-18);
   - the visitor-IP range check (F-21) — done 24 Oct 2026: the recorded public addresses are the hosting proxy's, not users'.

### B. Local checks (never against production)

5. In a throwaway local Postgres, run the "models match migrations" and "inventory concurrency" checks.
6. Both full test suites green, apart from the known issues (K-1 to K-5 and K-7).
7. **Content-Security-Policy local test (F-20):** build the web app and serve it with the security headers; browse (don't submit) every screen in Chrome and Firefox, with the browser console clean. Done 24 Oct 2026; repeat after any change to the headers, the scanner library, or Flutter.

### C. Apply migrations, then deploy

8. Apply the two database migrations in order — first the guest-consent column (F-09), then the item-review column (F-15) — to Neon, and confirm the new version. PR #95 must be merged first, so its migration files exist; Neon is already at `a1d4e7c9b2f5`, so upgrading to head runs exactly these two.
9. Deploy the backend only after the migrations.
10. On Render (at or before the deploy):
    - leave the secret key unchanged;
    - confirm the email settings;
    - keep `APP_ENV=production` (this hides error details and the API docs, and enables the correct visitor-IP handling);
    - **do not** set the proxy-trust setting to "trust everything";
    - only if a scheduled job calls the expiry endpoint, confirm its token is long, random and not in the code (F-17);
    - the build log must show the new packages installed from the single pinned list (including PyJWT, Pillow 13 and the updated certifi), each from a prebuilt wheel, with no errors, and the service starting with no "module not found."
11. Deploy the app (Netlify web + Android) at the same time as the backend.
    - On Netlify, ship the Content-Security-Policy in "report-only" mode first, check the live site's console on every screen (including a real registration with an upload), then switch it to enforcing mode in a second deploy.

### D. After deploy

12. Everyone signs in once more (expected, because of the token change).
13. Smoke tests:
    - a donor and CSWS can open a donation QR; signed out, the QR-by-id link is refused (F-17);
    - guest and registration address suggestions still work (F-19);
    - the API docs pages return "not found," and the web app's console shows no policy violations (F-20);
    - after one of your own audited actions, the newest recorded IP is your own public address, and a faked forwarded-IP header does not change it (F-21) — if it shows a Cloudflare address (Cloudflare sits in front of Render), set the proxy-hops setting to 2 and re-check;
    - the item-review feature works (F-15);
    - a search appears in the server log without the typed text (F-22).

### E. Decisions for the team and adviser (not code)

See the consolidated lists in sections 5 and 6 (F-25 and F-26: section 6, items 13–16).

---

## 5. Questions to bring to Mandaue

1. **Report validation process (the adviser's original question).** How does Mandaue validate and approve reports from disaster units? This underlies F-16, F-18 and F-23(b).
2. **F-18 — personal details in reports:**
   - a. Do reports need the **names** of affected people for validation? If yes, those should go in a staff-only field, not the public description.
   - b. When validating a report, should the Administrator **check the description for personal details**?
   - c. If a validated report has a mistake or personal details, **who corrects it, and how**?
3. **F-23(a) — delivery destination.** When goods for one barangay's report are delivered to a **different** barangay (for example an evacuation centre), who decides, and should the change be recorded? (If intended, we will likely keep the option and record each override.)
4. **F-23(b) — Administrator confirming for a barangay.** Should the Administrator be able to **confirm receipt and acknowledge aid on a barangay's behalf**, or is that the barangay's alone? (It weakens the barangay's independent confirmation.)
5. **K-6 — QR scanning on the web.** Does CSWS scan donor QR codes with the **web app** or the **Android app**? If the web app (or if scanning on the web is demonstrated at the defense), we will add the fix that turns the camera off when leaving the scanner.

---

## 6. Decisions for the team and adviser

1. **F-08 — old deleted accounts.** Decide whether to clean up accounts that were deleted before the F-08 fix.
2. **F-09 — guest consent.** Agree the consent wording and the retention period for guest data.
3. **F-11 — ID retention.** Government ID stays mandatory (confirmed). Decide how long ID photos are kept.
4. **F-13 Part C — release build.** Decide the final app ID and the release signing key.
5. **F-14 — production file cleanup (blocks deploy).** The team must review the orphan-file query results and agree before deploying, because the first run deletes them.
6. **Withdrawn-report notice.** Editing donations for a withdrawn report stays allowed; decide whether to add a donor notice (for example "This report has been withdrawn") and its wording.
7. **F-19 — address search.** Optionally self-host the map provider later (needs a server); a per-visitor limit becomes possible once the F-21 IP handling is verified in production.
8. **F-24 — data-privacy process.** Document a DPO / data-rights process: who the Data Protection Officer or contact is; how a user asks to view, correct, export or delete their data; how requests are verified; how fast they are handled; and that "delete" means anonymization with relief records retained. Fold in the F-09 and F-11 retention decisions. **Possible future enhancement:** a "request account deletion" button in the app (the deletion mechanism already exists).
9. **F-24 — manuscript/defense wording.** State the consent, the anonymize-on-delete behaviour, and the request process; have the adviser confirm any RA 10173 citations before putting them in the manuscript.
10. **Test data.** Cancel the test donation `DON-344913204065`, created during the web-app test.
11. **Note for the record.** On 20 October 2026, a few audited actions came from a backend run on a developer's own computer connected to the production database (the recorded IP was `127.0.0.1`). From now on, local backends use a local database only, and production corrections are made through the live API with an Administrator token.
12. **F-21 — visitor IPs before the deploy.** IPs recorded before the deploy are the hosting proxy addresses and cannot be corrected. If the audit log is presented, say IPs are reliable only from the deploy date, once the post-deploy check passes.
13. **F-25 — rule for production migrations.** One person (Mark) applies migrations to Neon, and only after the pull request that contains them has been reviewed and merged into `copy-develop`, in the deploy order of section 4 (migrations first, then the backend). To try a migration on real data, use a Neon branch (a copy of production), never production itself. If a migration is ever urgent, the team agrees first and the pull request is merged the same day. Before each deploy, the person applying migrations confirms that Neon's version matches the newest migration in `copy-develop`.
14. **F-25 — who holds Neon access.** List every person and place that can reach or manage the production database: members of the Neon project (web console); anyone signed in to Neon's command-line tool or holding a Neon API key (copy-develop's `.gitignore` lists `.neon/`, so someone uses Neon's tools from their own copy of the repository); the connection settings on Render (`DATABASE_URL`, `DIRECT_URL`); and every developer's `backend/app/.env`. Only Render and Mark's migration setup should keep the production connection; everyone else uses a local database or a Neon branch (as agreed in item 11). Changing the database password is not needed for F-25 now that the change is claimed, but do it if this list is narrowed, because anyone removed still knows the current password. Optionally drop the `playing_with_neon` sample table (harmless).
15. **F-26 — reconciliation migration.** Agree to add, after the audit deploy, one migration that creates Neon's missing checks and indexes where they don't exist (no change on Neon; local and test databases then match production), and to compare Neon's structure with a freshly migrated copy before each deploy. Decide who writes it and when.
16. **F-26 — notification type length (50 vs 100).** Production allows 50 characters for a notification type; the code says 100. Today's longest type is 29 characters, so nothing fails, but a longer one would pass every test and fail in production. Recommended: widen production to 100 in the reconciliation migration (widening never loses data). For the notification title (255 vs 200) and CMO notes (unlimited vs 200), production is already the larger one: keep it and change the code to match.

---

## 7. Test results at the end of the audit

- **Backend:** 308 passed, 4 skipped. (The 4 skipped are environment-dependent tests that run only against a local Postgres container.)
- **Flutter (app):** 168 passed, 4 failed. The 4 failures are the pre-existing known issues K-1 to K-4.
- **Dependency vulnerability scan (pip-audit):** No known vulnerabilities found, after updating Pillow (image handling) and certifi (HTTPS trust) and removing unused packages. Before the update, the scan reported 38 known vulnerabilities across those two packages.
- **Known test-date quirk:** K-5 (a pickup test) fails only when run on a Wednesday, Manila time.
- **After merging `copy-develop` with PR #93 (26 October 2026):** backend 328 passed, 3 failed, 4 skipped. The 3 failures are K-7 and also fail on `copy-develop` alone. Flutter unchanged: 168 passed, 4 failed (K-1 to K-4). These numbers will be updated after PR #95 is merged in and the migrations are re-chained.

All fixes were verified by running these suites after each change. The audit work is committed on the branch `audit/security-fixes` (pull request #92) and has not been deployed; deployment follows the checklist in section 4.

---

## 8. Notes from local testing (25 October 2026)

PR #92 was tested locally in Chrome against a fresh Postgres 16 database (`nexaaid_dev`, Podman), built from the baseline plus all migrations up to `c8e2f4a6b913`.

**Confirmed working:**

- **Migrations:** `7f4d2b9e6a31 → a1f09c3e5d72 → c8e2f4a6b913` ran without errors. (This was before PR #95. After #95, the chain becomes `7f4d2b9e6a31 → f2a9c4e7b1d3 → a1d4e7c9b2f5 → a1f09c3e5d72 → c8e2f4a6b913`, and will be rehearsed again before deploy.)
- **F-09:** submitting a guest donation without ticking the consent box is blocked with "Please agree to the processing of your personal data (RA 10173)". With consent ticked, the donation is recorded.
- **F-13:** the debug build shows the developer tools and server setting; the release build shows none, even after tapping About five times. The current production site still shows them, which is what F-13 fixes.
- **F-15:** a new item typed by a guest appears in the "New items to review" card for CSWS Main Office. Approving it empties the list and adds it to the item list.
- **F-22:** the server access log shows `?[hidden]` instead of query strings.

**UI notes for review (not security issues):**

1. **Consent checkbox position:** it sits between "Full name" and "Contact number". It would read more naturally after all the details, just before Submit.
2. **Consent wording for Drop Off:** the text mentions "pickup address", but a Drop Off donation collects no address.
3. **Dark mode contrast:** on the drop-off card, the text "Bring the goods and show your QR code at the CSWS office…" is hard to read in dark mode.

**Future note:** the map uses the public OpenStreetMap tile servers, which have a usage policy and are not meant for heavy use. Like the address search (F-19), a larger deployment would need its own tile provider.