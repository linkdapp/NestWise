# NestWise — Demo Script

**Target length: 9-10 minutes.** NestWise covers seven feature areas plus Admin — Home/Dashboard, Neighborhood Explorer, Restaurant Finder (+ recommend), Stay/Listings (+ recommend), Entertainment, Weather Context, User Profile, and Admin/Seed. Per `references/architecture-and-hybrid-flow.md`, forcing that into the usual 5-7 minute window would mean rushing at least three feature areas to fit — this script extends to 9-10 minutes instead, but the discipline that matters isn't the clock: only three moments below are "wow" moments the presenter should linger on (Neighborhood Detail's side-by-side hybrid render, the live seed reload, and the RAC session-distribution check). Everything else is a brisk 30-45 second pass so the extra runtime buys breathing room for the highlights, not padding on every page.

A presenter who has never opened NestWise before should be able to run this cold from the steps below.

---

## 1. Open the Dashboard (45 sec)

**Action:** Log into the APEX app; land on Home / Dashboard.

**Say:** "This is NestWise — a single Oracle APEX application in front of two databases: Oracle, running on a 2-node RAC cluster, for the structured data, and MongoDB for anything document-shaped. It's built for one city at a time — San Francisco here — and it's a real workload, not just a demo skin: every page you're about to see is genuine traffic against that RAC cluster."

**Point at:** the four dashboard tiles. "Neighborhoods and Restaurants come straight from Oracle. Listings and Current Weather are pulled live from MongoDB through a small proxy — same page, two databases, and neither one knows about the other."

## 2. Neighborhood Explorer → favorite a neighborhood (60 sec)

**Action:** Click **Neighborhoods** in the nav. Type "Mission" in the search box — watch the Interactive Report filter live. Click the favorite (heart) icon on Mission District.

**Say:** "This is a native APEX Interactive Report — filter, sort, export, all for free, no custom JavaScript. And favoriting" — click the icon — "is a Dynamic Action calling a PL/SQL toggle procedure. Notice it didn't reload the page — just that one icon."

## 3. ★ WOW MOMENT — Neighborhood Detail: Oracle and MongoDB side by side (90 sec)

**Action:** Click into **Mission District**.

**Say:** "This page is the one that actually tells the hybrid story. Up top" — point — "restaurant ratings and theater listings, straight out of Oracle. Right below it, in the same page, without a refresh" — point — "Airbnb-style listings and today's weather, both coming from MongoDB through the proxy. Two databases, one screen, rendered by the same APEX engine. That's the whole architecture in one page."

**Say:** "And notice the listing card has embedded reviews — that's a MongoDB document with a nested array, which is exactly the kind of data that's awkward in a rigid relational table and natural here."

## 4. Restaurant Finder: filters + recommend for me (75 sec)

**Action:** Click **Restaurants**. Change the Cuisine and Price filters live. Then click **Recommend for me**.

**Say:** "Straightforward filtering — cuisine, price, rating — all declarative select lists, no custom code." Then, after clicking Recommend: "This scores every restaurant against your saved preferences — cuisine match, budget fit, plus its rating. It's a simple weighted heuristic, not a trained model, and the page says so explicitly — that's the honest level of sophistication for a showcase like this."

## 5. Stay / Listings: browse, detail, recommend (75 sec)

**Action:** Click **Stay**. Open one listing's detail page — scroll to the embedded reviews. Go back, click **Recommend for me**.

**Say:** "Same recommendation idea, this time scored against MongoDB data — price fit and a simple weather-preference match, computed in the proxy since that's where the listing and weather data actually live together."

## 6. Entertainment + Weather Context (60 sec, brisk)

**Action:** Click **Entertainment** — point at theaters (Oracle) next to popular movies (MongoDB) for the same neighborhood. Click **Weather** — point at the trend chart.

**Say:** "Same pattern again — Oracle for the theater, Mongo for what's currently playing. And weather here is really a small time series in MongoDB — a natural fit for data that's just appended over time."

## 7. User Profile (30 sec, brisk)

**Action:** Click **Profile**, change a preference, save.

**Say:** "This is what's actually driving those recommendation scores you saw a minute ago — one simple form, saved in Oracle."

## 8. ★ WOW MOMENT — Admin / Seed Data: live reset (75 sec)

**Action:** Click **Admin**. Click **Reload Oracle Seed Data** — point at the counts refreshing. Click **Reload MongoDB Seed Data** — point at the same.

**Say:** "This app isn't a static mockup — I can reset both databases live, right now, from the UI. Oracle reload calls a PL/SQL procedure directly. MongoDB reload goes out through the proxy, which shells out to the same seed script used at install time — so there's exactly one definition of 'seed data' for each database, not two copies drifting apart."

## 9. ★ WOW MOMENT — Close with the RAC angle (45 sec)

**Action:** (Optional, if a DBA terminal is handy) Show `GV$SESSION` grouped by `inst_id` from `docs/install.md` step 9, or reference the Swingbench numbers from a prior run.

**Say:** "One more thing, because this is the actual point of building NestWise: every click you just watched was a real session against a 2-node RAC cluster. This app exists to validate that cluster with genuine application traffic, not synthetic load — and we've also run a custom Swingbench workload against its actual query patterns to see where performance holds up under concurrency. That's in the load-test write-up if anyone wants the numbers."

## Close (15 sec)

**Say:** "One APEX app, one app server, two databases each doing the part they're good at — Oracle for structured data and referential integrity, MongoDB for anything that's genuinely document-shaped. No microservices, no Kubernetes, and it's already running on real infrastructure."

---

### Presenter notes

- If the proxy is down, MongoDB-backed regions will show blank, not an error — check `curl http://<app-server>:4000/health` before presenting.
- Keep the three ★ moments (Neighborhood Detail, Admin reload, RAC session check) as the ones you visibly slow down for; everything else should move at a click-and-talk pace.
- If time is tight, cut step 6 (Entertainment/Weather) to 30 seconds combined rather than cutting a ★ moment.
