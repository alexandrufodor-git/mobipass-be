# Upload the MobiPass legal pages to mobipass.eu

**Goal:** make these two pages live:
- `https://mobipass.eu/privacy`
- `https://mobipass.eu/terms`

**What you need:**
- The file **`mobipass-legal.zip`** (attached / sent to you).
- Login to the **Hosterion** account that hosts `mobipass.eu`.
- Just a web browser — nothing to install.

**Time:** about 5 minutes.

---

## Step by step

### 1. Open cPanel File Manager
1. Log in to your Hosterion account (client area at hosterion.ro).
2. Find and open **cPanel** for the `mobipass.eu` hosting.
3. In cPanel, under the **Files** section, click **File Manager**.
   (File Manager opens inside your browser — like a file explorer on a web page.)

### 2. Go to the website root
1. In the left sidebar, click the **`public_html`** folder.
   This is the live `mobipass.eu` website. You should see the existing site files here.

> ⚠️ Make sure you are **inside `public_html`** before the next step, otherwise the pages won't appear at mobipass.eu.

### 3. Upload the zip
1. Click the **Upload** button in the top toolbar. A new browser tab opens.
2. Click **Select File** (or drag the file in) and choose **`mobipass-legal.zip`**.
3. Wait for the progress bar to reach **100% (Complete)**.
4. Close that upload tab and go back to File Manager.
5. Click **Reload** (top toolbar) — you should now see `mobipass-legal.zip` listed inside `public_html`.

### 4. Extract the zip
1. **Right-click** `mobipass-legal.zip` → choose **Extract**.
2. A box appears asking where to extract — leave it as the current folder
   (it should show `/public_html`) → click **Extract File(s)**.
3. Close the results popup. Click **Reload**.
4. You should now see two new folders inside `public_html`: **`privacy`** and **`terms`**.

### 5. Delete the zip (tidy up)
1. **Right-click** `mobipass-legal.zip` → **Delete** → confirm.
   (The pages are already extracted; the zip is no longer needed.)

### 6. Check it works
Open these two links in a browser:
- https://mobipass.eu/privacy
- https://mobipass.eu/terms

Each should show a formatted **Privacy Policy** / **Terms** page (not code, not a "404 Not Found").

✅ Done.

---

## If something looks wrong

- **You see a "404 Not Found":** the folders probably landed in the wrong place.
  In File Manager, confirm the path is exactly `public_html/privacy/index.html` and
  `public_html/terms/index.html`. If they ended up inside another folder, move the
  `privacy` and `terms` folders directly into `public_html`.
- **You see page *code* instead of a nice page:** open the folder and make sure the file
  inside is named exactly **`index.html`** (all lowercase).
- **Page doesn't update:** wait 1–2 minutes and refresh (Cloudflare may cache briefly).
  A hard refresh is Ctrl+Shift+R (Windows) / Cmd+Shift+R (Mac).

## To update a page later
Replace the matching `index.html` file:
- Privacy → `public_html/privacy/index.html`
- Terms → `public_html/terms/index.html`
