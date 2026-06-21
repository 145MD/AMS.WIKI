# 👩‍🏫 Instructor Portal Module

> Self-service portal where instructors log in and see **only their own** classes, students,
> attendance, student fee status, and revenue-share earnings.

## 1. Module Overview

Institutes employ instructors who need visibility into the classes they teach without being
given institute-wide admin access. The Instructor Portal is a permission-gated area of the same
authenticated web app (the PWA) that shows each instructor a personalised view:

- **My Dashboard** — class/student counts, today's sessions, this month's earnings.
- **My Classes** — the classes they're assigned to, with schedule and enrolment counts.
- **Class detail** — tabbed **Roster**, **Attendance** (mark/correct), and **Fees** (read-only).
- **My Earnings** — their own revenue-share payouts, with a trailing-months history.

The whole surface is **self-scoped**: every API call resolves the caller's own
`InstructorEmployment` server-side and only returns data for the classes that instructor
teaches. There is no instructor-id parameter, so one instructor can never read another's data.

## 2. Data Model (reused)

No new tables. The portal sits on top of existing entities:

| Entity | Role |
| --- | --- |
| `InstructorEmployment` | Links a `User` to an `Institute` as an instructor. |
| `InstructorClass` | Assigns an instructor to a `Class` (active/primary). |
| `StudentClass` | Enrolment used for the roster and fee status. |
| `ClassSession` | Weekly schedule shown on the dashboard / class detail. |
| `Attendance` | Read for the sheet; created/updated when marking. |
| `RevenueShareConfig` / `PaymentAllocation` | Drive the earnings figures. |

## 3. Onboarding & Credentials

When an instructor is employed via a **brand-new person** (`EmployInstructorCommand` Person path):

- **Email and NIC are mandatory** (`EmployInstructorCommandValidator`). The email becomes the login
  username; the NIC seeds the initial password.
- The new account gets a **system-generated initial password** `{NIC}@{Firstname}` (first name
  title-cased) — see `InstructorInitialPassword.Build`. It's predictable on purpose so an admin can
  hand it over, never a lasting secret.
- The account is flagged `ApplicationUser.MustChangePassword`, so the instructor is **forced to
  change the password on first login**. The PWA's `_authenticated` route gate redirects to a
  full-screen `/change-password` page until the flag clears (cleared by `ChangePasswordCommand`).

Linking an **existing** person (by `UserId` / `PersonCode`) reuses their account and credentials
untouched — no email/NIC requirement and no password reset.

### Institute membership (login access)

Logging in requires an active `InstituteUser` row (the membership/role record the login guard and
JWT permissions are built from):

- **Instructors are auto-linked.** `EmployInstructorCommandHandler.EnsureInstituteMembershipAsync`
  creates an `InstituteUser` bound to the seeded **Instructor** role (which carries `portal:*`) plus
  the baseline global `User` role — idempotent, so an existing membership/role is never overwritten.
  Without this an employed instructor could not actually sign into the portal.
