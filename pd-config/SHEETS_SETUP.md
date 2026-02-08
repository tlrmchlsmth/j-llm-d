# Google Sheets Integration Setup

The `collect.py --sheets` flag uploads benchmark results to a Google Spreadsheet
with embedded Pareto charts. This requires one-time OAuth setup.

## 1. Create a Google Cloud project

1. Go to https://console.cloud.google.com/
2. Click the project dropdown (top bar) > "New Project"
3. Name it anything (e.g. "pd-config-bench") and create it
4. Make sure the new project is selected in the dropdown

## 2. Enable APIs

1. Go to **APIs & Services > Library** (left sidebar)
2. Search for and enable:
   - **Google Sheets API**
   - **Google Drive API**

## 3. Configure OAuth consent screen

1. Go to **APIs & Services > OAuth consent screen**
2. Choose **Internal** (if you have a Google Workspace org) or **External** (personal Gmail)
3. Fill in:
   - App name: anything (e.g. "pd-config")
   - User support email: your email
   - Developer contact email: your email
4. Click **Save and Continue** through the remaining steps (no scopes or test users needed for Internal)

## 4. Create OAuth credentials

1. Go to **APIs & Services > Credentials**
2. Click **+ Create Credentials > OAuth client ID**
3. Application type: **Desktop app**
4. Name: anything (e.g. "pd-config-cli")
5. Click **Create**
6. Click **Download JSON**

## 5. Install the credentials

```bash
mkdir -p ~/.config/gspread
mv ~/Downloads/client_secret_*.json ~/.config/gspread/credentials.json
```

## 6. Install Python dependencies

```bash
uv pip install gspread google-auth-oauthlib
```

## 7. Test it

```bash
python3 -c "
import gspread
gc = gspread.oauth()
sh = gc.create('pd-config-test-delete-me')
print(f'Created: {sh.url}')
gc.del_spreadsheet(sh.id)
print('Deleted. Setup is working.')
"
```

This will open a browser window for OAuth consent on first run. After authorizing,
the token is cached at `~/.config/gspread/authorized_user.json` and subsequent
runs won't need the browser.

## Usage

```bash
# From pd-config/ directory:
just collect-sheets "My Benchmark Results"

# Or directly:
python3 collect.py -n tms --sheets "My Benchmark Results"
```
