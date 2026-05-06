# Cross-Institute Identity — Final Implementation Plan

**Status:** Approved design, ready to implement
**Target implementer:** Claude Sonnet (or any engineer)
**Owner of the design:** discussed with project owner; this document is the source of truth
**Last updated:** 2026-05-02

> Read this document in full before writing any code. It describes both the *what* and the *why*. The why matters when you hit edge cases — fall back to the principles, not your own judgement.

---

## 1. Goal

Allow a single real human to be enrolled at multiple institutes (as student or instructor) with a single underlying global identity, while:

1. **Working for minors with no NIC, no email, no birth certificate.** Birth certificates must NOT be requested — they're a UX tax we refuse to impose.
2. **Correctly distinguishing twins** with the same DOB, same parent, same last name, no strong identifiers. The only thing differing is `FirstName`.
3. **Never leaking PII across institutes.** Institute B's registrar must never see that this student exists at Institute A. Linking happens silently, in the background.
4. **Supporting the same flow for instructors.** `InstructorEmployment` follows the same model.

## 2. Non-Goals

- Re-architecting tenancy. The existing `IInstituteContext` + EF query filter model is correct and stays.
- Replacing `ApplicationUser`. It already plays the role of the global Person.
- Building merge UX for institute admins. Merges are global-admin-only.
- Importing identity data from external authorities. Out of scope.

---

## 3. Current State (as of 2026-05-02)

Verified by reading the codebase. Use these as ground truth.

### 3.1 Identity entities

- `AMS.Domain/Entities/User/ApplicationUser.cs` — extends `IdentityUser<long>`. Carries `Guid UserId` (stable opaque id, auto-generated in property initializer), `FirstName`, `LastName`, audit fields, and a `DocketId`. **No `DateOfBirth`, `NIC`, `PersonCode`.** `Email` (from IdentityUser) is globally unique via Identity defaults.
- `AMS.Domain/Entities/Student/Entity/StudentEnrollment.cs` — `Guid` PK; FKs `long UserId`, `Guid InstituteId`. Fields include `StudentCode`, `DateOfBirth`, free-text `GuardianName/Phone/Email`, `Address`, `EnrollmentNumber`, `Status`. Unique on `(UserId, InstituteId)` and `(StudentCode, InstituteId)`.
- `AMS.Domain/Entities/Instructor/Entity/InstructorEmployment.cs` — `Guid` PK; FKs `long UserId`, `Guid InstituteId`. Carries a redundant `Name` plus `ContactEmail/Phone`, `JoinDate`, `IsActive`. Unique on `(UserId, InstituteId)`.
- `AMS.Domain/Entities/Institute/Entity/InstituteUser.cs` — join table mapping users to institutes with `InstituteRole` enum. Unique on `(InstituteId, UserId)`.

### 3.2 Tenancy

- `AMS.Application/Interfaces/Institute/IInstituteContext.cs` — `Guid? CurrentInstituteId` from JWT claim or header.
- `AMS.Infrastructure/Database/ApplicationDbContext.cs` — applies `HasQueryFilter` to scope `StudentEnrollment`, `InstructorEmployment`, `Class` by `CurrentInstituteId`. Has `BypassTenantFilters` flag for background jobs. `OnModelCreating` calls `ApplyConfigurationsFromAssembly` then `ApplyTenantQueryFilters` (lines 123–144). Domain events published in `SaveChangesAsync` via `PublishDomainEventsAsync` (line ~159).

### 3.3 Migrations

- `AMS.API/AMS.Infrastructure/Persistence/Migrations/`
- Single greenfield migration: `20260501143551_InitialMigration.cs`. All tables prefixed `ams_`, schema `public`.

### 3.4 Service Bus

- `appsettings.json` (lines 35–51) configures topics: `transaction-events`, `charging-events`, `notification-events`. We will add `identity-events`.

### 3.5 What's missing

- No `DateOfBirth`, `NIC`, or human-readable `PersonCode` on `ApplicationUser`.
- No `Guardian` entity. Guardian data is free-text on `StudentEnrollment` — siblings cannot share a normalized guardian.
- No identity matching service, no merge tooling, no background worker for matching.
- No `GlobalIdentityAdmin` role. All current roles are institute-scoped via `InstituteRole` enum.

---

## 4. Final Architecture

### 4.1 Principles (read these first)

