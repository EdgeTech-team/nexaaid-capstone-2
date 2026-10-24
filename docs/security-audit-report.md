# NexaAid — Security and Privacy Audit Report

**Date:** 24 October 2026
**System:** NexaAid (disaster relief coordination for Mandaue City) — FastAPI backend, Flutter app (web + Android), hosted on Render (backend), Neon (database) and Netlify (web app).
**Scope:** 24 findings (F-01 to F-24) covering security, privacy, data integrity and legal/compliance.

---

## 1. Executive summary (for the adviser)

We reviewed the NexaAid backend and app for security and privacy problems, one finding at a time. Each finding was investigated first, discussed, then fixed only after approval, with the full test suite run after every change. No change was deployed; this report is the hand-off before deployment.

**What was audited:** account sign-in and tokens, who can see and change which records, how donations and reports move through the system, file uploads and ID photos, guest-donor data, the public web pages, the server's settings, its logs, its third-party software, delivery records, and the privacy rights of the people whose data we hold.

**Findings by severity (24 total):**

| Severity | Count | Finding numbers |
|---|---|---|
| High | 1 | F-02 |
| Medium | 10 | F-01, F-03, F-04, F-06, F-07, F-08, F-09, F-10, F-11, F-13 |
| Low | 11 | F-05, F-12, F-14, F-15, F-16, F-17, F-18, F-19, F-21, F-23, F-24 |
| Informational | 2 | F-20, F-22 |

**What was fixed (code written, tested, awaiting deployment):** 19 findings fully, and 2 more in part. In plain terms, we closed the one high-severity issue (no limit on sign-in attempts, which let passwords and reset codes be guessed), stopped internal records and other people's data from leaking to the wrong users, made sign-in tokens stop working after a password change, encrypted the login token on phones, stopped guests from quietly changing the public data, tightened file uploads, added a server-wide limit on the public address search, locked down the public web settings and added a Content-Security-Policy, fixed how the server records who did what and from where, kept personal data out of the logs, updated and pinned all third-party software (removing 38 known vulnerabilities), and stopped staff email addresses from showing to barangay representatives.

**What is deferred, and why:**

- **F-11 (donor ID mandatory):** the adviser confirmed the government-ID requirement stays, because the manuscript declares it. No change. We verified ID photos are not reachable by public link and can only be viewed by Administrators.
- **F-18 (personal details in report descriptions):** needs Mandaue's input on how reports are validated and whether names belong in a public field. Deferred until the visit.
- **F-13 Part C (release signing key and final app ID):** pending the team's own build decisions. The insecure-connection risk itself is already fixed.
- **F-23 parts (a) and (b):** delivery destination flexibility and whether an Administrator may confirm receipt on a barangay's behalf — both are process questions for Mandaue.
- **F-24 (self-service data rights):** mostly a documentation task — a written data-privacy process — not a code problem. Recorded for the team and adviser.

**Overall:** NexaAid is in good shape. The security fixes are complete and tested; what remains is a planned deployment (with one data-cleanup review that must happen first), a short list of process questions for the Mandaue visit, and a few documentation and policy decisions for the team and adviser.

---

## 2. All 24 findings

| # | Finding (plain English) | Severity | Status | Decision made |
|---|---|---|---|---|
| F-01 | The public reference list exposed internal records (donations, deliveries, requests). | Medium | **Fixed** | Internal lists now go only to the staff role that uses them. |
| F-02 | No limit on sign-in or password-reset attempts, so passwords and reset codes could be guessed. | **High** | **Fixed** | 5 failed attempts, then a 15-minute wait, counted the same for unknown accounts. |
| F-03 | The "forgot password" page revealed whether an email had an account. | Medium | **Fixed** | Same answer whether or not the account exists. |
| F-04 | Any Disaster Unit member could replace the e-wallet payment details on any report. | Medium | **Fixed** | Restricted to the right role/owner. |
| F-05 | Barangay representatives could read other barangays' unvalidated reports. | Low | **Fixed** | A rep sees only their own barangay's. |
| F-06 | Inventory counts could go wrong when two updates happened at once. | Medium | **Fixed** | Updates are now safe under concurrency. |
| F-07 | A report-edit endpoint accepted any status change and kept no audit trail. | Medium | **Fixed** | Status is changed only by validate/reject/withdraw; every edit is logged. |
| F-08 | Deleting an account left some of the person's data behind. | Medium | **Fixed** | Deletion now anonymizes the person and removes ID photos; relief records stay under "Deleted User". Cleanup of older deleted accounts is a team decision. |
| F-09 | Guest donor data was taken without consent, validation or a retention rule. | Medium | **Fixed** | Consent is recorded (RA 10173); wording and retention period are for the team. |
| F-10 | Sign-in tokens stayed valid after a password change; the temporary-password rule was only enforced in the app. | Medium | **Fixed** | A password change ends every old session; the rule is enforced on the server. |
| F-11 | Every donor must upload a government ID, even though accounts are approved automatically. | Medium | **Deferred** | Adviser: ID stays mandatory (declared in the manuscript). Verified ID photos are Administrator-only and not publicly linkable. |
| F-12 | The login token was stored unencrypted on the device. | Low | **Fixed** | Stored in the Android Keystore / iOS Keychain. |
| F-13 | Release builds allowed insecure (non-HTTPS) connections and exposed developer settings. | Medium | **Fixed (A, B)** / **Deferred (C)** | Insecure connections and dev settings are blocked in release builds. The release signing key and final app ID are pending the team. |
| F-14 | Anyone could upload files without logging in, and orphan files were cleared only by hand. | Low | **Fixed** | Automatic cleanup after 25 hours (the 24-hour claim window plus 1 hour), and a 200 MB cap. A one-time review of production orphan files must happen before deploy. |
| F-15 | Guests could add new items to the public item list. | Low | **Fixed** | New items wait for CSWS Main Office / Administrator review. |
| F-16 | The old single-donation endpoint accepted any report, not just validated ones. | Low | **Fixed** | It now follows the same validated-only rule as the newer endpoints. |
| F-17 | Smaller sign-in weaknesses: donation references could be listed, guest cancellation could be probed, the cron token was compared unsafely. | Low | **Fixed** | QR-by-id is owner/staff only; one uniform answer plus a limit on guest cancel attempts; constant-time token check. |
| F-18 | Public report descriptions could expose names or household details of affected people. | Low | **Deferred — Mandaue** | Needs Mandaue's validation process; see the questions list. |
| F-19 | The public address-search proxy had no login and no limit, risking the free map provider blocking us. | Low | **Fixed** | A shared limit of 60 calls per minute; cached results don't count. |
| F-20 | API documentation and loose web settings were enabled in production; the web app had no content-security policy. | Info | **Fixed** | Docs hidden in production; credentials disabled in CORS; a tested Content-Security-Policy for the web app. |
| F-21 | Error messages and recorded visitor IP addresses depended on deployment settings we couldn't see. | Low | **Fixed** | Errors are generic in production; the real visitor IP is recorded safely behind the proxy. One check to run after deploy. |
| F-22 | Personal data could reach the logs, and third-party software wasn't pinned or up to date. | Info | **Fixed** | Email addresses masked in logs; search terms kept out of the access log; all packages pinned to one list; 38 known vulnerabilities removed. |
| F-23 | Delivery records had a few loose rules. | Low | **Fixed (c)** / **Mandaue (a, b)** | Staff emails no longer shown to barangay reps. Destination flexibility (a) and Administrator confirming for a barangay (b) are Mandaue questions. |
| F-24 | Users can't view, correct, export or delete their own data in the app. | Low | **Documentation** | Record a data-privacy (DPO) process; a "request deletion" button is a possible future enhancement. The deletion mechanism itself already exists and is tested. |

