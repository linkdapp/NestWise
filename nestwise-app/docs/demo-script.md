# NestWise — Demo Script

**Target length: 10-11 minutes.** All 12 planned pages are built and verified
working, so everything described below is real. Nothing here is aspirational.

A presenter who has never opened NestWise before should be able to run this
cold from the steps below. Every claim in it is something the app genuinely
does; nothing here is aspirational.

Three moments are worth visibly slowing down for:

1. **Neighborhood Detail** — Oracle and MongoDB rendering side by side.
2. **Admin / Seed Data** — resetting both databases live, without breaking them.
3. **The RAC session check** — real sessions on both instances.

Everything else moves at a brisk 30-45 second click-and-talk pace.

---

## 0. Before you present (2 min, offstage)

- `curl http://<app-server>:4000/health` → expect `{"status":"ok","service":"nestwise-mongo-proxy"}`. If the proxy is down, MongoDB-backed regions render **blank rather than erroring**, which is easy to mistake for a design choice mid-demo.
- Sign in as **`nestwise_admin`**, not `nestwise_test` — the Admin / Seed Data page and its navigation entry are both hidden from non-admins, and step 7 needs it.
- **Do not click "Neighborhood Detail" directly in the left nav.** That page expects a neighborhood to have been chosen; opening it cold shows empty regions. Always arrive via Neighborhood Explorer. (Leaving it in the nav is a known rough edge, not a bug.)

---

## 1. Open the Dashboard (45 sec)

**Action:** Land on **Home**.

**Say:** "NestWise is one Oracle APEX application in front of two databases —
Oracle on a 2-node RAC cluster for the structured, relational data, and MongoDB
for anything genuinely document-shaped. One city at a time; this is Washington,
D.C."

**Point at:** the four tiles. "Neighborhoods and Restaurants come straight from
Oracle. Listings and Current Weather are pulled live from MongoDB through a
small Node proxy. Same page, two databases, and neither database knows the
other exists."

---

## 2. Neighborhood Explorer → favorite a neighborhood (60 sec)

**Action:** **Neighborhood Explorer** in the nav. Type "George" in the search
box. Click the favorite icon on Georgetown.

**Say:** "Native APEX Interactive Report — filtering, sorting, export, all for
free. And favoriting" — click — "is a declarative link plus a PL/SQL toggle
process. No page reload, no custom JavaScript anywhere in this app."

---

## 3. ★ Neighborhood Detail: Oracle and MongoDB on one page (90 sec)

**Action:** Click **Georgetown** in the report.

**Say:** "This is the page that tells the architecture story. Up here" — point
at Restaurants / Theaters / Stats — "restaurant ratings, theaters, and
neighborhood stats, all straight out of Oracle. Down here" — point at Stay Here
and Weather Here — "listings and current weather for this same neighborhood,
coming from MongoDB through the proxy. One page, one render, two databases."

**Say:** "The join key between them is just `neighborhood_id` — an integer that
means the same thing on both sides. That sounds trivial and it is the single
thing most likely to break in a setup like this. I'll come back to that."

*(Plant it here. It pays off in step 7.)*

---

## 4. Restaurant Finder: filters + recommend (75 sec)

**Action:** **Restaurant Finder**. Change Cuisine and Price Range. Scroll to
**Recommended for Me**.

**Say:** "Declarative select lists driving a filtered report — no custom code."
Then: "And this scores every restaurant against your saved preferences: cuisine
match, budget fit, plus its own rating. It's a simple weighted heuristic, not a
trained model, and the page says so. That's the honest level of sophistication
for a showcase."

---

## 5. Stay / Listings → Listing Detail (75 sec)

**Action:** **Stay / Listings**. Point at **Recommended for Me** at the top
first, then scroll to **Browse All Listings**, pick a neighborhood from the
filter — cards narrow to that neighborhood. Click a card.

**Say, on the recommendations:** "These are scored against the preferences saved
on my profile — listing rating, plus a bonus if the price fits my budget and
another if the neighborhood's weather matches what I like. Simple weighted
heuristic, and the page says so. The scoring happens in the proxy, because
that's the one place the listing data and the weather data actually sit
together."

**Say, on the browse grid:** "These cards are MongoDB documents, filtered by the
same `neighborhood_id`. The filter's dropdown is an Oracle query; the cards are
a Mongo REST call. They meet on the page."

**Then, on Listing Detail:** "And here's why this data lives in MongoDB rather
than Oracle — reviews are an array embedded *inside* the listing document.
Variable length, read together with the listing, never queried on their own.
Modelling that relationally would mean a child table and a join for something
that is genuinely one object."

**Point at:** the **View Neighborhood** button. "And that goes back the other
way — a MongoDB document handing off to an Oracle-backed page."

---

## 6. Entertainment: both databases, one filter (45 sec)

**Action:** **Entertainment**. Select **Penn Quarter / Chinatown**.

**Say:** "One dropdown, and watch both sides update together — theaters on the
left out of Oracle, what's popular near them on the right out of MongoDB. Same
neighborhood, same click, two databases. That's a single Dynamic Action firing
two region refreshes; no custom JavaScript."

