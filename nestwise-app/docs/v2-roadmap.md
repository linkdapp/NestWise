# NestWise — v2 roadmap

Everything here is **deliberately not built**. It is recorded so the ideas
aren't lost and so anyone reading the project can see the scope was chosen
rather than missed.

v1's value as a showcase is that it is tight: two databases, each doing what it
is genuinely good at, demonstrated across a coherent set of pages that all work.
Breadth is not the same as credibility — every additional surface is another
thing that can be empty or wrong in front of an audience. These are worth
building only once v1 is complete, exported, and demoable end to end.

## 1. Venue Detail page

**Why it's the strongest candidate.** A Cards region has fixed slots, so it can
only display the common core of a `venues` document (`name`, `venue_type`,
`description`). The type-specific fields — `music_genres` and `live_nights` on a
music room, `taps_count` and `on_site_brewing` on a brewery, `view` and
`seasonal` on a rooftop — are exactly what justifies MongoDB here, and they're
currently invisible in the UI. A detail page is the natural place to show them.

**The interesting design problem:** the fields differ per document, so a
fixed-column region can't render them declaratively. Options worth weighing:

- Show the common core in page items, plus a "raw document" display populated
  via `APEX_EXEC` — literally showing the JSON is a blunt but honest
  demonstration of the variable schema.
- Build a small PL/SQL process that walks the document and renders label/value
  pairs for whatever fields are present.
- Accept a per-type conditional layout (regions with Server-side Conditions on
  `venue_type`), which is declarative but only scales to the six known types.

**Also:** the same click-through pattern for `theaters`, which is trivial by
comparison since theaters are fixed-shape Oracle rows.

## 2. Trails and parks

Straightforward to add following the `venues` pattern — a MongoDB collection
with variable attributes per type (a trail has length, surface, and difficulty;
a park has acreage, amenities, and whether dogs are allowed off-leash). Would
need seed data, a proxy route, a REST Data Source, and a region.

**Honest assessment:** this adds content, not architecture. It would demonstrate
the same thing `venues` already demonstrates. Worth building for completeness of
the *product* story, not for the *technical* one.

## 3. Events calendar

The most expensive item here, and the one most likely to disappoint if rushed.

- APEX has a native **Calendar** region, which would be the first in this
  project and a genuinely new component to show.
- But events need real modelling: start/end datetimes, all-day vs. timed,
  recurrence, and a notion of "upcoming" that stays true as time passes.
- **Seed data is the trap.** A calendar populated with dates in the past renders
  empty, which looks broken rather than empty. Any events seed needs to be
  generated relative to `SYSDATE` at load time, not hardcoded — otherwise the
  demo degrades silently the longer the lab sits unused. That is a real
  maintenance obligation, not a detail.
- Fixed-shape and date-heavy, so this belongs in **Oracle**, not MongoDB —
  which makes it a good counterweight if the app ever looks Mongo-heavy.

## 4. Smaller things noted along the way

- **The `View Neighborhood` button on Listing Detail** now duplicates most of
  what that page shows inline. It still adds the Stats block and the
  neighborhood's own listings, so it stays for now — but if the page grows
  further, that button is the thing to reconsider.
- **Parameter duplication** on the REST Data Sources (source-level and
  operation-level copies of the same parameter) is cosmetic and deliberately
  left alone. See `apex/page_plan.md` for the reasoning.
- **Weather seed depth.** See the Weather Context notes in `page_plan.md` —
  the number of observations per neighborhood directly determines whether a
  trend chart is worth having.