1. **`ApplicationUser` IS the global Person.** No new Person entity. We enrich `ApplicationUser` with the missing identity fields.
2. **Enrollments are per-institute.** `StudentEnrollment` and `InstructorEmployment` already have the right shape. Don't change their cardinality.
3. **Guardians are normalized.** A `Guardian` entity owns the phone number; siblings share via a join table.
4. **Matching is async and PII-isolated.** Registrar gets immediate success; matching happens in a background worker that runs as a system principal with `BypassTenantFilters = true`. Match results never surface to institute admins.
5. **When in doubt, do not auto-merge.** A wrong merge corrupts attendance/fees data for two real humans. Splitting is possible but every split is a failure of the matcher.
6. **First name is a gate, not a tiebreaker.** Twins with same DOB / same guardian must remain separate Persons.
7. **Birth certificates are not used.** Even though we keep an optional column, never prompt for them, never depend on them.

### 4.2 Enrich `ApplicationUser`

Add these fields to `ApplicationUser` (file: `AMS.Domain/Entities/User/ApplicationUser.cs`):

| Field | Type | Nullable | Notes |
|---|---|---|---|
| `DateOfBirth` | `DateOnly?` | yes | Strongly encouraged at registration. Without it, gate-based matching fails — only strong identifiers can match. |
| `Gender` | `Gender?` (new enum) | yes | Used as a hard veto in matching: mismatched gender → never auto-merge. Values: `Male`, `Female`, `Other`, `PreferNotToSay`. |
| `Nic` | `string?` | yes | National ID. **Partial unique** index `WHERE Nic IS NOT NULL`. |
| `BirthCertificateNumber` | `string?` | yes | Optional, never prompted. Partial unique. Kept for institutes that already collect it. |
| `PersonCode` | `string` | no | System-generated, human-readable, printable. Format: `P-{YYYY}-{6-digit-sequence}`. Globally unique. Stable forever (do not regenerate on merge). |
| `IsLinkPending` | `bool` | no, default `true` | Flipped to `false` after the matcher has processed this user. |
| `IsCanonical` | `bool` | no, default `true` | After a merge, the duplicate's row stays in the DB (audit) with `IsCanonical = false`, `IsDeleted = true`. |
| `MergedIntoUserId` | `long?` | yes | If `IsCanonical = false`, points to the surviving canonical user. |

Add domain methods:
- `static ApplicationUser CreateProvisional(...)` — creates a new user with `IsLinkPending = true`, generates `PersonCode`.
- `void MarkLinked()` — sets `IsLinkPending = false`. Called after matcher completes.
- `void MarkMergedInto(long canonicalUserId)` — sets `IsCanonical = false`, `IsDeleted = true`, `MergedIntoUserId`. Called by merge service.
- `void UpdateIdentityProfile(DateOnly? dob, Gender? gender, string? nic, string? birthCert)` — for admin corrections.

**`PersonCode` generation.** Use a PostgreSQL sequence `ams_person_code_seq` and format in C#:

```csharp
public static string GeneratePersonCode(long sequenceValue, DateTime utcNow) =>
    $"P-{utcNow:yyyy}-{sequenceValue:D6}";
```

Create the sequence in the migration (`SELECT setval('ams_person_code_seq', 1)` initial). Allocate a value via `_db.Database.SqlQueryRaw<long>("SELECT nextval('ams_person_code_seq')")`. Do this *before* persisting the user so the column is non-null on insert.

### 4.3 Move `DateOfBirth` from `StudentEnrollment` to `ApplicationUser`

DOB is a property of the human, not the enrollment. The migration must:
1. Add `DateOfBirth` (and other identity columns) to `ApplicationUser`.
2. Backfill: `UPDATE ams_users SET "DateOfBirth" = (SELECT "DateOfBirth" FROM ams_student_enrollments WHERE "UserId" = ams_users."Id" LIMIT 1) WHERE EXISTS (...)`.
3. Drop `DateOfBirth` from `StudentEnrollment`.

Update `StudentEnrollment.Create` to no longer accept `dateOfBirth`. Update `UpdateProfile` to no longer take it. Callers update DOB via a new `UpdateUserIdentity` flow on `ApplicationUser`.

### 4.4 Normalize guardians

New entities under `AMS.Domain/Entities/Guardian/`:

**`Guardian`** (`Entity/Guardian.cs`):
```
Guid Id (PK)
string PhoneNumber (required, unique after E.164 normalization)
string? Name
string? Email
string? Nic
audit fields (use BaseAuditableDomainEntity<Guid>)
```

