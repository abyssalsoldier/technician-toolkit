# Download website

`index.html` is the whole site: one static page with no build step and no server code. Upload it to any web host (the site root or a subfolder).

- **Downloads** link to `https://github.com/abyssalsoldier/technician-toolkit/releases/latest/download/<file>`, so the page always offers the newest release without being re-uploaded:
  - `EndpointToolkit.exe`: the ready-to-run exe (attached by the release workflow's `exe` job)
  - `latest.zip`: the ready-to-extract folder (run `Launch.bat`)
  - `client-kit.zip`: the full program for building a branded version (`Setup-Client.bat`)
- **Version, date, sizes and checksum** are filled in by the browser from the GitHub API (`api.github.com/repos/.../releases/latest`). If that call fails (offline, rate limit), the page still works with the default text.
- **Releases come from `main`.** Day-to-day work is on `dev`. Merging `dev` into `main` with a bumped `dependencies/version.txt` publishes a release, and the site shows it automatically.

Re-upload `index.html` only when the page itself changes. This folder is repo-only: it's excluded from every zip, exe and USB build.
