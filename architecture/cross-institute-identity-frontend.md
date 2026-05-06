# Cross-Institute Identity — Frontend Implementation Plan

**Status:** Approved design, ready to implement
**Companion to:** [`cross-institute-identity.md`](./cross-institute-identity.md) (backend)
**Target implementer:** Claude Sonnet (or any frontend engineer)
**Last updated:** 2026-05-02

> Read the backend plan first. This document only covers UI changes; the *why* lives in the backend doc.

---

## 1. Goal

Make the AMS.PWA reflect the new global-identity model:

1. Registrars collect the data the matcher needs (`FirstName`, `LastName`, `DateOfBirth`, `Gender`, optional `Nic`, optional `PersonCode`, structured `Guardian`).
2. **Never display PII from other institutes.** Even if a returning student is linked behind the scenes, the institute UI shows only this institute's enrollment.
3. Optional `PersonCode` input gives parents a clean way to assert "this is the same student" across institutes without revealing where they came from.
4. New screens for the `GlobalIdentityAdmin` role: review queue, merge, split. Strictly isolated from the institute-scoped UI.
5. Same flow applies to instructor onboarding.

## 2. Non-Goals

- No frontend matching logic. The matcher runs on the backend; the PWA never scores duplicates.
- No "potential duplicate from another institute" UI for institute users. Ever.
- No i18n in this iteration (the codebase has no i18n today).
- No NFC hardware integration changes (existing text-input flow unchanged).

---

## 3. Current State (verified 2026-05-02)

### 3.1 Stack
- React 19.2.3, Vite 7.3.0, TypeScript 5.9.3
- TanStack Router (file-based, `routeTree.gen.ts`)
- Zustand for auth state (`src/stores/auth-store.ts`)
- TanStack React Query + Axios (`src/lib/api-client.ts`)
- React Hook Form + Zod
- Radix + shadcn/ui + Tailwind v4
- No i18n. Strings are inline.

### 3.2 Folder layout
- `src/routes/(auth)/` — public routes
- `src/routes/_authenticated/` — institute-scoped, JWT-gated
- `src/routes/(errors)/` — 401/403/404/500/503
- `src/features/<domain>/` — feature modules with `components/`, `index.tsx`, etc.
- `src/services/<domain>.service.ts` — Axios-based API clients
- `src/hooks/use-<domain>.ts` — React Query wrappers
- `src/types/<domain>.ts` — TS types
- `src/components/permission-guard.tsx` — `<PermissionGuard permission="..." />`