**`UserGuardian`** (join):
```
Guid Id (PK)
long UserId (FK ApplicationUser)
Guid GuardianId (FK Guardian)
GuardianRelationship Relationship  (enum: Father, Mother, Guardian, Sibling, Self, Other)
bool IsPrimary
audit fields
Unique (UserId, GuardianId)
```

Place enum at `AMS.Domain/Shared/Enums/GuardianRelationship.cs`.

**Phone normalization.** Before insert/lookup, normalize to E.164 (e.g. `+94771234567`). Store both `PhoneNumber` (normalized) and optionally `PhoneNumberOriginal`. Use `libphonenumber-csharp` NuGet package. The unique index is on `PhoneNumber` (normalized form).

**Backfill.** Migrate `StudentEnrollment.GuardianName/Phone/Email` to `Guardian` + `UserGuardian` rows. Strategy:
1. Group existing enrollments by normalized `GuardianPhone`.
2. Create one `Guardian` per unique phone, with the most-recent name/email.
3. Create one `UserGuardian` per enrollment linking the enrollment's `UserId` to the new `Guardian` with `Relationship = Guardian, IsPrimary = true`.
4. Drop `GuardianName/Phone/Email` columns from `StudentEnrollment`.

Same applies to `InstructorEmployment.ContactPhone/Email` — but for instructors, the relationship is `Self`. Drop `Name`, `ContactEmail`, `ContactPhone` from `InstructorEmployment` after backfill (use `ApplicationUser.FirstName/LastName` and `Email` instead). Keep `Designation`, `Qualification`, `Bio`, `JoinDate`, `IsActive` — those are employment-scoped.

### 4.5 NFC cards stay enrollment-scoped

`NfcCard.StudentEnrollmentId` is correct and unchanged. Cards are issued by an institute. After a merge, the card's enrollment FK is re-pointed transparently (because the duplicate's enrollment moves to the canonical user — see §6.3).

### 4.6 New role: `GlobalIdentityAdmin`

Create a global role outside `InstituteRole`:
- Stored as an `ApplicationRole` row with name `GlobalIdentityAdmin`.
- Seeded in migration.
- Granted permissions: `identity:review`, `identity:merge`, `identity:split`, `identity:read-pii-cross-institute`.
- This role bypasses institute scope (the relevant endpoints set `BypassTenantFilters = true` after authorization).

**Institute admins must NOT have these permissions.** Add a guard in `PermissionService` that strips `identity:*` permissions if the user is acting under any `InstituteUser` context.

---

## 5. Matching Algorithm — Authoritative Spec

### 5.1 Inputs to a match attempt

Constructed at registration time:

```csharp
public record MatchInput(
    long ProvisionalUserId,
    string FirstName,
    string LastName,
    DateOnly? DateOfBirth,
    Gender? Gender,
    string? Nic,
    string? Email,
    string? PersonCode,            // optional — student-supplied
    Guid? BirthCertificateId,
    IReadOnlyList<Guid> GuardianIds,  // resolved Guardian rows by normalized phone
    DateTime AttemptedAt
);
```

### 5.2 Decision pipeline

Run in this exact order. First terminal outcome wins.

```
STAGE 1 — STRONG PATH
  if PersonCode matches an existing canonical user → AUTO-LINK
  if Nic matches                                    → AUTO-LINK
  if Email matches (and not in family-email allowlist) → AUTO-LINK

STAGE 2 — HARD VETOES (eliminate candidates)
  remove candidate if Gender present on both sides and differs
  remove candidate if DateOfBirth present on both sides and differs

STAGE 3 — GATE PATH (must pass ALL three gates)
  Gate A — FirstName:
    trigram_similarity(input.FirstName, candidate.FirstName) >= 0.85
    OR DoubleMetaphone(input.FirstName) == DoubleMetaphone(candidate.FirstName)
  Gate B — DateOfBirth:
    both present AND exact match
  Gate C — Guardian:
    candidate has at least one GuardianId in input.GuardianIds

  if any gate fails → candidate is NOT a match

STAGE 4 — TWIN-CLUSTER DETECTION
  let cluster = SELECT users WHERE DateOfBirth = input.DateOfBirth
                AND EXISTS (UserGuardian where GuardianId IN input.GuardianIds)
                AND IsCanonical = true
  if cluster.Count >= 2:
    raise FirstName gate to: trigram >= 0.92 AND DoubleMetaphone match AND Gender match
    if any candidate still passes → REVIEW QUEUE (never auto-merge inside a twin cluster)

STAGE 5 — COMPOSITE SCORE (only for candidates that passed all gates)
  base = 0.70  // gates passed
  + 0.10 if LastName trigram >= 0.85
  + 0.10 if Gender both present and match
  + 0.05 if OtherNames similarity >= 0.70  // if/when OtherNames is added
  + 0.05 if Address similarity >= 0.70

STAGE 6 — DECISION
  if STAGE 1 hit                  → AUTO-LINK (confidence 1.0)
  if score >= 0.92 AND not in cluster → AUTO-LINK
  if score in [0.75, 0.92)        → REVIEW QUEUE
  if score < 0.75                  → NEW PERSON (matcher leaves provisional user as canonical, sets IsLinkPending = false)
```

