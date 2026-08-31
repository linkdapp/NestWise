// =============================================================================
// NestWise — one-time fix for the Oracle/MongoDB neighborhood_id drift
// =============================================================================
// Background: Oracle's neighborhoods.neighborhood_id IDENTITY values have
// drifted from the original 1-28 seed range (see schema_notes.md's original
// table) because admin_pkg.reload_oracle_seed_data does not reset the
// IDENTITY sequence. MongoDB's listings/weather_snapshots/mflix_movies
// collections still use the original 1-28 numbering from seed_data.js.
//
// Confirmed empirically against this lab's live schema on 2026-08-27 via:
//   SELECT neighborhood_id, name FROM neighborhoods ORDER BY neighborhood_id;
// Result: a uniform +8 offset across all 28 rows (Georgetown 1->9,
// Barracks Row 27->35, West End 28->36, etc. -- every row shifted by
// exactly the same amount). That uniformity is what makes a simple offset
// safe here; if the drift is ever non-uniform (e.g. from a partial reload),
// this script's approach would need to become a name-keyed lookup instead
// of a flat offset -- don't assume +8 applies forever without re-checking.
//
// SAFE TO RUN ONCE. Idempotency guard: only documents whose current
// neighborhood_id is still <= 28 (the original range) get touched, so
// re-running this script after a successful run is a no-op, not a double-shift.
//
// Who:   Whoever has mongosh access to the NestWise MongoDB server
// What:  mongosh nestwise db/mongodb/remap_neighborhood_ids.js
// Where: Run directly on the MongoDB server (oradbserv04 in this lab),
//        or from any host with network access to it via mongosh's connection
//        string form: mongosh "mongodb://oradbserv04:27017/nestwise" db/mongodb/remap_neighborhood_ids.js
// =============================================================================

const OFFSET = 8; // Oracle current_id = original_id + OFFSET, confirmed above.
const ORIGINAL_MAX = 28; // guard: only remap docs still in the original 1-28 range

function rangeSummary(coll, field) {
    const result = db[coll].aggregate([
        { $group: { _id: null, min: { $min: "$" + field }, max: { $max: "$" + field }, count: { $sum: 1 } } }
    ]).toArray();
    return result.length ? result[0] : { min: null, max: null, count: 0 };
}

print("=== Before ===");
print("listings:          " + JSON.stringify(rangeSummary("listings", "neighborhood_id")));
print("weather_snapshots: " + JSON.stringify(rangeSummary("weather_snapshots", "neighborhood_id")));

// --- listings -----------------------------------------------------------
let listingsUpdated = 0;
db.listings.find({ neighborhood_id: { $lte: ORIGINAL_MAX } }).forEach(doc => {
    db.listings.updateOne(
        { _id: doc._id },
        { $set: { neighborhood_id: doc.neighborhood_id + OFFSET } }
    );
    listingsUpdated++;
});
print("listings remapped: " + listingsUpdated);

// --- weather_snapshots ----------------------------------------------------
let weatherUpdated = 0;
db.weather_snapshots.find({ neighborhood_id: { $lte: ORIGINAL_MAX } }).forEach(doc => {
    db.weather_snapshots.updateOne(
        { _id: doc._id },
        { $set: { neighborhood_id: doc.neighborhood_id + OFFSET } }
    );
    weatherUpdated++;
});
print("weather_snapshots remapped: " + weatherUpdated);

// --- mflix_movies (neighborhood_ids is an ARRAY, not a scalar) -----------
let moviesUpdated = 0;
db.mflix_movies.find({ neighborhood_ids: { $elemMatch: { $lte: ORIGINAL_MAX } } }).forEach(doc => {
    const remapped = doc.neighborhood_ids.map(id => (id <= ORIGINAL_MAX ? id + OFFSET : id));
    db.mflix_movies.updateOne(
        { _id: doc._id },
        { $set: { neighborhood_ids: remapped } }
    );
    moviesUpdated++;
});
print("mflix_movies remapped: " + moviesUpdated);

print("=== After ===");
print("listings:          " + JSON.stringify(rangeSummary("listings", "neighborhood_id")));
print("weather_snapshots: " + JSON.stringify(rangeSummary("weather_snapshots", "neighborhood_id")));
print("Done.");