### 3.3 Existing student/instructor surface
- `src/features/students/components/student-form.tsx` — Zod schema fields: `email, studentCode, dateOfBirth, guardianName, guardianPhone, guardianEmail, address, enrollmentNumber, notes`. **All free-text guardian.**
- `src/services/student.service.ts` exposes `lookupIdentity({ email?, phone? })` returning `{ exists, userId? }`. **This is a PII leak risk** — see §5.6.
- `src/types/student.ts` mirrors backend DTOs.
- `src/features/users/` — global user management (admin-only).
- `src/features/cards/` — NFC card issuance, validation, listing. Card UID accepted as text input.
- No instructor enrollment form yet (verify; if absent it's added in this plan).
- No identity-matching, merge, or duplicate UI of any kind.

### 3.4 Auth & tenancy
- `useAuthStore` holds `user, accessToken, refreshToken, instituteId, roles, permissions`.
- `instituteId` is decoded from JWT (`institute_id` claim) and persisted.
- API client auto-injects `Authorization: Bearer …` and `X-Institute-Id`.
- UI gating via `<PermissionGuard permission="users:create">` etc.

---

## 4. Frontend Principles

These are non-negotiable.

1. **PII isolation in the response handler.** When a backend response indicates a link happened (or is pending), the PWA must NOT render any field originating from another institute. The student's view is always institute-local.
2. **Registration is non-blocking.** The registrar sees an immediate success. No spinner that waits for the matcher.
3. **`PersonCode` is the only cross-institute signal exposed to institute users.** It can be typed in (registration), displayed back (enrollment detail, NFC card), and printed (receipt, ID card). It never reveals which other institute issued it.
4. **Global identity admin UI is strictly separated** from institute UI. Different route group, different role, different navigation entry, different layout.
5. **Matching never happens client-side.** Don't ship trigram or phonetic logic to the browser. The frontend collects data and shows results from the backend.
6. **Forms validate format, not uniqueness.** Uniqueness is a backend concern. The PWA only enforces local rules (e.g., `PersonCode` regex, phone format hints).

---

## 5. UI Changes by Surface

### 5.1 Student registration form

**File:** `src/features/students/components/student-form.tsx`

Replace the current Zod schema. New shape:

```ts
const enrollSchema = z.object({
  // identity (sent to global ApplicationUser)
  firstName: z.string().min(1, 'First name is required.').max(100),
  lastName: z.string().min(1, 'Last name is required.').max(200),
  dateOfBirth: z.string().min(1, 'Date of birth is required for matching.'),
  gender: z.enum(['Male', 'Female', 'Other', 'PreferNotToSay']).optional(),
  nic: z.string().trim().optional(),                       // NEVER required
  personCode: z
    .string()
    .regex(/^P-\d{4}-\d{6}$/, 'Format: P-YYYY-NNNNNN')
    .optional(),                                            // optional re-enrollment shortcut
  email: z.string().email().optional().or(z.literal('')),  // optional for minors

  // institute-scoped
  studentCode: z.string().min(1),
  enrollmentNumber: z.string().optional(),
  address: z.string().optional(),
  notes: z.string().optional(),

  // guardians (structured — see GuardianPicker §6.3)
  guardians: z
    .array(
      z.object({
        guardianId: z.string().uuid().optional(),         // null = new guardian
        phoneNumber: z.string().min(1, 'Phone is required'),
        name: z.string().optional(),
        email: z.string().email().optional().or(z.literal('')),
        relationship: z.enum(['Father', 'Mother', 'Guardian', 'Sibling', 'Self', 'Other']),
        isPrimary: z.boolean(),
      })
    )
    .min(1, 'At least one guardian is required.'),
})
```

**Removed fields (do not collect):** `birthCertificateNumber` — not requested anywhere in the UI per project decision. The backend column exists but is opt-in for institutes that already collect it; out of scope for the PWA.

**DOB:** Required for the matcher to work. If genuinely unknown, registrar uses a "DOB unknown" toggle which submits `null` and triggers a banner explaining matcher will not auto-link without DOB. Bias the design toward collecting it.

**`PersonCode` field:**
- Optional, placed under a collapsed "Have you enrolled before? Enter your student ID" disclosure on the form.
- When entered AND format-valid, the form calls `useResolvePersonCode()` (see §7.4) and shows a green check (✓ "Existing record found") or a red ✗ ("ID not recognized — leave blank").
- The check returns ONLY a boolean; no PII (no name, no DOB, no other institute). This is enforced by the backend endpoint contract.
- Once validated, the form submits `personCode` and skips the matcher entirely on the backend.

**Submission response handling:**
- `POST /students` returns `{ enrollment, isLinkPending: boolean, personCode: string }`.
- The PWA renders enrollment details and a small status pill: **"Identity verification queued"** if `isLinkPending`, else **"Verified"**. No mention of any other institute.
- On the student detail page, the pill auto-refreshes every 5s for up to 60s while `isLinkPending`, then stops. (Use React Query `refetchInterval` with `enabled: isLinkPending`.)

### 5.2 Student detail page

**File:** `src/features/students/components/student-detail.tsx`

Add to the header:
- `<PersonCodeBadge code={student.personCode} />` — copy-to-clipboard, optional QR icon that opens a dialog showing a printable QR (encodes only the `PersonCode` string).
- `<IdentityVerificationPill state={isLinkPending ? 'pending' : 'verified'} />`.

Add a "Guardians" card listing structured guardians:
- Phone (formatted), name, relationship, primary badge.
- "Add guardian" button → opens `GuardianPicker`.
- Optional "Siblings at this institute" sub-list — same `Guardian.id` linked to other students in the **current institute only**. Backend filters by `CurrentInstituteId`. Cross-institute siblings are intentionally hidden.

### 5.3 Instructor enrollment form

**File:** `src/features/instructors/components/instructor-form.tsx` (create if missing)

Same identity fields as student (`firstName, lastName, dateOfBirth, gender, nic?, email?, personCode?`) plus instructor-specific (`designation, qualification, bio, joinDate, role, isActive`). Drop redundant `name`, `contactEmail`, `contactPhone` (they belong on `ApplicationUser`).

Guardian section is replaced with **"Contact"** (a `Self`-relationship guardian by default; one phone, one email).

### 5.4 NFC card UI

**File:** `src/features/cards/components/card-detail.tsx`

- Display the linked student's `personCode` next to their name. Provide a "Print card" action that includes `personCode` as a small QR + human-readable text.
- No backend change to NFC logic; cards remain scoped to enrollments.

### 5.5 PWA card-checking flow

No identity changes. Validation endpoint already returns `{ isValid, studentEnrollmentId, instituteId, cardStatus }`. The auto-merge re-points the enrollment FK transparently, so a returning student's card-check at the new institute Just Works.

### 5.6 Lock down the existing `lookupIdentity` flow

**Risk:** `student.service.ts → lookupIdentity({ email, phone })` currently returns `{ exists, userId }`. This leaks cross-institute existence to a registrar who guesses an email or phone.

**Fix:**
1. Remove `lookupIdentity` from the registrar's flow entirely. The matcher handles linking now.
2. Replace it with `resolvePersonCode({ personCode })` returning ONLY `{ valid: boolean }`. Used solely to validate the optional `personCode` field on the registration form. Backend endpoint must enforce: no name, no email, no other institute, no DOB in the response.
3. If a `lookupIdentity` consumer remains for any global-admin tool, gate it behind the global-admin policy — never expose to institute roles.

Update `src/services/student.service.ts` and `src/hooks/use-students.ts` accordingly.

---

## 6. New Components

### 6.1 `<PersonCodeBadge code={...} />`
**File:** `src/components/person-code-badge.tsx`

- Pill with monospaced text `P-2026-000123`.
- Click → copy to clipboard + toast.
- Optional QR icon button → modal showing QR (use `qrcode.react` — small dep) and a "Print" button that opens a print-friendly view via `window.print()`.

### 6.2 `<IdentityVerificationPill state="pending|verified" />`
**File:** `src/components/identity-verification-pill.tsx`

- Tooltip on hover explaining "Identity verification runs in the background to detect prior enrollment. No data is shared between institutes." Be deliberate about the wording — it must reassure without revealing anything.

### 6.3 `<GuardianPicker value={guardians} onChange={...} />`
**File:** `src/features/guardians/components/guardian-picker.tsx`

Multi-guardian editor. For each guardian row:
1. Phone input (formats as user types using `libphonenumber-js` — already light dep). On blur, the picker calls `useGuardianLookupByPhone(normalizedPhone)`:
   - If found in the **current institute scope**, prefill `guardianId, name, email`. Show "Existing guardian linked".
   - If not found, leave fields editable and submit creates a new `Guardian`.
2. Name (text), email (optional), relationship (select), primary toggle.
3. Add/remove rows. At least one row required, exactly one `isPrimary = true`.

The guardian lookup is **institute-scoped**. Guardians are not auto-shared across institutes through this picker; a new institute creates its own `Guardian` row even if the phone matches another institute. Only the matcher (server-side) considers cross-institute guardians, never the UI.

### 6.4 `<GenderSelect />`
**File:** `src/components/gender-select.tsx`

Wraps shadcn `Select`. Values match backend enum exactly: `Male | Female | Other | PreferNotToSay`.

### 6.5 `<NicInput />`
**File:** `src/components/nic-input.tsx`

Optional text input with a small format hint. No regional validation hardcoded — accept any non-empty trimmed string. Validation is server-side. Always optional in this app.

### 6.6 `<DobUnknownToggle />`
**File:** `src/features/students/components/dob-unknown-toggle.tsx`

Checkbox below DOB field: "Date of birth unavailable". When checked:
- Disables DOB input, sets value to `null`.
- Renders a yellow inline note: *"Without a date of birth, this student cannot be auto-linked to prior enrollments. Add it later when known."*
- This is the one place we actively educate the registrar on why DOB matters — without leaking PII.

---

## 7. Services & Hooks

### 7.1 New service: `guardian.service.ts`
**File:** `src/services/guardian.service.ts`

```ts
export const guardianService = {
  searchByPhone: (phone: string) => api.get<ApiResponse<Guardian | null>>('/guardians/lookup', { params: { phone } }),
  list: (params) => api.get<ApiResponse<PaginatedResponse<Guardian>>>('/guardians', { params }),
  create: (data: CreateGuardianRequest) => api.post<ApiResponse<Guardian>>('/guardians', data),
  link: (data: { userId: number; guardianId: string; relationship: GuardianRelationship; isPrimary: boolean }) =>
    api.post<ApiResponse<UserGuardian>>('/user-guardians', data),
  unlink: (id: string) => api.delete<ApiResponse<void>>(`/user-guardians/${id}`),
}
```

### 7.2 New service: `global-identity.service.ts`
**File:** `src/services/global-identity.service.ts`

Used only by the global-admin UI.

```ts
export const globalIdentityService = {
  listReview: (params) => api.get<ApiResponse<PaginatedResponse<IdentityReviewItem>>>('/global-identity/review', { params }),
  resolveReview: (id: string, body: ResolveReviewItemRequest) =>
    api.post<ApiResponse<void>>(`/global-identity/review/${id}/resolve`, body),
  merge: (body: MergePersonsRequest) => api.post<ApiResponse<void>>('/global-identity/merge', body),
  split: (body: SplitPersonRequest) => api.post<ApiResponse<void>>('/global-identity/split', body),
  getMergeAuditTrail: (userId: number) => api.get<ApiResponse<PersonMergeAudit[]>>(`/global-identity/users/${userId}/merge-audit`),
}
```

This service must include a header `X-Bypass-Institute-Scope: true` (or rely on the policy on the backend). Document the contract — backend enforces it regardless.

### 7.3 Update `student.service.ts`

- Remove `lookupIdentity`. Add `resolvePersonCode(code: string): Promise<{ valid: boolean }>` (or move to a new `identity.service.ts`).
- `enrollStudent(data: EnrollStudentRequest)` — drop `email`-required, drop free-text `guardianName/Phone/Email`, add structured `guardians[]`, add `gender`, `nic`, `personCode` fields.
- Response type extended with `personCode: string` and `isLinkPending: boolean`.

### 7.4 New hooks
**Files:** `src/hooks/use-guardians.ts`, `src/hooks/use-global-identity.ts`, `src/hooks/use-resolve-person-code.ts`

Standard React Query wrappers. `useResolvePersonCode` uses a debounced fetch (300ms) keyed by the input value, with `enabled: regex.test(value)`.

### 7.5 Types

**Files:** `src/types/guardian.ts`, `src/types/identity.ts`

```ts
// guardian.ts
export type GuardianRelationship = 'Father' | 'Mother' | 'Guardian' | 'Sibling' | 'Self' | 'Other'
export interface Guardian { id: string; phoneNumber: string; name?: string; email?: string; nic?: string }
export interface UserGuardian { id: string; userId: number; guardianId: string; relationship: GuardianRelationship; isPrimary: boolean }

// identity.ts
export type Gender = 'Male' | 'Female' | 'Other' | 'PreferNotToSay'
export type ReviewStatus = 'Pending' | 'Resolved' | 'Dismissed'
export type ReviewReason = 'TwinClusterDetected' | 'ScoreInReviewBand' | 'GenderConflict' | 'Other'
export type ResolvedAction = 'Linked' | 'NewPerson' | 'NeedsMoreInfo'

export interface IdentityReviewItem {
  id: string
  provisionalUserId: number
  candidateUserId?: number
  score: number
  reason: ReviewReason
  candidates: Array<{ userId: number; firstName: string; lastName: string; dateOfBirth?: string; personCode: string; score: number }>
  status: ReviewStatus
  resolvedByUserId?: number
  resolvedAt?: string
  action?: ResolvedAction
  createdAt: string
}
```

Update `src/types/student.ts` and `src/types/user.ts` to add the new identity fields.

---

## 8. Routing & Authorization

### 8.1 New route group: `_global-admin`

**Files:**
- `src/routes/_global-admin/route.tsx` — guard:
  ```tsx
  beforeLoad: () => {
    const { auth } = useAuthStore.getState()
    if (!auth.isAuthenticated()) throw redirect({ to: '/sign-in' })
    if (!auth.hasRole('GlobalIdentityAdmin')) throw redirect({ to: '/_authenticated' })
  }
  ```
- `src/routes/_global-admin/identity/review.tsx` — review queue list.
- `src/routes/_global-admin/identity/review.$id.tsx` — single item, with merge/dismiss actions.
- `src/routes/_global-admin/identity/users.$userId.merge-audit.tsx` — audit trail for a user.

The layout for `_global-admin` should look visually distinct (different header color, "GLOBAL ADMIN" badge) so an admin always knows when they're operating cross-institute.

### 8.2 Permission gates

Add to `<PermissionGuard>` usages:
- Review queue link in nav: `<PermissionGuard permission="identity:review">`.
- Merge/split buttons: `<PermissionGuard permission="identity:merge">`, `<PermissionGuard permission="identity:split">`.

Institute admins must NOT see the global-admin nav entry. Hide by role check, not just permission, since the backend strips `identity:*` perms when an institute context is present (defense in depth).

### 8.3 Auth store extension

`src/stores/auth-store.ts`:
- Add `auth.isGlobalIdentityAdmin: () => boolean` (returns `roles.includes('GlobalIdentityAdmin')`).
- No new instituteId logic — global admin endpoints are `BypassTenantFilters` on the server. The client can leave `X-Institute-Id` header empty or send it; the server ignores it for `/global-identity/*`.

---

## 9. Global Admin Screens (PII allowed here, audited)

### 9.1 Review queue list
**File:** `src/routes/_global-admin/identity/review.tsx`

Table columns: created at, provisional user (FirstName, LastName, DOB), top candidate (FirstName, LastName, DOB, PersonCode), score, reason, status. Filter by status (Pending/Resolved/Dismissed) and reason.

Row click → detail page.

### 9.2 Review item detail
**File:** `src/routes/_global-admin/identity/review.$id.tsx`

Two-pane layout: provisional user (left), top candidate(s) (right). Show all matching candidates with their score and gate-pass results. Visual indicators for which gates passed/failed (green/red dots).

Actions:
- **Link to candidate** — opens confirmation dialog showing the merge plan ("This will combine 2 enrollments, 1 NFC card, $X in payments, …"). On confirm calls `globalIdentityService.merge`.
- **Mark as new person** — calls `resolveReview({ action: 'NewPerson' })`. The provisional user keeps `IsCanonical = true`.
- **Needs more info** — leaves status pending, adds an internal note.

Every action shows a "Reason" textarea (free text, 200 chars) which is included in the audit log.

### 9.3 Merge audit trail
**File:** `src/routes/_global-admin/identity/users.$userId.merge-audit.tsx`

Timeline of every merge that touched this user (as canonical or duplicate). Each row links to the snapshot. Includes a `Split` action for any merge (gated by `identity:split`).

### 9.4 Direct merge (rarely used)
A "Merge two users" page with two `userId` inputs. Backend computes a preview (no PII shown until both are entered). Only used when the matcher missed a duplicate that the admin spotted manually.

---

## 10. Phased Implementation Plan

Mirrors the backend phases. Each phase = one branch, one PR.

### Phase 1 — Types & service shape (no UI behavior change)

**Goal:** Land all the new TS types and service signatures, even if backend isn't ready yet.

- Add `src/types/guardian.ts`, `src/types/identity.ts`.
- Update `src/types/student.ts`, `src/types/user.ts` with new fields (`personCode`, `gender`, `nic`, `dateOfBirth` on User).
- Stub `guardian.service.ts`, `global-identity.service.ts` with the right shape; behind a feature flag the existing screens still call old endpoints.
- No UI change yet.

**Acceptance:** `pnpm tsc --noEmit` passes, `pnpm build` succeeds.

### Phase 2 — Student form refactor

- Replace Zod schema with the new shape.
- Build `<GuardianPicker>` (with phone-lookup hook).
- Build `<GenderSelect>`, `<NicInput>`, `<DobUnknownToggle>`.
- Add the optional "Existing student ID" disclosure with `useResolvePersonCode`.
- Remove all calls to `lookupIdentity`.
- Update enroll mutation to send the new payload.
- Render `<PersonCodeBadge>` and `<IdentityVerificationPill>` in success state.

**Acceptance:** Manual test — register a student with all fields, verify payload matches backend contract, observe success without any cross-institute data in network response.

### Phase 3 — Student detail enhancements

- Add `<PersonCodeBadge>` to the header.
- Add `<IdentityVerificationPill>` with auto-refresh while pending.
- Add structured Guardians card; "Siblings at this institute" sub-list.
- Add "Print card" action including PersonCode QR.

**Acceptance:** Detail page shows guardians and siblings correctly. PII isolation verified — no other-institute hints in any response.

### Phase 4 — Instructor enrollment

- Create `src/features/instructors/` module mirroring `students/`.
- `instructor-form.tsx` — same identity fields, no guardians (just `Self` contact).
- `instructor-detail.tsx`.
- Route: `_authenticated/instructors/`.
- Service & hooks.

**Acceptance:** Register an instructor end-to-end. Identity fields hit the same matcher.

### Phase 5 — Global admin area

- Create `_global-admin` route group + guard.
- Distinct layout (header color, badge).
- Review queue list + detail screens.
- Merge confirmation dialog with preview.
- Audit trail page.
- Manual merge / split tooling.

**Acceptance:** As `GlobalIdentityAdmin`, resolve a review item by linking to a candidate. Verify cross-institute data is visible. As an institute admin, attempt to access `/_global-admin/*` — blocked by route guard, and even if URL is hand-crafted, the backend returns 403.

### Phase 6 — Polish & instrumentation

- Telemetry: log (without PII) counts of "registrations", "person-code-resolved", "review-items-resolved" via existing analytics if any.
- Error states for every new mutation.
- Loading skeletons for review queue and detail.
- Empty states.
- Print stylesheet for PersonCode QR.

---

## 11. Test Plan

### 11.1 Unit (Vitest)

`src/features/students/__tests__/student-form.test.tsx`:
- Validates Zod schema rejects missing `firstName`, `lastName`.
- DOB unknown toggle nullifies DOB and shows the warning banner.
- `personCode` regex: accepts `P-2026-000123`, rejects `p-2026-123` and `12345`.
- At least one guardian required; exactly one primary.

`src/features/guardians/__tests__/guardian-picker.test.tsx`:
- Phone lookup prefills name on hit.
- New guardian creates a row without `guardianId`.

`src/components/__tests__/person-code-badge.test.tsx`:
- Click copies value; toast fired.

### 11.2 Integration (Playwright or Cypress, whichever is set up — verify; if neither, add Playwright)

Scenarios — each scripts the full flow against a backend-double or stubbed API:

1. **Register a brand-new student.**
   - Fill all fields, submit, see success.
   - Network tab: no `X-Other-Institute*` headers in response. Response payload doesn't contain any `otherInstitute*` fields.
   - PersonCode badge displayed on detail page.
2. **Register with PersonCode.**
   - Type a valid `PersonCode`, see green check.
   - Submit. Detail page shows pill = "Verified".
3. **Register without PersonCode that auto-links in background.**
   - Pill shows "Pending" then refreshes to "Verified" after worker completes.
4. **Register two twins.**
   - Both succeed, both get distinct `personCode`s, neither is flagged on the registrar UI.
5. **Institute admin cannot access `/_global-admin/identity/review`.**
   - Direct URL navigation → redirected away.
6. **Global admin resolves a review item.**
   - Sees both provisional and candidate PII.
   - Confirms link; merge succeeds; audit trail shows new row.
7. **Lookup leak regression.**
   - Verify no UI surface displays an "exists at another institute" message at any point.

### 11.3 Manual QA checklist

- [ ] Print a card; scan the QR with a phone; verify it decodes to the `PersonCode` only.
- [ ] Register a student with DOB unknown; confirm yellow warning shown.
- [ ] Register with a deliberately malformed `PersonCode`; confirm form blocks submit.
- [ ] As global admin in `_global-admin`, verify the layout is visually distinct.
- [ ] Logout and back in; auth store reflects role correctly.

---

## 12. Accessibility & UX Notes

- `<PersonCodeBadge>` must have proper ARIA label (`aria-label="Person code, click to copy"`).
- The "DOB unknown" warning must use `role="status"` so screen readers announce it.
- Color is never the only signal: gate-pass dots in review detail include text (`Pass` / `Fail`), not just color.
- Keyboard navigation through `GuardianPicker` rows must support add/remove via focused buttons.
- Print stylesheet for `PersonCode` QR uses CSS `@media print` to hide nav and inflate the QR.

---

## 13. Privacy & PII Engineering Rules

These rules are part of the contract. Code reviews must enforce.

1. **No client-side cross-institute query.** The PWA never asks the backend "does this person exist at another institute?". The only allowed cross-institute query for institute users is `resolvePersonCode(code) → { valid: boolean }`.
2. **No rendering of fields whose origin is another institute.** If a backend response ever includes `otherInstituteName` or similar, it's a backend bug — file it, do not render.
3. **Logs must not include PII.** Sentry / console logs in error handlers must scrub `name`, `email`, `phone`, `nic`, `dateOfBirth` from payloads.
4. **Search params must not include PII.** No `?email=foo@bar.com` in URLs. Use POST bodies for lookups.
5. **`X-Institute-Id` header is sent from `_authenticated` only**, not from `_global-admin`. The global-admin Axios call should explicitly omit it (use a separate Axios instance if needed).

---

## 14. Open Questions

These do not block Phase 1 but should be answered before later phases:

1. **i18n.** Adding cross-institute identity flow is a good moment to introduce `react-i18next`. Decision: defer to a separate workstream; this plan ships English strings.
2. **QR library.** `qrcode.react` is recommended. Confirm bundle-size budget allows ~5KB gzip.
3. **PersonCode display on home dashboard.** Should an enrolled student's PersonCode appear on the institute admin's dashboard widgets? Likely yes for support; flag for product.
4. **Phone country default in `<GuardianPicker>`.** Default to `LK` (Sri Lanka) consistent with backend default. Confirm.
5. **Layout differentiation for `_global-admin`.** Banner color/icon TBD with design.

---

## 15. Out of Scope

- Self-service merge requests by end users.
- Mobile-native NFC reading (existing manual UID flow preserved).
- Bulk import / migration UI for existing data.
- Real-time notifications to global admins about new review items (handled via email/SMS on backend; in-app push is a future enhancement).

---

## 16. Implementation order summary

1. Phase 1 — types & service stubs
2. Phase 2 — student form refactor + new components
3. Phase 3 — student detail enhancements
4. Phase 4 — instructor enrollment surface
5. Phase 5 — global admin area
6. Phase 6 — polish, telemetry, print styling

Each phase ships independently. Backend phases 1–4 must be merged before frontend Phase 2 so the new endpoints exist.

---

## 17. Cross-references

- Backend plan: [`cross-institute-identity.md`](./cross-institute-identity.md)
- Existing security architecture: [`security-architecture.md`](./security-architecture.md) — extend the role/permission section with `GlobalIdentityAdmin` once Phase 5 lands.
- Existing API design: [`api-design.md`](./api-design.md) — add the new `/global-identity/*`, `/guardians`, `/user-guardians` endpoints once Phase 1 of the backend ships.