### 5.3 PostgreSQL extensions required

In Migration 1:
```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram similarity
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch; -- Double Metaphone
```

### 5.4 Candidate query (sketch)

```sql
SELECT u."Id", u."FirstName", u."LastName", u."DateOfBirth", u."Gender", u."Nic",
       similarity(u."FirstName", @firstName) AS first_name_sim,
       similarity(u."LastName", @lastName) AS last_name_sim,
       dmetaphone(u."FirstName") AS first_name_dm
FROM ams_users u
JOIN ams_user_guardians ug ON ug."UserId" = u."Id"
WHERE u."IsCanonical" = true
  AND u."IsDeleted" = false
  AND u."Id" <> @provisionalUserId
  AND ug."GuardianId" = ANY(@guardianIds)
  AND (u."DateOfBirth" IS NULL OR u."DateOfBirth" = @dob)
  AND (u."Gender" IS NULL OR @gender IS NULL OR u."Gender" = @gender)
  AND (
        similarity(u."FirstName", @firstName) >= 0.85
        OR dmetaphone(u."FirstName") = dmetaphone(@firstName)
      )
GROUP BY u."Id";
```

This MUST run with `BypassTenantFilters = true`.

### 5.5 Family email allowlist

Some parents register all children with the same email. To avoid auto-linking three siblings to one user when they share a parent's email, do not strong-match on Email alone if the email is already attached to ≥ 2 canonical users. In that case, fall through to the gate path.

---

## 6. Background Pipeline

### 6.1 Event flow

```
Registration command (StudentEnrollment or InstructorEmployment)
  └─> Domain event raised on ApplicationUser: IdentityMatchRequestedEvent { UserId, Source = Student|Instructor, EnrollmentId }
       └─> MediatR handler in AMS.Application publishes to Service Bus topic 'identity-events'
            └─> IdentityMatchingWorker consumes (subscription 'identity-matcher')
                 ├─ runs matching pipeline
                 ├─ if AUTO-LINK → MergePersonsCommand (system principal)
                 ├─ if REVIEW QUEUE → insert IdentityReviewItem row, send notification to GlobalIdentityAdmin
                 └─ if NEW PERSON → MarkLinked()
```

### 6.2 New Service Bus topic

In `appsettings.json`:
```json
"AzureServiceBus": {
  "Topics": {
    ...
    "IdentityEvents": "identity-events"
  },
  "Subscriptions": {
    ...
    "IdentityMatcher": "um-identity-matcher"
  }
}
```

### 6.3 Merge transaction (idempotent)

`IIdentityMergeService.MergeAsync(long canonicalUserId, long duplicateUserId, MergeReason reason, string actorId)`:

```
BEGIN
  set _instituteContext.BypassTenantFilters = true
  if duplicateUserId.IsCanonical = false → return (already merged)

  for each table with FK UserId:
    StudentEnrollment, InstructorEmployment, InstituteUser, Payment, Attendance,
    Notification, AuditLog, Docket, ApplicationUserRole, ApplicationUserClaim,
    ApplicationUserLogin, ApplicationUserToken, UserGuardian
  do:
    UPDATE table SET UserId = canonical WHERE UserId = duplicate
    handle unique constraint (UserId, InstituteId) clashes:
      - StudentEnrollment: keep earliest EnrollmentDate, latest Status, merge Notes; delete duplicate enrollment
      - InstructorEmployment: keep earliest JoinDate, latest IsActive; delete duplicate employment
      - InstituteUser: keep highest InstituteRole; delete duplicate
      - UserGuardian: ON CONFLICT DO NOTHING

  duplicateUser.MarkMergedInto(canonical)  // sets IsCanonical=false, IsDeleted=true, MergedIntoUserId
  insert PersonMergeAudit { canonicalId, duplicateId, score, reason, actorId, timestamp, snapshotJson }

COMMIT
```

