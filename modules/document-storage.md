# Document & Media Storage

NFC-based attendance is multi-tenant: many institutes share one deployment. Every
uploaded file — institute logos, user profile pictures, and general documents — is
stored in **Azure Blob Storage** with **hard per-tenant isolation**.

## Goals

- An institute's files live **only** in that institute's own container.
- The storage account stays **fully private** ("allow blob public access" can be OFF).
  Logos shown on the **anonymous sign-in page** are served via short-lived read **SAS
  URLs**; everything else streams through the authenticated content proxy.
- File access is deterministic (no fragile URL parsing) and always re-checks the
  caller's tenant before returning bytes.

## Blob layout

```
inst-{instituteId}/                 ← private, ONE container per institute
    users/{userId}/profile/{date}/{guid}_name.jpg      (+ /thumbnails/)
    users/{userId}/documents/{date}/{guid}_name.pdf
    students/{studentId}/documents/...
    docket/{docketId}/...
    institute/documents/...
branding/                           ← public-read, shared
    {instituteId}/logo/{date}/{guid}_logo.png
platform/                           ← private, platform/system assets
    templates/... | defaults/...
```

- Container names use the **immutable institute Id** (`inst-{guid:N}`, 37 chars) — not
  the mutable slug — so renaming an institute never strands its blobs. Azure container
  rules (3–63 chars, lowercase alphanumeric + hyphen) are satisfied.
- The container + relative blob path are stored on each `Document` row
  (`ContainerName`, `Path`), so download/delete never have to parse a URI.

## Access model

Every container is **private**. Nothing relies on public blob access.

| Asset | Container | How it's served |
|-------|-----------|-----------------|
| Institute logo | `branding` | Raw blob URL saved to `Institute.LogoUrl`; **signed into a read SAS URL** by `IBlobUrlSigner` whenever a DTO exposes it (branding endpoint, institute detail, switcher, list). Pre-auth friendly — the token is in the URL. |
| Profile picture | `inst-{id}` | Authenticated proxy `GET /api/documents/{id}/content` |
| General document | `inst-{id}` | Authenticated proxy `GET /api/documents/{id}/content` |
| Platform asset | `platform` | Authenticated proxy |

### SAS signing

`IBlobUrlSigner` / `BlobUrlSigner` generates a read-only service SAS (default 24h TTL)
from the account's shared-key credential — i.e. the `AzureBlobStorage` connection string
must include `AccountKey`. The stored `Institute.LogoUrl` is always the **raw** blob URL;
it's re-signed on every read so SAS expiry never strands a stored value. If the client
lacks a shared-key credential (managed identity / SAS connection string), signing is
skipped and the raw URL is returned (works only if the container is public) — logged as a
warning. For that setup, switch to user-delegation SAS.

> The institute logo is managed only via `POST /api/institutes/{id}/logo`. Editing
> institute details (`PUT /api/institutes/{id}`) never touches the logo.

## Tenant isolation enforcement

`ContainerStrategyService.GetContainerName` **throws** if a tenant-scoped category is
requested without an institute id. `DocumentService`:

- Resolves the target institute from `IInstituteContext` (or an explicit, authorized id).
- Rejects cross-tenant writes and reads — only a caller acting inside the document's
  institute (or a holder of `institutes:access-any`) may touch it.

## Key components

- **`IContainerStrategyService` / `ContainerStrategyService`** — container + path rules.
- **`IDocumentStorageService` / `DocumentStorageService`** — Azure Blob I/O, container
  access levels, thumbnail generation, best-effort thumbnail cleanup on delete.
- **`IDocumentService` / `DocumentService`** — orchestrates validation, tenant
  resolution, persistence, and the content proxy.
- **`Document`** entity — `InstituteId`, `OwnerType`, `OwnerId`, `ContainerName`,
  relative `Path`, nullable `DocketId`.

## API surface

| Method | Route | Auth | Purpose |
|--------|-------|------|---------|
| POST | `/api/institutes/{id}/logo` | `institutes:update` | Upload/replace logo (replaces old blob) |
| GET | `/api/public/institutes/by-slug/{slug}/branding` | anonymous | Branding (logo URL) for the sign-in page |
| POST | `/api/account/profile-picture` | authenticated | Upload/replace own avatar |
| GET | `/api/account/profile-picture` | authenticated | Avatar reference (proxy URL) |
| GET | `/api/account/profile-picture/content` | authenticated | Stream own avatar bytes |
| DELETE | `/api/account/profile-picture` | authenticated | Remove own avatar |
| POST | `/api/documents/upload` | `documents:upload` | Upload a document (owner-scoped) |
| GET | `/api/documents/{id}` | `documents:view` | Document metadata |
| GET | `/api/documents/{id}/content` | `documents:download` | Stream document bytes (proxy) |
| DELETE | `/api/documents/{id}` | `documents:delete` | Archive a document |

`AuthMeDto.ProfilePictureUrl` carries the avatar proxy URL so the PWA can render it at
bootstrap; it is resolved live (the avatar can change after the JWT is minted).

## Per-category upload rules

Size limits, allowed extensions and MIME types, and thumbnail generation are defined per
`DocumentCategory` in `CategoryUploadSettings`. Logos: ≤2 MB, `jpg/png/svg/webp`.
Profile pictures: ≤2 MB, `jpg/png`, thumbnailed (200×200).