---

## 3. Known pre-existing issues (K-1 to K-6)

These are separate from the audit findings. K-1 to K-5 were already present before the audit; K-6 was discovered during the F-20 web test. None blocks the security fixes.

- **K-1:** A Flutter test, "Organization form: document upload and type dropdown," fails. Pre-existing UI test.
- **K-2:** A Flutter test, "account numbers follow provider standards," fails. Pre-existing.
- **K-3:** A Flutter test, "Edit fields: Other blocks letters," fails. Pre-existing.
- **K-4:** A Flutter test, "Edit fields: Bank number stops at 16 digits," fails. Pre-existing.
- **K-5:** A backend test about a not-home pickup stop fails only when run on a Wednesday (Manila time); a test-date quirk, not a real bug.
- **K-6:** On the **web app**, the camera stays on after leaving the QR scanner until the page is reloaded. The cause is in the third-party scanner library's web code; the Android/iOS apps are not affected. For now: on the web, reload after scanning, or scan with the Android app. Not reported to the library's maintainers (that is the team's call). To be raised with Mandaue (below).

---

## 4. Deployment checklist

Do these in order. The migrations must be applied to the database **before** the new backend goes live, and one data-cleanup review must be agreed **before** deploying.

### A. Before touching the production database (Neon)

0. **Render deploys automatically on every push to the `copy-develop` branch.** Do not push the audit work to `copy-develop` until the database migrations (step 8) are done — a push would put the new backend against the old database and requests would fail. Commit the audit work on its own branch and keep it off `copy-develop` until then. (Optionally, turn Auto-Deploy off during the change and deploy manually.)
1. Commit the work, keeping the `.claude/` folder out of the commit, and agree on the branch.
2. Make a Neon backup or branch.
3. Confirm the database is at the expected pre-audit version (`7f4d2b9e6a31`).
4. Run the read-only checks (queries the team runs themselves):
   - orphan upload files and storage used (F-14);
   - items in the "Other" category awaiting review (F-15);
   - accounts deleted before the F-08 fix;
   - validated report descriptions that may contain phone numbers or names (F-18);
   - the visitor-IP range check (F-21) — done 24 Oct 2026: the recorded public addresses are the hosting proxy's, not users'.

### B. Local checks (never against production)

5. In a throwaway local Postgres, run the "models match migrations" and "inventory concurrency" checks.
6. Both full test suites green, apart from the known issues (K-1 to K-5).
7. **Content-Security-Policy local test (F-20):** build the web app and serve it with the security headers; browse (don't submit) every screen in Chrome and Firefox, with the browser console clean. Done 24 Oct 2026; repeat after any change to the headers, the scanner library, or Flutter.

### C. Apply migrations, then deploy

8. Apply the two database migrations in order — first the guest-consent column (F-09), then the item-review column (F-15) — to Neon, and confirm the new version.
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

See the consolidated lists in sections 5 and 6.

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

---

## 7. Test results at the end of the audit

- **Backend:** 308 passed, 4 skipped. (The 4 skipped are environment-dependent tests that run only against a local Postgres container.)
- **Flutter (app):** 168 passed, 4 failed. The 4 failures are the pre-existing known issues K-1 to K-4.
- **Dependency vulnerability scan (pip-audit):** No known vulnerabilities found, after updating Pillow (image handling) and certifi (HTTPS trust) and removing unused packages. Before the update, the scan reported 38 known vulnerabilities across those two packages.
- **Known test-date quirk:** K-5 (a pickup test) fails only when run on a Wednesday, Manila time.

All fixes were verified by running these suites after each change. Nothing in this audit was staged, committed or deployed; that is the next step, following the checklist in section 4.