Make idempotent: re-running with the same args is a no-op after the first commit.

### 6.4 Split (admin-only undo)

`SplitPersonCommand` accepts a `PersonMergeAudit.Id`, restores the duplicate by:
1. Set `IsCanonical = true`, `IsDeleted = false`, `MergedIntoUserId = null`.
2. Re-point any FKs that were originally on the duplicate, using the snapshot JSON in the audit record.
3. Insert a new `PersonMergeAudit` row with reason `Split` for traceability.

Splits are rare. Keep the snapshot JSON for at least 1 year.

### 6.5 Review queue

New entity `IdentityReviewItem` (`AMS.Domain/Entities/Identity/Entity/IdentityReviewItem.cs`):
```
Guid Id
long ProvisionalUserId
long? CandidateUserId          // top candidate
double Score
ReviewReason Reason            // TwinClusterDetected | ScoreInReviewBand | GenderConflict | Other
string CandidatesJson          // serialized list of all candidates with scores
ReviewStatus Status            // Pending | Resolved | Dismissed
long? ResolvedByUserId
DateTime? ResolvedAt
ResolvedAction? Action         // Linked | NewPerson | NeedsMoreInfo
```

Endpoint: `GET /api/global-identity/review` (lists pending), `POST /api/global-identity/review/{id}/resolve` (body: `{ action, candidateUserId? }`).

Authorization: `[Authorize(Policy = "GlobalIdentityAdmin")]`. The endpoint sets `BypassTenantFilters = true` after authz.

---

## 7. Phased Implementation Plan

Each phase is independently shippable and reviewable. Do them in order.

### Phase 1 — Schema for global identity (foundation)

**Goal:** Enrich `ApplicationUser`. No behavior change yet.

Files:
- `AMS.Domain/Entities/User/ApplicationUser.cs` — add fields, methods.
- `AMS.Domain/Shared/Enums/Gender.cs` — new enum.
- `AMS.Infrastructure/Database/Configurations/User/ApplicationUserConfiguration.cs` (create if absent) — partial unique indexes via `HasIndex(...).HasFilter(...)`.
- `AMS.Infrastructure/Persistence/Migrations/<timestamp>_EnrichApplicationUserIdentity.cs` — generated via `dotnet ef migrations add`.

Migration must:
- Create extensions: `pg_trgm`, `fuzzystrmatch`.
- Create sequence `ams_person_code_seq`.
- Add columns `DateOfBirth`, `Gender`, `Nic`, `BirthCertificateNumber`, `PersonCode`, `IsLinkPending`, `IsCanonical`, `MergedIntoUserId`.
- Backfill `PersonCode` for existing users using sequence values.
- Add partial unique indexes on `Nic`, `BirthCertificateNumber`. Unique index on `PersonCode`.
- After backfill, alter `PersonCode` to `NOT NULL`.

EF index syntax for partial unique:
```csharp
builder.HasIndex(u => u.Nic)
    .IsUnique()
    .HasFilter("\"Nic\" IS NOT NULL");
```

**Acceptance:**
- `dotnet build AMS.slnx` passes.
- `dotnet ef database update` runs the new migration cleanly on a populated dev DB.
- Existing users get a `PersonCode`. New `ApplicationUser` creation flow allocates a `PersonCode`.
- Inserting two users with the same non-null `Nic` fails with a unique-violation. Inserting two users with NULL `Nic` succeeds.

### Phase 2 — Move `DateOfBirth` and add `Guardian`

**Goal:** DOB lives on the Person. Guardians are normalized.

Files:
- `AMS.Domain/Entities/Guardian/Entity/Guardian.cs` — new.
- `AMS.Domain/Entities/Guardian/Entity/UserGuardian.cs` — new.
- `AMS.Domain/Shared/Enums/GuardianRelationship.cs` — new enum.
- `AMS.Domain/Entities/Guardian/Interfaces/IGuardianRepository.cs` — new.
- `AMS.Infrastructure/Repositories/Guardian/GuardianRepository.cs` — new.
- `AMS.Infrastructure/Database/Configurations/Guardian/*.cs` — EF configs.
- `AMS.Infrastructure/Database/ApplicationDbContext.cs` — add `DbSet<Guardian>`, `DbSet<UserGuardian>`.
- `AMS.Application/Services/Phone/IPhoneNormalizer.cs` + impl in Infrastructure using `libphonenumber-csharp`.
- `AMS.Domain/Entities/Student/Entity/StudentEnrollment.cs` — remove `DateOfBirth`, `GuardianName`, `GuardianPhone`, `GuardianEmail`. Update `Create` and `UpdateProfile` signatures.
- `AMS.Domain/Entities/Instructor/Entity/InstructorEmployment.cs` — remove `Name`, `ContactEmail`, `ContactPhone`. Update `Create` and `Update`.
- All command handlers and DTOs that reference removed fields — update to either pass through to `ApplicationUser` (DOB) or to `UserGuardian` (guardian fields).
- `AMS.Infrastructure/Persistence/Migrations/<timestamp>_NormalizeGuardiansAndMoveDob.cs`.

