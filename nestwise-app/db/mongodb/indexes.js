// =============================================================================
// NestWise — indexes.js
// Run with: mongosh nestwise db/mongodb/indexes.js
// One index per field the app actually filters or sorts on (see
// schema_notes.md "Access from APEX" table for the exact query per field).
// =============================================================================

db = db.getSiblingDB('nestwise');

// listings — Stay/Listings browse + detail + "recommend for me"
db.listings.createIndex({ neighborhood_id: 1 });                 // GET /api/listings?neighborhood_id=
db.listings.createIndex({ avg_rating: -1 });                     // default list sort
db.listings.createIndex({ amenities: 1 });                       // multikey — amenity filtering in recommend scoring
db.listings.createIndex({ neighborhood_id: 1, avg_rating: -1 }); // compound: "listings in this neighborhood, best first"

// mflix_movies — Entertainment page
db.mflix_movies.createIndex({ neighborhood_ids: 1 });            // multikey — "movies near this neighborhood's theaters"
db.mflix_movies.createIndex({ popularity_score: -1 });           // default "currently popular" sort

// weather_snapshots — Weather Context + Dashboard current-weather tile
db.weather_snapshots.createIndex({ neighborhood_id: 1, observed_at: -1 }); // "latest snapshot for this neighborhood"
db.weather_snapshots.createIndex({ city: 1, observed_at: -1 });            // "latest snapshots for this city" (dashboard)

// venues — Entertainment page's nightlife region
db.venues.createIndex({ neighborhood_id: 1 });                   // GET /api/venues?neighborhood_id=
db.venues.createIndex({ venue_type: 1 });                        // optional type filter
db.venues.createIndex({ neighborhood_id: 1, venue_type: 1 });    // compound: "bars in this neighborhood"

print("NestWise MongoDB indexes created.");
db.listings.getIndexes().forEach(i => print(" listings: " + JSON.stringify(i.key)));
db.mflix_movies.getIndexes().forEach(i => print(" mflix_movies: " + JSON.stringify(i.key)));
db.weather_snapshots.getIndexes().forEach(i => print(" weather_snapshots: " + JSON.stringify(i.key)));
db.venues.getIndexes().forEach(i => print(" venues: " + JSON.stringify(i.key)));
