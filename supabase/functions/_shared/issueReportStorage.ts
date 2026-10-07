// Private issue-reports bucket, shared by issue-report (upload) and issue-report-prune.
// Layout: {platform}/{yyyy-mm-dd}/{report_id}.zip

export const ISSUE_REPORTS_BUCKET = "issue-reports"

export interface StorageEntry {
  name: string
  id: string | null // null for a folder
}

const headers = (serviceKey: string) => ({
  Authorization: `Bearer ${serviceKey}`,
  apikey: serviceKey,
  "Content-Type": "application/json",
})

// Missing files are skipped by Storage, so a row whose file is already gone still prunes.
export async function removeIssueReportFiles(supabaseUrl: string, serviceKey: string, paths: string[]): Promise<void> {
  const res = await fetch(`${supabaseUrl}/storage/v1/object/${ISSUE_REPORTS_BUCKET}`, {
    method: "DELETE",
    headers: headers(serviceKey),
    body: JSON.stringify({ prefixes: paths }),
  })
  if (!res.ok) throw new Error(`remove objects: ${res.status} ${await res.text()}`)
}

/** One level under [prefix] (e.g. "ios/"): folders and files, up to [limit]. */
export async function listIssueReportEntries(
  supabaseUrl: string,
  serviceKey: string,
  prefix: string,
  limit = 1000,
): Promise<StorageEntry[]> {
  const res = await fetch(`${supabaseUrl}/storage/v1/object/list/${ISSUE_REPORTS_BUCKET}`, {
    method: "POST",
    headers: headers(serviceKey),
    body: JSON.stringify({ prefix, limit, offset: 0 }),
  })
  if (!res.ok) throw new Error(`list objects: ${res.status} ${await res.text()}`)
  return await res.json()
}