- **Students are on-demand, not automatic.** Enrolling a student does **not** create login access
  (least-privilege; there's no student portal yet). An admin grants it per student via the Students
  list → **Grant institute access** action, which calls `POST /api/institutes/{id}/users/existing`
  (`AddUserToInstituteCommand`, gated by `institute-users:create`) with the seeded **Student** role.
  The same command also backs the legacy super-admin `POST /users` endpoint.

The `AddStudentRoleAndInstructorMembershipBackfill` migration seeds the Student role into existing
institutes and backfills `InstituteUser(Instructor)` rows for instructor employments that predate
the auto-link.

## 4. Permissions

The seeded **`Instructor`** institute role carries a dedicated self-scoped permission set
(`DefaultInstituteRolePermissions.InstructorPermissions`) instead of the institute-wide
`students:view` / `classes:view`:

| Permission | Grants |
| --- | --- |
| `portal:access` | Use the portal; land on the dashboard. |
| `portal:classes:view` | List own classes + class detail. |
| `portal:students:view` | View the roster of own classes. |
| `portal:attendance:view` | View attendance for own class sessions. |
| `portal:attendance:mark` | Mark/correct attendance for own class sessions. |
| `portal:payments:view` | Read-only fee status of students in own classes. |
| `portal:revenue:view` | View own revenue-share earnings. |

These are eligible for the per-institute assignable boundary (`InstitutePermissionPolicy`,
resource `portal`), so institute admins can grant them to custom roles. Because admins lack
`portal:*` and instructors lack the broad admin permissions, the "My Teaching" sidebar group
and the admin sections never overlap.

## 5. API — `/api/portal/*`

All endpoints extend `BaseApiController` and are gated by the matching `portal:*` policy.
Ownership is enforced by `ICurrentInstructorResolver` (`GetCurrentAsync` / `GetForClassAsync`).

| Method & route | Permission | Returns |
| --- | --- | --- |
| `GET /api/portal/me` | `portal:access` | The instructor's own profile. |
| `GET /api/portal/dashboard` | `portal:access` | Dashboard metrics + today's sessions. |
| `GET /api/portal/classes` | `portal:classes:view` | Classes the instructor teaches. |
| `GET /api/portal/classes/{classId}` | `portal:classes:view` | Class detail: sessions + fees + revenue split. |
| `GET /api/portal/classes/{classId}/students` | `portal:students:view` | Roster. |
| `GET /api/portal/classes/{classId}/attendance?date=` | `portal:attendance:view` | Attendance sheet for a date. |
| `POST /api/portal/classes/{classId}/attendance` | `portal:attendance:mark` | Upsert attendance for a date. |
| `GET /api/portal/classes/{classId}/fee-status?year=&month=` | `portal:payments:view` | Read-only class fee status. |
| `GET /api/portal/earnings?year=&month=` | `portal:revenue:view` | The instructor's payout for a month. |
| `GET /api/portal/earnings/history?months=` | `portal:revenue:view` | Trailing-months payout history. |

Several handlers reuse existing admin queries after the ownership check — `GetClassStudentsQuery`,
`GetClassFeeStatusQuery`, and `GetInstructorPayoutQuery` — so portal data stays consistent with
the admin views.

## 6. Frontend

Lives in the existing authenticated shell (same sidebar/header/theming):

- Routes: `src/routes/_authenticated/portal/**` (dashboard, classes, classes/$classId, earnings).
- Feature: `src/features/portal/**` (dashboard, my-classes, class-detail with tabs, attendance
  sheet, fee-status panel, earnings).
- Data: `src/services/portal.service.ts` + `src/hooks/use-portal.ts` (TanStack Query).
- Nav: a permission-gated **"My Teaching"** group in `sidebar-data.ts`.
- Landing: `_authenticated/index.tsx` redirects instructor-only users to `/portal`.

## 7. Deployment Notes

Three migrations ship with this module:
- `AddInstructorPortalPermissions` — seeds the `portal:*` permission rows, swaps the broad
  permissions on every existing `Instructor` institute role for the `portal:*` set, and adds them to
  each institute's assignable boundary.
- `AddMustChangePassword` — adds the `MustChangePassword` column to `ams_application_users`.
- `AddStudentRoleAndInstructorMembershipBackfill` — seeds the `Student` institute role into existing
  institutes and backfills `InstituteUser(Instructor)` membership for pre-existing instructor employments.

Run the API once with `--seed-permissions` after deploy so the global permission catalogue is reconciled.

## 8. Tests

`AMS.Tests/Portal/`, `AMS.Tests/Instructor/` and `AMS.Tests/Institute/` cover the security spine and
onboarding contracts:
- `CurrentInstructorResolverTests` — non-instructors and non-owned classes are rejected (Forbidden).
- `InstructorPortalRoleTests` — the Instructor role carries `portal:*` and **not** institute-wide perms.
- `MarkMyClassAttendanceCommandValidatorTests` — marking input validation.
- `EmployInstructorCommandValidatorTests` — email + NIC required for a new instructor; not for an existing one.
- `InstructorInitialPasswordTests` — `{NIC}@{Firstname}` format satisfies the Identity password policy.
- `DefaultInstituteRoleTests` — `Student` is a seeded system role with no management permissions; `Instructor` carries `portal:access`.
- `AddUserToInstituteCommandValidatorTests` — add-existing-member input validation.