**Point at:** the movie badges. "And these are ranked by a popularity score that
lives on the Mongo document, filtered by an array field — each movie carries the
list of neighborhoods it's playing near. That's a shape that would need a
junction table in Oracle and is just a field here."

*Penn Quarter is the right neighborhood to pick: four theaters and four movies.
Most others legitimately show one or both sides empty — there are only 14
theaters and 13 movies in the seed.*

## 7. Weather Context (30 sec, brisk)

**Action:** **Weather Context**. Pick any neighborhood.

**Say:** "Five days of observations per neighborhood, chart above and raw
snapshots below. This is time-series data that's just appended over time — a
natural fit for documents, and the last of the three MongoDB collections."

*Honest note if a developer asks how it's built: this is the one region that
doesn't bind declaratively to the REST source. A Chart Series wouldn't take the
parameter, so the data is fetched in PL/SQL with `APEX_WEB_SERVICE`, parsed with
`JSON_TABLE`, and charted from an APEX Collection. Documented in
`apex/page_plan.md`.*

## 8. User Profile (30 sec, brisk)

**Action:** **User Profile**, change a preference, Save.

**Say:** "This is what drives the recommendation scores you just saw. One form,
stored in Oracle."

---

## 9. ★ Admin / Seed Data: reset both databases live (90 sec)

**Action:** **Admin / Seed Data**. Point at the status panel *before* clicking
anything — specifically **Min Nbhd Id = 1, Max Nbhd Id = 28**. Click **Reload
Oracle Seed Data**, confirm. Then **Reload MongoDB Seed Data**, confirm. Point
at the ID range again: still 1 and 28.

**Say:** "This isn't a static mockup — I can reset both databases live from the
UI. Oracle reload calls a PL/SQL procedure. MongoDB reload goes out through the
proxy to the same seed script used at install time, so there's exactly one
definition of 'seed data' per database."

**Say — this is the real payoff:** "Now, remember the join key. This used to be
the most dangerous button in the app. `neighborhood_id` was an Oracle IDENTITY
column, and deleting rows doesn't reset an identity sequence — so every reload
handed out a *fresh* range of IDs while MongoDB kept its original numbering.
The two databases silently stopped agreeing. The failure mode wasn't an error;
it was one neighborhood quietly showing another neighborhood's listings,
because both were plausible D.C. neighborhoods and nothing looked wrong."

**Say:** "The fix was to stop generating the key at all. Nothing in this
application inserts a neighborhood at runtime — all 28 come from a seed script
— so the identity column bought nothing and cost cross-database integrity. The
IDs are now part of the seed data itself, identical on every install and every
reload. That's why the range still reads 1 to 28 after resetting both sides,
and it's why this button is safe to press in front of an audience."

*If the audience is DBAs, this is the moment they will care about most. It's a
real integrity bug, found by real testing, fixed at the cause rather than
papered over with a sync script.*

---

## 10. ★ Close with the RAC angle (60 sec)

**Action:** If a DBA terminal is handy, run `loadtest/rac_session_check.sh` and,
in a second session:

```sql
SELECT inst_id, COUNT(*) FROM gv$session
WHERE username = 'NESTWISE' GROUP BY inst_id ORDER BY inst_id;
```

**Say:** "Every click you just watched was a real session against a 2-node RAC
cluster — this app exists to validate that cluster with genuine application
traffic, not synthetic load. Under 20 concurrent sessions through the SCAN
listener, we see both instances taking work — 14 and 6 on one sample, 11 and 8
a moment later. Uneven, which is correct: SCAN balances on connection count and
instance load, not a strict split, and it rebalances over the life of the run."

**Worth adding, because it is a genuinely useful observation:** "Clicking around
by hand shows *nothing* in `gv$session` — each page's database work finishes in
milliseconds, so by the time you switch windows every session has already
closed. You need sustained concurrency to see it at all."

---

## Close (15 sec)

**Say:** "One APEX application, one app server, two databases each doing the
part they're actually good at — Oracle for structured data and referential
integrity, MongoDB for anything genuinely document-shaped. No microservices, no
Kubernetes, and it's running on real infrastructure."

---

## Not yet built — what to say if asked

Answer plainly; a showcase loses more credibility from overclaiming than from an
honest "not yet."

| Feature | Status |
|---|---|
| **Swingbench load-test numbers** | **Not run.** The RAC session-distribution check in step 8 is real and reproducible. A custom Swingbench benchmark against NestWise's own query patterns would require Java or PL/SQL transaction classes — see `loadtest/swingbench/README-swingbench.md`. Do not imply numbers that don't exist. |

---

### Presenter notes

- Proxy down → Mongo regions render **blank, not errored**. Check `/health` first.
- Sign in as `nestwise_admin`; step 9 is invisible otherwise.
- **Neighborhood Detail** is no longer in the nav — reach it by clicking a neighborhood in the Explorer, or the "View Neighborhood" button on a listing.
- On **Entertainment**, pick Penn Quarter / Chinatown or Adams Morgan. Most neighborhoods legitimately have no theater, no movies, or no venues — that's honest seed data, not a gap.
- If time is tight, compress steps 4-8 rather than cutting any ★ moment.
- Step 9's ID-stability story is the strongest technical content in the demo for a DBA audience. If you only have five minutes, run steps 1, 3, 9, 10.
