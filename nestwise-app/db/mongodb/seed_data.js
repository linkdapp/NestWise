// =============================================================================
// NestWise — seed_data.js
// Load with: mongosh nestwise db/mongodb/seed_data.js
// Idempotent (deleteMany before insertMany) — safe to re-run, and this is
// exactly what proxy/routes/admin.js calls for the "Reload Seed Data" button.
//
// neighborhood_id values below match a fresh Oracle install's IDENTITY
// sequence (1-8, see db/mongodb/schema_notes.md):
// 1 Mission District, 2 Hayes Valley, 3 North Beach, 4 SoMa, 5 Castro,
// 6 Noe Valley, 7 Richmond District, 8 Marina District — city: San Francisco
// =============================================================================

db = db.getSiblingDB('nestwise');

// ---------------------------------------------------------------------------
// listings — Airbnb-style stays, embedded reviews, ~2-3 per neighborhood
// ---------------------------------------------------------------------------
db.listings.deleteMany({});
db.listings.insertMany([
  { neighborhood_id: 1, title: "Sunny 1BR near Dolores Park", price_per_night: 145,
    amenities: ["wifi", "kitchen", "washer", "pet friendly"],
    reviews: [
      { author: "J. Rivera", rating: 5, text: "Great location, steps from the park.", date: "2026-05-02" },
      { author: "S. Okafor", rating: 4, text: "A bit noisy at night but worth it.", date: "2026-06-14" }
    ], avg_rating: 4.5, created_at: "2026-01-10T00:00:00Z" },
  { neighborhood_id: 1, title: "Mission Muralist Loft", price_per_night: 189,
    amenities: ["wifi", "workspace", "air conditioning"],
    reviews: [
      { author: "T. Nguyen", rating: 5, text: "Incredible art on every wall.", date: "2026-04-20" }
    ], avg_rating: 5.0, created_at: "2026-02-01T00:00:00Z" },
  { neighborhood_id: 2, title: "Hayes Valley Boutique Studio", price_per_night: 165,
    amenities: ["wifi", "kitchen", "gym access"],
    reviews: [
      { author: "M. Alvarez", rating: 4, text: "Perfect for walking to shops.", date: "2026-03-11" },
      { author: "R. Kim", rating: 4, text: "Small but well designed.", date: "2026-05-29" }
    ], avg_rating: 4.0, created_at: "2026-01-15T00:00:00Z" },
  { neighborhood_id: 2, title: "Modern Hayes Valley 2BR", price_per_night: 240,
    amenities: ["wifi", "kitchen", "washer", "parking"],
    reviews: [
      { author: "D. Costa", rating: 5, text: "Spotless and stylish.", date: "2026-06-02" }
    ], avg_rating: 5.0, created_at: "2026-02-20T00:00:00Z" },
  { neighborhood_id: 3, title: "North Beach Jazz Age Flat", price_per_night: 175,
    amenities: ["wifi", "kitchen", "balcony"],
    reviews: [
      { author: "P. Romano", rating: 4, text: "Loved the Italian bakeries nearby.", date: "2026-04-08" }
    ], avg_rating: 4.0, created_at: "2026-01-25T00:00:00Z" },
  { neighborhood_id: 3, title: "Cozy Coit Tower View", price_per_night: 210,
    amenities: ["wifi", "view", "kitchen"],
    reviews: [
      { author: "L. Fischer", rating: 5, text: "The view alone is worth it.", date: "2026-05-19" },
      { author: "A. Haddad", rating: 4, text: "Steep walk up but amazing.", date: "2026-06-30" }
    ], avg_rating: 4.5, created_at: "2026-02-14T00:00:00Z" },
  { neighborhood_id: 4, title: "SoMa Highrise 1BR", price_per_night: 220,
    amenities: ["wifi", "gym access", "workspace", "air conditioning"],
    reviews: [
      { author: "K. Suarez", rating: 4, text: "Great for a work trip.", date: "2026-03-02" }
    ], avg_rating: 4.0, created_at: "2026-01-05T00:00:00Z" },
  { neighborhood_id: 4, title: "Ballpark District Condo", price_per_night: 199,
    amenities: ["wifi", "kitchen", "parking"],
    reviews: [
      { author: "E. Park", rating: 3, text: "Fine, a bit loud on game nights.", date: "2026-04-27" },
      { author: "N. Osei", rating: 4, text: "Walkable to everything downtown.", date: "2026-06-08" }
    ], avg_rating: 3.5, created_at: "2026-02-11T00:00:00Z" },
  { neighborhood_id: 5, title: "Castro Rainbow Row Flat", price_per_night: 155,
    amenities: ["wifi", "kitchen", "pet friendly"],
    reviews: [
      { author: "V. Marchetti", rating: 5, text: "Amazing neighborhood energy.", date: "2026-05-15" }
    ], avg_rating: 5.0, created_at: "2026-01-19T00:00:00Z" },
  { neighborhood_id: 5, title: "Castro Theatre-Adjacent Studio", price_per_night: 139,
    amenities: ["wifi", "workspace"],
    reviews: [
      { author: "B. Tran", rating: 4, text: "Great walk score, close to everything.", date: "2026-06-21" }
    ], avg_rating: 4.0, created_at: "2026-02-28T00:00:00Z" },
  { neighborhood_id: 6, title: "Noe Valley Sunny Garden Unit", price_per_night: 168,
    amenities: ["wifi", "kitchen", "garden", "pet friendly"],
    reviews: [
      { author: "C. Delgado", rating: 5, text: "So peaceful, felt like home.", date: "2026-04-03" },
      { author: "I. Solberg", rating: 5, text: "Best sun in the city, literally.", date: "2026-06-17" }
    ], avg_rating: 5.0, created_at: "2026-01-30T00:00:00Z" },
  { neighborhood_id: 6, title: "24th Street Craftsman Room", price_per_night: 110,
    amenities: ["wifi", "shared kitchen"],
    reviews: [
      { author: "F. Novak", rating: 4, text: "Great value for the neighborhood.", date: "2026-05-09" }
    ], avg_rating: 4.0, created_at: "2026-02-06T00:00:00Z" },
  { neighborhood_id: 7, title: "Richmond Fog Chaser Cottage", price_per_night: 132,
    amenities: ["wifi", "kitchen", "parking"],
    reviews: [
      { author: "G. Petrov", rating: 4, text: "Quiet and close to Golden Gate Park.", date: "2026-03-22" }
    ], avg_rating: 4.0, created_at: "2026-01-12T00:00:00Z" },
  { neighborhood_id: 7, title: "Clement Street Family Flat", price_per_night: 178,
    amenities: ["wifi", "kitchen", "washer", "pet friendly"],
    reviews: [
      { author: "H. Yamamoto", rating: 5, text: "Best dumplings a block away.", date: "2026-05-25" },
      { author: "Q. Ibrahim", rating: 4, text: "Comfortable and spacious.", date: "2026-06-28" }
    ], avg_rating: 4.5, created_at: "2026-02-17T00:00:00Z" },
  { neighborhood_id: 8, title: "Marina Waterfront View 1BR", price_per_night: 265,
    amenities: ["wifi", "view", "gym access", "parking"],
    reviews: [
      { author: "O. Bennett", rating: 5, text: "Sunset views over the bay were unreal.", date: "2026-04-14" }
    ], avg_rating: 5.0, created_at: "2026-01-22T00:00:00Z" },
  { neighborhood_id: 8, title: "Marina Brunch District Studio", price_per_night: 190,
    amenities: ["wifi", "kitchen", "air conditioning"],
    reviews: [
      { author: "W. Larsen", rating: 4, text: "So close to all the good brunch spots.", date: "2026-06-05" }
    ], avg_rating: 4.0, created_at: "2026-02-25T00:00:00Z" }
]);

