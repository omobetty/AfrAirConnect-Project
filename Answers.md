Its assumed that I have Git installed on my local machine and my global credentials set up. These I had done from previous class assignment.
Command used to clone to my local directory on my PC:  git clone https://github.com/CHAFAH/AfricAir
Created AfriAirConnect-Project folder on my PC and cloned the above repo
Deleted AfricAir.git repo and created AfrAirConnect-Project repo in my github
git init :To initiaze my local repo for tracking
git push from my local PC to my github repo: git init, git status, git add, git commit, git remote -v,  git remote set-url origin https://github.com/omobetty/AfrAirConnect-Project.git, git remote -v, git push -u origin main

PART A Answers:
1.File list in dist: africair-mark.svg
index.html
manus-routes.json
assets/airports-BrwcO3ZA.js
assets/index.es-C05bQb9q.js
assets/index-CBj_wgb2.css
assets/index-D8WT6gtn.js
assets/pdf-o1MWN_TF.js
assets/react-CpYK3H_K.js
1. That hashes lets browsers and CDNs cache assets aggressively while fetching updated files after a build changes.
1. Broken or qverwriting files could also leave an older cached page requesting chunks from a newer build, causing failed loads or version mismatches
2. tsc -b runs TypeScript in build mode. Here it checks the referenced app and Vite config projects; both set noEmit: true, so it doesn’t emit JavaScript into dist. It does keep incremental build metadata under .tmp.
2. vite build bundles the app for production and produces the files in dist. The && in the build script means Vite runs only if TypeScript succeeds.
3. --frozen-lockfile tells pnpm to install exactly what’s recorded in pnpm-lock.yaml and not modify it. If package.json and the lockfile disagree, installation fails instead of silently resolving new versions.
3. If pnpm-lock.yaml is deleted and you run pnpm install, pnpm resolves dependencies again from the version ranges in package.json and creates a new lockfile. Even if package.json hasn’t changed, newer compatible direct or transitive package versions may be selected, so the new lockfile and installed dependency tree can differ from the old ones.
3. That’s dangerous in CI because builds may no longer be reproducible: a deployment could use different dependencies than the one tested locally, causing unexpected behavior or failures. It also weakens auditing because the exact dependency versions changed without an intentional dependency update. With pnpm install --frozen-lockfile, a missing lockfile causes the install to fail instead of silently choosing new versions.
4. In vite.config.ts, manualChunks tells Rollup, which Vite uses for production builds, to group selected modules into named output chunks: jsPDF-related dependencies go into pdf, the airport dataset into airports, and React into react. This can help cache those groups independently, but it doesn’t automatically make them load only when needed.
4. chunkSizeWarningLimit: 700 sets the size, in kB, above which Vite warns about a chunk. It’s only a warning threshold; it doesn’t cap or shrink the chunk. The config sets it to 700 because the PDF library is large.
4. The largest chunk from this build is pdf-o1MWN_TF.js: 584.78 kB before compression, 175.43 kB gzip. That matters on 3G because transferring more bytes can add noticeable wait time, and JavaScript also takes time to parse and execute. The app imports the PDF code statically, so it may be downloaded during initial page loading, even though it’s in a separate chunk.
5. Reason1: Performance: pnpm dev runs Vite’s development server, which transforms modules on demand and includes development features like hot-module replacement. It’s not optimized for production delivery.
5. Reason2: Exposure and security: The dev server is designed for trusted development, not as a hardened public-facing server.
5. Reason3: Reliability and production operations: It isn’t intended for production traffic management such as robust process supervision, caching, TLS, scaling, or production routing.
6. dist contains 1,420,511 bytes of files (about 1.35 MiB). The gzipped tar stream is 451,332 bytes (about 441 KiB).
7. B2: Be Idempotent - First run bootstrap.sh output -
Rules updated
Rules updated (v6)
[bootstrap] enabling UFW
Firewall is active and enabled on system startup
[bootstrap] bootstrap complete
7. B2: Be Idempotent - Second run bootstrap.sh output - Skipping adding existing rule
Skipping adding existing rule (v6)
[bootstrap] UFW is already active
[bootstrap] bootstrap complete
8. Build Output with distinct exit codes:
8. 0   Build and package succeeded
  2   Invalid usage
  10  Repository clone, fetch, ref resolution, or checkout failed
  20  Node/Corepack/pnpm setup or dependency installation failed
  30  TypeScript checks or tests failed
  40  Production build, metadata, archive, or checksum failed