Migration must:
- Create `ams_guardians` and `ams_user_guardians` tables.
- Backfill DOB: `UPDATE ams_users u SET "DateOfBirth" = se."DateOfBirth" FROM ams_student_enrollments se WHERE u."Id" = se."UserId" AND se."DateOfBirth" IS NOT NULL`.
- Backfill guardians: insert one `Guardian` per unique normalized phone (use a CTE), then one `UserGuardian` per `StudentEnrollment` with non-null guardian phone.
- Backfill instructors as `Self` relationships from `InstructorEmployment.ContactPhone`.
- Drop `DateOfBirth`, `GuardianName`, `GuardianPhone`, `GuardianEmail` from `ams_student_enrollments`.
- Drop `Name`, `ContactEmail`, `ContactPhone` from `ams_instructor_employments`.

**Acceptance:**
- All existing tests pass after refactoring command/handler signatures.
- A query for "all users with guardian phone X" returns the correct set after backfill.
- Three sibling users sharing a guardian phone produce 1 `Guardian` row + 3 `UserGuardian` rows.

### Phase 3 — Identity matching service (no background yet)

**Goal:** Pure synchronous matching service that anyone can call. No worker, no merge yet.

Files:
- `AMS.Application/IdentityMatching/IIdentityMatchingService.cs` — interface.
- `AMS.Application/IdentityMatching/Models/MatchInput.cs`, `MatchResult.cs`, `MatchCandidate.cs`, `MatchDecision.cs` (enum: `AutoLink | ReviewQueue | NewPerson`).
- `AMS.Infrastructure/Services/IdentityMatching/IdentityMatchingService.cs` — implementation following §5.2 exactly.
- `AMS.Infrastructure/Services/IdentityMatching/TwinClusterDetector.cs`.
- `AMS.Infrastructure/Services/IdentityMatching/NameSimilarity.cs` — wraps `pg_trgm` and `dmetaphone` calls via raw SQL or `EF.Functions.TrigramsSimilarity` if available.
- DI wiring in `AMS.Infrastructure/DependencyInjection.cs`.

The service must:
- Always set `_instituteContext.BypassTenantFilters = true` while running.
- Return a `MatchResult` with `Decision`, top `Candidate`, and full ranked list. **It does not mutate state.**
- Be unit-testable without a real Service Bus.

**Acceptance:** Unit tests cover (use fixtures, no real DB needed for pure scoring; integration tests for the SQL-bound pieces):
- Twin scenario: two users with same DOB + shared guardian + different first names → both kept separate.
- Re-enrollment: same first name + DOB + guardian → AUTO-LINK.
- Twin re-enrollment: cluster of 2 detected, same FirstName trigram 0.93, DM match, gender match → REVIEW QUEUE (never auto-merge inside a cluster).
- Gender mismatch + everything else matching → NEW PERSON.
- Strong path: matching `Nic` overrides everything else → AUTO-LINK.
- Family email: an email shared by 2 existing users → fall through to gate path (no email auto-link).
- Missing DOB on candidate → gate B fails → NEW PERSON unless strong path.

### Phase 4 — Background worker + Service Bus wiring

**Goal:** Async pipeline. Enrollment fires an event; worker resolves it.

Files:
- `AMS.Domain/DomainEvents/Identity/IdentityMatchRequestedEvent.cs`.
- `AMS.Application/EventHandlers/Identity/IdentityMatchRequestedHandler.cs` — relays to Service Bus.
- `AMS.Infrastructure/BackgroundServices/IdentityMatchingWorker.cs` — `BackgroundService` consuming the subscription. On each message: open scope, call `IIdentityMatchingService`, then call merge or insert review item or just `MarkLinked`.
- `appsettings.json` + `appsettings.Development.json` — add the new topic/subscription.
- `Program.cs` — register the hosted service.
- `AMS.Application/Commands/Student/RegisterStudent/RegisterStudentCommandHandler.cs` (and Instructor equivalent) — at the end of registration, raise `IdentityMatchRequestedEvent` on the `ApplicationUser` aggregate.

