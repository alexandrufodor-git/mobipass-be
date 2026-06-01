# Bulk Create Employee Invites

This edge function allows HR users to bulk-create employee invites by uploading a CSV file.

## Endpoint

```
POST /bulk-create
```

## Authentication

Requires authentication via JWT token. The user must have HR permissions.

## CSV Format

The CSV file must include a header row with column names.

### Required Columns
- `email` - Employee email address (must be valid email format)
- `firstName` - Employee first name (cannot be empty)
- `lastName` - Employee last name (cannot be empty)

### Optional Columns
- `description` - Employee description or bio
- `department` - Employee department or team
- `experience` - Employee experience (e.g., "2 years", "6 months")
- `hireDate` - Employee hire date as Unix timestamp in milliseconds (e.g., 1706745600000 for Feb 1, 2024)

### Example CSV

```csv
email,firstName,lastName,department,experience,hireDate,description
john.doe@example.com,John,Doe,Engineering,3 years,1672531200000,Senior Software Engineer
jane.smith@example.com,Jane,Smith,Marketing,2 years,1680307200000,Marketing Manager
bob.johnson@example.com,Bob,Johnson,Sales,,1688169600000,
alice.williams@example.com,Alice,Williams,HR,5 years,1659398400000,HR Director
```

### Notes

- Column order doesn't matter as long as the header row matches
- `firstName` and `lastName` are required and cannot be empty
- Empty values for optional fields are treated as NULL in the database
- If an email already exists in the system, that row will be skipped with status `already_exists`
- Invalid email addresses will be rejected with status `invalid_email`
- Missing or empty `firstName` will be rejected with error `missing_first_name`
- Missing or empty `lastName` will be rejected with error `missing_last_name`
- The `hireDate` must be a valid integer (Unix timestamp in milliseconds). Invalid values will be ignored
- All text fields are trimmed of leading/trailing whitespace
- The CSV can be sent as either:
  - `multipart/form-data` (file upload)
  - Raw CSV text in the request body

## Response Format

Both the CSV and the REGES JSON branches return the **same per-record
shape**. Each `results[i]` mirrors a row of the
`profile_invites_with_details` view (so the FE can reuse its dashboard row
type), plus an outcome envelope (`status`, `invited`, optional `error`).

`email` and `derived_email` are **both nullable**:

- CSV invite → `email` is set to the value from the file, `derived_email` is `null`.
- REGES invite → `derived_email` is set when the company has an `email_pattern`; `email` stays `null` until the employee claims the invite via `/register`.

`status` values:

| value | when |
|---|---|
| `created` | new invite row written |
| `created_linked` | REGES — invite linked to an already-registered profile via `derived_email` |
| `merged` | REGES — PII merged into an existing `employee_pii` row |
| `updated` | re-upload of an existing unclaimed invite |
| `skipped_claimed` | re-upload of an invite already claimed by an employee (no overwrite) |
| `already_exists` | CSV duplicate email |
| `invalid_email` | CSV row with malformed email |
| `missing_first_name` / `missing_last_name` | CSV row missing required field |
| `failed` | REGES per-record validation error (see `error`) |

```json
{
  "created": 4,
  "results": [
    {
      "invite_id":          "123e4567-e89b-12d3-a456-426614174000",
      "email":              "john.doe@example.com",
      "derived_email":      null,
      "first_name":         "John",
      "last_name":          "Doe",
      "description":        "Senior Software Engineer",
      "department":         "Engineering",
      "hire_date":          1672531200000,
      "source":             "manual",
      "radiat":             false,
      "invite_status":      "inactive",
      "invited_at":         "2024-02-01T12:00:00Z",
      "company_id":         "abc12345-e89b-12d3-a456-426614174000",
      "company_name":       "Acme",
      "logo_image_path":    null,
      "user_id":            null,
      "profile_status":     null,
      "registered_at":      null,
      "profile_image_path": null,
      "bike_benefit_id":    null,
      "benefit_status":     null,
      "contract_status":    null,
      "last_modified_at":   "2024-02-01T12:00:00Z",
      "bike_id":            null,
      "order_id":           null,

      "status":             "created",
      "invited":            true
    },
    {
      "invite_id":     "9aa12345-...",
      "email":         "existing@example.com",
      "derived_email": null,
      "first_name":    "Jane",
      "last_name":     "Smith",
      "status":        "already_exists",
      "invited":       false
    },
    {
      "invite_id":     "",
      "email":         "invalid-email",
      "derived_email": null,
      "first_name":    null,
      "last_name":     null,
      "status":        "invalid_email",
      "invited":       false,
      "error":         "invalid_email"
    }
  ]
}
```

> Fields not shown in the second/third example are still present (set to
> `null`); only the relevant ones are listed for brevity.

## TBD — REGES `radiat` cascade on claimed invites

Today, when REGES says an already-onboarded employee left the company
(`radiat: false → true` on a claimed invite), `ingest_reges_batch` only:

- flips `profile_invites.radiat` to `true`
- emits `company_notifications` (`event_type='reges_terminated'`)

It does **not** touch `bike_benefits` (`benefit_status` / `contract_status`
stay in whatever state they had), so the HR dashboard can show
`benefit_status='active'` while `radiat=true`. `/register` is already
defensive (`403 invite_inactive` if `radiat=true`).

**Why we're not auto-terminating yet:**
the subsidy math is per-company. Hard-terminating bricks the employee's
in-flight bike benefit and erases their progress; in some cases the
employee actually *moved* (acquired by another company, transferred,
went freelance) and we'd want to **carry their data over to the new
company / a personal-login account before terminating the source row**.

Plan once that path exists:

1. New endpoint to migrate `{profile, employee_pii, bike_benefit, contract,
   bike_order, tbi_loan_application}` from company A → company B (or to a
   "personal" company-less profile).
2. Only after a successful migration (or HR explicit confirmation) does
   the cascade fire: `bike_benefits.benefit_status='terminated'`,
   `benefit_terminated_at=now()`, `contract_status='terminated'`,
   `contract_terminated_at=now()`.
3. Until then, `radiat` stays advisory — HR makes the call manually
   from the dashboard banner driven by `reges_terminated` notifications.

## Example Request (cURL)

```bash
curl -X POST https://your-supabase-url.functions.supabase.co/bulk-create \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -F "file=@employees.csv"
```

## Data Flow

1. HR user uploads CSV file
2. Function parses CSV and validates email addresses
3. For each valid email:
   - Checks if email already exists in `profile_invites`
   - If not exists, creates a new invite record with all provided employee data
   - Associates the invite with the HR user's company
4. Returns summary of successful and failed invites

## Employee Registration Flow

When an employee registers using their invite:

1. Employee receives invitation email
2. Employee verifies their email via OTP
3. Employee sets their password
4. The `handle_user_registration` trigger automatically:
   - Creates a user profile with all employee data from the invite
   - Copies firstName, lastName, department, experience, hireDate, and description to the profile
   - Assigns 'employee' role
   - Creates a bike benefit record
   - Updates the invite status to 'active'

## Converting Date to Unix Timestamp

To convert a date to Unix timestamp in milliseconds for the `hireDate` field:

### JavaScript/TypeScript
```javascript
const date = new Date('2024-02-01');
const timestamp = date.getTime(); // 1706745600000
```

### Python
```python
from datetime import datetime
date = datetime(2024, 2, 1)
timestamp = int(date.timestamp() * 1000)  # 1706745600000
```

### Excel/Sheets Formula
```
=(A2-DATE(1970,1,1))*86400000
```
Where A2 contains your date value.