// ---------------------------------------------------------------------------
// mflix_movies — sample mflix-style "currently popular" movies
// ---------------------------------------------------------------------------
db.mflix_movies.deleteMany({});
db.mflix_movies.insertMany([
  { title: "Midnight in the Garden", genres: ["Drama", "Mystery"], year: 2025, runtime: 118,
    cast: ["A. Chen", "M. Okonkwo"], neighborhood_ids: [1, 4], popularity_score: 82 },
  { title: "Fog Over the Bay", genres: ["Thriller"], year: 2026, runtime: 104,
    cast: ["L. Fischer", "D. Costa"], neighborhood_ids: [7, 8], popularity_score: 76 },
  { title: "The Last Streetcar", genres: ["Drama", "Romance"], year: 2025, runtime: 132,
    cast: ["R. Kim", "P. Romano"], neighborhood_ids: [3, 5], popularity_score: 90 },
  { title: "North Beach Nights", genres: ["Comedy"], year: 2026, runtime: 97,
    cast: ["T. Nguyen"], neighborhood_ids: [3], popularity_score: 68 },
  { title: "Castro Marquee", genres: ["Documentary"], year: 2025, runtime: 88,
    cast: ["V. Marchetti"], neighborhood_ids: [5], popularity_score: 71 },
  { title: "SoMa Skyline", genres: ["Action", "Sci-Fi"], year: 2026, runtime: 141,
    cast: ["K. Suarez", "E. Park"], neighborhood_ids: [4], popularity_score: 95 },
  { title: "Park Bench Chronicles", genres: ["Drama"], year: 2024, runtime: 110,
    cast: ["C. Delgado"], neighborhood_ids: [6, 1], popularity_score: 58 },
  { title: "Golden Gate Getaway", genres: ["Family", "Adventure"], year: 2026, runtime: 101,
    cast: ["H. Yamamoto", "G. Petrov"], neighborhood_ids: [7], popularity_score: 84 },
  { title: "Waterfront Heist", genres: ["Action", "Crime"], year: 2025, runtime: 122,
    cast: ["O. Bennett", "W. Larsen"], neighborhood_ids: [8, 4], popularity_score: 88 },
  { title: "Hayes Street Serenade", genres: ["Musical", "Romance"], year: 2026, runtime: 109,
    cast: ["M. Alvarez", "R. Kim"], neighborhood_ids: [2], popularity_score: 73 },
  { title: "Noe Valley Sunlight", genres: ["Drama"], year: 2024, runtime: 96,
    cast: ["I. Solberg"], neighborhood_ids: [6], popularity_score: 61 },
  { title: "The Interconnect", genres: ["Sci-Fi", "Thriller"], year: 2026, runtime: 128,
    cast: ["N. Osei", "B. Tran"], neighborhood_ids: [4, 5], popularity_score: 92 }
]);

