// Private issue-reports bucket, shared by issue-report (upload) and issue-report-prune.

export const ISSUE_REPORTS_BUCKET = "issue-reports"

// Missing files are skipped by Storage, so a row whose file is already gone still prunes.
export async function removeIssueReportFiles(supabaseUrl: string, serviceKey: string, paths: string[]): Promise<void> {
  const res = await fetch(`${supabaseUrl}/storage/v1/object/${ISSUE_REPORTS_BUCKET}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey, "Content-Type": "application/json" },
    body: JSON.stringify({ prefixes: paths }),
  })
  if (!res.ok) throw new Error(`remove objects: ${res.status} ${await res.text()}`)
}