**Acceptance:**
- Registering a new student fires the event, the worker picks it up within 5s in dev, and `IsLinkPending` flips to `false`.
- Worker is idempotent: replaying the same message produces no duplicate state change.
- Worker dead-letters poisoned messages after 3 failures; no infinite loops.

### Phase 5 — Merge / split / review queue

**Goal:** Tooling for the auto-link decision and global-admin overrides.

Files:
- `AMS.Domain/Entities/Identity/Entity/IdentityReviewItem.cs`.
- `AMS.Domain/Entities/Identity/Entity/PersonMergeAudit.cs`.
- `AMS.Application/Commands/Identity/MergePersons/MergePersonsCommand.cs` + handler + validator.
- `AMS.Application/Commands/Identity/SplitPerson/SplitPersonCommand.cs` + handler + validator.
- `AMS.Application/Queries/Identity/ListReviewItems/ListReviewItemsQuery.cs` + handler.
- `AMS.Application/Commands/Identity/ResolveReviewItem/ResolveReviewItemCommand.cs` + handler.
- `AMS.Api/Controllers/GlobalIdentityController.cs` — extends `BaseApiController`, gated by `[Authorize(Policy = "GlobalIdentityAdmin")]`.
- `AMS.Infrastructure/Services/Permission/PermissionService.cs` — strip `identity:*` permissions when current principal has any `InstituteUser` claim attached.
- Seed `GlobalIdentityAdmin` role + permissions (`identity:review`, `identity:merge`, `identity:split`, `identity:read-pii-cross-institute`) in the seeder.

**Acceptance:**
- Merging two users transactionally re-points all FKs and survives a unique-constraint clash on `(UserId, InstituteId)`.
- Audit row written for every merge with snapshot JSON.
- Split restores the previous state from the audit snapshot.
- Institute admin (no global role) gets 403 on review endpoints.
- An institute admin who is *also* a `GlobalIdentityAdmin` can only use the global endpoints from a session without an institute context (verify via integration test).

### Phase 6 — Registration UX changes (no PII leak)

**Goal:** Registrar-facing flow honors PII isolation. `PersonCode` becomes an optional input.