// ---------------------------------------------------------------------------
// weather_snapshots — a "today" and a "yesterday" observation per
// neighborhood, so the Weather Context page can show a trend, plus the
// current-city summary is derived by the proxy from the latest per
// neighborhood (see proxy/routes/weather.js).
// ---------------------------------------------------------------------------
db.weather_snapshots.deleteMany({});
db.weather_snapshots.insertMany([
  { city: "San Francisco", neighborhood_id: 1, observed_at: "2026-08-20T09:00:00Z", temp_f: 66, conditions: "Partly cloudy", weather_score: 7.5 },
  { city: "San Francisco", neighborhood_id: 1, observed_at: "2026-08-19T09:00:00Z", temp_f: 63, conditions: "Overcast", weather_score: 6.8 },
  { city: "San Francisco", neighborhood_id: 2, observed_at: "2026-08-20T09:00:00Z", temp_f: 65, conditions: "Sunny", weather_score: 8.0 },
  { city: "San Francisco", neighborhood_id: 2, observed_at: "2026-08-19T09:00:00Z", temp_f: 62, conditions: "Partly cloudy", weather_score: 7.2 },
  { city: "San Francisco", neighborhood_id: 3, observed_at: "2026-08-20T09:00:00Z", temp_f: 61, conditions: "Fog, clearing by noon", weather_score: 6.5 },
  { city: "San Francisco", neighborhood_id: 3, observed_at: "2026-08-19T09:00:00Z", temp_f: 59, conditions: "Fog", weather_score: 5.9 },
  { city: "San Francisco", neighborhood_id: 4, observed_at: "2026-08-20T09:00:00Z", temp_f: 68, conditions: "Sunny", weather_score: 8.3 },
  { city: "San Francisco", neighborhood_id: 4, observed_at: "2026-08-19T09:00:00Z", temp_f: 67, conditions: "Sunny", weather_score: 8.1 },
  { city: "San Francisco", neighborhood_id: 5, observed_at: "2026-08-20T09:00:00Z", temp_f: 69, conditions: "Clear", weather_score: 8.6 },
  { city: "San Francisco", neighborhood_id: 5, observed_at: "2026-08-19T09:00:00Z", temp_f: 68, conditions: "Sunny", weather_score: 8.4 },
  { city: "San Francisco", neighborhood_id: 6, observed_at: "2026-08-20T09:00:00Z", temp_f: 70, conditions: "Sunny, light breeze", weather_score: 8.9 },
  { city: "San Francisco", neighborhood_id: 6, observed_at: "2026-08-19T09:00:00Z", temp_f: 71, conditions: "Sunny", weather_score: 9.0 },
  { city: "San Francisco", neighborhood_id: 7, observed_at: "2026-08-20T09:00:00Z", temp_f: 58, conditions: "Foggy, cool", weather_score: 5.4 },
  { city: "San Francisco", neighborhood_id: 7, observed_at: "2026-08-19T09:00:00Z", temp_f: 57, conditions: "Fog, drizzle", weather_score: 4.9 },
  { city: "San Francisco", neighborhood_id: 8, observed_at: "2026-08-20T09:00:00Z", temp_f: 64, conditions: "Breezy, clear", weather_score: 7.3 },
  { city: "San Francisco", neighborhood_id: 8, observed_at: "2026-08-19T09:00:00Z", temp_f: 63, conditions: "Windy", weather_score: 6.7 }
]);

print("NestWise MongoDB seed data loaded: " +
      db.listings.countDocuments({}) + " listings, " +
      db.mflix_movies.countDocuments({}) + " movies, " +
      db.weather_snapshots.countDocuments({}) + " weather snapshots.");