8. Build Output with success:
vite v6.4.4 building for production...
✓ 1828 modules transformed.
dist/index.html                     0.79 kB │ gzip:   0.40 kB
dist/assets/index-CBj_wgb2.css     44.67 kB │ gzip:   9.59 kB
dist/assets/index-D8WT6gtn.js     117.59 kB │ gzip:  36.45 kB
dist/assets/index.es-C05bQb9q.js  159.77 kB │ gzip:  53.55 kB
dist/assets/react-CpYK3H_K.js     223.31 kB │ gzip:  69.26 kB
dist/assets/airports-BrwcO3ZA.js  289.19 kB │ gzip: 108.22 kB
dist/assets/pdf-o1MWN_TF.js       584.78 kB │ gzip: 175.43 kB
✓ built in 8.05s
[build] creating africair-0be3e84b9f60.tar.gz
[build] artifact: /root/AfrAirConnect-Project/africair-0be3e84b9f60.tar.gz
[build] checksum: /root/AfrAirConnect-Project/africair-0b

### B4: Atomic release switching

Using `ln -sfn` directly on `current` is not atomic: replacing a symlink can involve removing the old link and creating the new one as separate filesystem operations. A request arriving between those operations could find `current` missing. The deploy script creates a temporary symlink beside `current` and then uses `mv -T` to rename it over `current`. Because both links are on the same filesystem, the rename is atomic: requests see either the old release or the new release.
9. B6. Health monitoring with systemd:
root@ip-172-31-3-50:~/AfrAirConnect-Project# systemctl list-timers --all | grep africair-healthcheck
sudo journalctl -t africair-health --since "10 min ago"
Wed 2026-10-21 20:37:00 UTC           59s Wed 2026-10-21 20:36:00 UTC    305ms ago africair-healthcheck.timer     africair-healthcheck.service
Oct 21 20:34:51 ip-172-31-3-50 africair-health[45350]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:35:00 ip-172-31-3-50 africair-health[45377]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:36:00 ip-172-31-3-50 africair-health[45394]: health check passed: http://127.0.0.1/healthz; failure counter reset
9. root@ip-172-31-3-50:~/AfrAirConnect-Project# systemctl list-timers --all | grep africair-healthcheck
sudo journalctl -t africair-health --since "10 min ago"
Wed 2026-10-21 21:02:00 UTC           33s Wed 2026-10-21 21:01:00 UTC      25s ago africair-healthcheck.timer     africair-healthcheck.service
Oct 21 20:52:00 ip-172-31-3-50 africair-health[45630]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:53:00 ip-172-31-3-50 africair-health[45644]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:54:00 ip-172-31-3-50 africair-health[45657]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:55:00 ip-172-31-3-50 africair-health[45671]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:56:00 ip-172-31-3-50 africair-health[45687]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:57:00 ip-172-31-3-50 africair-health[45701]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:58:00 ip-172-31-3-50 africair-health[45715]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 20:59:00 ip-172-31-3-50 africair-health[45728]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 21:00:00 ip-172-31-3-50 africair-health[45744]: health check passed: http://127.0.0.1/healthz; failure counter reset
Oct 21 21:01:00 ip-172-31-3-50 africair-health[45760]: health check passed: http://127.0.0.1/healthz; failure counter reset