Files:
- `AMS.Application/Commands/Student/RegisterStudent/RegisterStudentCommand.cs` — add optional `PersonCode`. If present, `RegisterStudentCommandHandler` resolves it to an existing canonical `ApplicationUser` and creates a new `StudentEnrollment` against it directly (no provisional user, no matcher needed). Wraps in transaction.
- Same for `RegisterInstructorCommand`.
- API DTOs and PWA forms — add optional `PersonCode` field labeled "Existing student ID (if any)".
- The registration response **must not** indicate whether a match was found. It returns the institute-local enrollment view only. The link, if any, happens silently in the background.
- Audit log entry on registration must NOT include any cross-institute identifiers (e.g. don't log "linked to existing user from Institute X").

**Acceptance:**
- Registering with a valid `PersonCode` skips the matcher and links directly.
- Registering without a `PersonCode` always returns success immediately. Background worker resolves the link within seconds.
- Inspecting the API response with browser devtools reveals no other-institute identifiers.

---

## 8. Test Plan

### 8.1 Unit tests (no DB)

In `AMS.Tests/IdentityMatching/`:
- `MatchingPipelineTests.cs` — covers all decision branches in §5.2 with hand-rolled fixtures.
- `TwinClusterDetectorTests.cs`.
- `PersonCodeGeneratorTests.cs` — format, no collisions across years.
- `PhoneNormalizerTests.cs` — Sri Lankan numbers `077...`, `+94 77...`, etc.

### 8.2 Integration tests (Testcontainers PostgreSQL)

In `AMS.Tests/Integration/IdentityMatching/`:
- `RegisterAtTwoInstitutesAutoLinksTest.cs` — same person registers at A then B with same first name, DOB, and parent phone → second registration's enrollment ends up pointing to the first user's `Id` after the worker runs.
- `TwinsRegisterAtSameInstituteTest.cs` — Alice and Bob register; verify two distinct `ApplicationUser` rows.
- `TwinReEnrollsAtSecondInstituteTest.cs` — Alice (twin) re-enrolls at B; verify item lands in review queue, not auto-merged.
- `MergeIdempotencyTest.cs`.
- `SplitRestoresStateTest.cs`.
- `InstituteAdminCannotSeeReviewQueueTest.cs`.
- `RegistrationResponseHasNoCrossInstitutePiiTest.cs` — assert response payload after registration contains no `OtherInstitute*` keys, no other `PersonCode`s.

### 8.3 Manual QA checklist

After Phase 6 ships, run through:
- [ ] Register a brand-new student. Observe matcher logs show "NEW PERSON".
- [ ] Register the same student (same first name, DOB, parent phone) at a second institute. Observe matcher logs show "AUTO-LINK". UI at second institute shows enrollment normally with no other-institute hints.
- [ ] Register two twins at the same institute. Observe two distinct users.
- [ ] Re-enroll one twin at a second institute. Observe a review item appears for `GlobalIdentityAdmin`.
- [ ] As global admin, resolve review item → "Link" → second institute's enrollment now points to the first twin's user.
- [ ] Confirm institute admin cannot access `/api/global-identity/*` (403).

---

## 9. Operational Runbook

- **Matcher backlog grows.** Check `IdentityMatchingWorker` logs in Seq. Likely cause: Service Bus subscription disabled or DB pool exhaustion.
- **Wrong merge in production.** Find the `PersonMergeAudit` row, run `SplitPersonCommand` with that audit id. The duplicate user is restored from the snapshot. Re-trigger matching only after manually correcting the inputs that caused the false positive.
- **Twin appears as one record.** If users report "my child's attendance is mixed up with their twin", that's a symptom of a wrong auto-merge. Run `SELECT * FROM ams_person_merge_audit WHERE canonicaluserid = X OR duplicateuserid = X` to find the merge, then split.
- **A returning student wasn't auto-linked.** Likely the `FirstName` trigram fell below 0.85 (e.g. spelling drift) OR the parent's phone changed and the gate failed. Resolution: a global admin uses the review queue if it's there; otherwise registers normally and uses `MergePersonsCommand` later. Optionally, registrar can ask the student for a `PersonCode` next time.

---

## 10. Open Questions (decide before implementation)

These don't block schema work but should be resolved before Phase 6 ships:

1. **Family-email allowlist size.** What's "≥ 2 users"? Or do we want a configurable threshold per environment?
2. **`OtherNames` / middle name field.** Recommended to add to `ApplicationUser` to disambiguate same-FirstName twins. Not in this plan because not yet collected anywhere — flag for product.
3. **Auto-merge confidence threshold.** Currently 0.92. Tune after observing review-queue volume in production.
4. **Phone country default.** `libphonenumber-csharp` needs a region for ambiguous numbers. Default to `LK` (Sri Lanka) based on project context — confirm.
5. **PersonCode visibility on cards.** Should the PWA card-checking surface display `PersonCode` to swipe operators? Likely yes, for support; not part of this plan but flagged.

---

## 11. What this plan deliberately does NOT include

- A self-serve "merge my own duplicates" flow for end users. All merges are admin-mediated.
- Cross-region replication of `Guardian` data. Out of scope.
- Soft fingerprinting (browser/device-based identity hints). Privacy-hostile and unreliable.
- Photo-based matching. Way out of scope.

---

## 12. Implementation order summary

1. Phase 1 — enrich `ApplicationUser` + extensions + sequence (1 migration)
2. Phase 2 — move DOB up, normalize guardians (1 migration + entity refactor)
3. Phase 3 — `IIdentityMatchingService` synchronous, fully unit/integration tested
4. Phase 4 — domain event + Service Bus + background worker
5. Phase 5 — merge/split/review tooling + `GlobalIdentityAdmin` role
6. Phase 6 — registration UX changes + `PersonCode` input

Each phase = its own branch, its own PR, its own review.

---

## 13. Glossary

- **Person** — a real human. Represented by a row in `ams_users` (canonical `ApplicationUser`).
- **Enrollment** — a relationship between a Person and an Institute as a student or instructor.
- **PersonCode** — printable, stable, globally unique string. The "passport" a student carries between institutes.
- **Provisional user** — an `ApplicationUser` row with `IsLinkPending = true`. Functionally complete; pending matching outcome.
- **Canonical user** — an `ApplicationUser` row with `IsCanonical = true`. The surviving identity after merges.
- **Twin cluster** — ≥ 2 canonical users sharing the same `(DateOfBirth, Guardian)` tuple. Auto-merge is disabled inside clusters.
- **GlobalIdentityAdmin** — the only role allowed to see PII across institutes. Lives outside `InstituteRole`.
