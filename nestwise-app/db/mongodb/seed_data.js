// =============================================================================
// NestWise — seed_data.js
// Load with: mongosh nestwise db/mongodb/seed_data.js
// Idempotent (deleteMany before insertMany) — safe to re-run, and this is
// exactly what proxy/routes/admin.js calls for the "Reload Seed Data" button.
//
// neighborhood_id values below match a FRESH Oracle install's IDENTITY
// sequence (1-28, see db/mongodb/schema_notes.md) — Washington, D.C.:
//  1 Georgetown              8 Navy Yard/Capitol Riverfront  15 Brookland            22 Glover Park
//  2 Capitol Hill            9 Foggy Bottom                  16 H Street NE/Atlas    23 Tenleytown
//  3 Dupont Circle           10 Penn Quarter/Chinatown        17 Anacostia            24 Friendship Heights
//  4 Adams Morgan            11 Mount Pleasant                18 SW Waterfront/Wharf  25 Congress Heights
//  5 Columbia Heights        12 Cleveland Park                19 NoMa                 26 Deanwood
//  6 U Street/Shaw           13 Woodley Park                  20 Bloomingdale         27 Barracks Row
//  7 Logan Circle            14 Petworth                      21 LeDroit Park         28 West End
// city: Washington
// =============================================================================

db = db.getSiblingDB('nestwise');

// ---------------------------------------------------------------------------
// listings — Airbnb-style stays, embedded reviews, 2 per neighborhood (56)
// ---------------------------------------------------------------------------
db.listings.deleteMany({});
db.listings.insertMany([
  // 1 Georgetown
  { neighborhood_id: 1, title: "Canal-View Rowhouse Suite", price_per_night: 235,
    amenities: ["wifi", "kitchen", "air conditioning"],
    reviews: [{ author: "J. Rivera", rating: 5, text: "Steps from the C&O Canal, loved the brick charm.", date: "2026-05-02" }],
    avg_rating: 4.6, created_at: "2026-01-10T00:00:00Z" },
  { neighborhood_id: 1, title: "M Street Boutique Loft", price_per_night: 210,
    amenities: ["wifi", "workspace", "gym access"],
    reviews: [{ author: "S. Okafor", rating: 4, text: "Perfect base for exploring the shops.", date: "2026-06-14" }],
    avg_rating: 4.3, created_at: "2026-02-01T00:00:00Z" },

  // 2 Capitol Hill
  { neighborhood_id: 2, title: "Eastern Market Rowhouse", price_per_night: 189,
    amenities: ["wifi", "kitchen", "pet friendly"],
    reviews: [{ author: "M. Alvarez", rating: 5, text: "Walked to the market every morning.", date: "2026-03-11" }],
    avg_rating: 4.5, created_at: "2026-01-15T00:00:00Z" },
  { neighborhood_id: 2, title: "Capitol Dome View Studio", price_per_night: 245,
    amenities: ["wifi", "view", "workspace"],
    reviews: [{ author: "R. Kim", rating: 5, text: "Fell asleep looking at the dome lit up.", date: "2026-05-29" }],
    avg_rating: 4.7, created_at: "2026-02-20T00:00:00Z" },

  // 3 Dupont Circle
  { neighborhood_id: 3, title: "Embassy Row Brownstone", price_per_night: 199,
    amenities: ["wifi", "kitchen", "balcony"],
    reviews: [{ author: "D. Costa", rating: 4, text: "Great people-watching on the circle.", date: "2026-06-02" }],
    avg_rating: 4.4, created_at: "2026-01-25T00:00:00Z" },
  { neighborhood_id: 3, title: "Dupont Bookstore Nook", price_per_night: 155,
    amenities: ["wifi", "shared kitchen"],
    reviews: [{ author: "P. Romano", rating: 4, text: "Cozy and quiet, loved Kramerbooks nearby.", date: "2026-04-08" }],
    avg_rating: 4.2, created_at: "2026-02-14T00:00:00Z" },

  // 4 Adams Morgan
  { neighborhood_id: 4, title: "18th Street Nightlife Flat", price_per_night: 165,
    amenities: ["wifi", "kitchen", "air conditioning"],
    reviews: [{ author: "L. Fischer", rating: 4, text: "Loud at night but so much fun.", date: "2026-05-19" }],
    avg_rating: 4.0, created_at: "2026-01-05T00:00:00Z" },
  { neighborhood_id: 4, title: "Adams Morgan Garden Studio", price_per_night: 178,
    amenities: ["wifi", "garden", "pet friendly"],
    reviews: [{ author: "A. Haddad", rating: 5, text: "Quiet garden oasis close to the action.", date: "2026-06-30" }],
    avg_rating: 4.5, created_at: "2026-02-11T00:00:00Z" },

  // 5 Columbia Heights
  { neighborhood_id: 5, title: "14th Street Modern 1BR", price_per_night: 172,
    amenities: ["wifi", "kitchen", "workspace"],
    reviews: [{ author: "K. Suarez", rating: 4, text: "Easy metro access, loved the food scene.", date: "2026-03-02" }],
    avg_rating: 4.3, created_at: "2026-01-19T00:00:00Z" },
  { neighborhood_id: 5, title: "DC USA Highrise Studio", price_per_night: 158,
    amenities: ["wifi", "gym access", "air conditioning"],
    reviews: [{ author: "E. Park", rating: 4, text: "Solid value, close to everything.", date: "2026-04-27" }],
    avg_rating: 4.1, created_at: "2026-02-28T00:00:00Z" },

  // 6 U Street / Shaw
  { neighborhood_id: 6, title: "Jazz Corridor Loft", price_per_night: 210,
    amenities: ["wifi", "kitchen", "workspace"],
    reviews: [{ author: "N. Osei", rating: 5, text: "History on every corner, incredible food.", date: "2026-06-08" }],
    avg_rating: 4.6, created_at: "2026-01-30T00:00:00Z" },
  { neighborhood_id: 6, title: "Shaw Rowhouse Retreat", price_per_night: 195,
    amenities: ["wifi", "washer", "pet friendly"],
    reviews: [{ author: "V. Marchetti", rating: 4, text: "Beautiful renovation, great host.", date: "2026-05-15" }],
    avg_rating: 4.4, created_at: "2026-02-06T00:00:00Z" },

  // 7 Logan Circle
  { neighborhood_id: 7, title: "Victorian Logan Circle Suite", price_per_night: 220,
    amenities: ["wifi", "kitchen", "air conditioning"],
    reviews: [{ author: "B. Tran", rating: 5, text: "Gorgeous architecture, walkable to 14th St.", date: "2026-06-21" }],
    avg_rating: 4.5, created_at: "2026-01-12T00:00:00Z" },
  { neighborhood_id: 7, title: "Logan Circle Rooftop Studio", price_per_night: 205,
    amenities: ["wifi", "view", "workspace"],
    reviews: [{ author: "C. Delgado", rating: 5, text: "Rooftop access made the trip.", date: "2026-04-03" }],
    avg_rating: 4.6, created_at: "2026-02-17T00:00:00Z" },

  // 8 Navy Yard / Capitol Riverfront
  { neighborhood_id: 8, title: "Ballpark View Condo", price_per_night: 230,
    amenities: ["wifi", "gym access", "parking"],
    reviews: [{ author: "I. Solberg", rating: 4, text: "Walked to every Nationals game.", date: "2026-06-17" }],
    avg_rating: 4.3, created_at: "2026-01-22T00:00:00Z" },
  { neighborhood_id: 8, title: "Riverfront Loft", price_per_night: 199,
    amenities: ["wifi", "kitchen", "balcony"],
    reviews: [{ author: "F. Novak", rating: 4, text: "Loved the waterfront boardwalk.", date: "2026-05-09" }],
    avg_rating: 4.2, created_at: "2026-02-25T00:00:00Z" },

  // 9 Foggy Bottom
  { neighborhood_id: 9, title: "GWU Campus Studio", price_per_night: 165,
    amenities: ["wifi", "workspace", "air conditioning"],
    reviews: [{ author: "G. Petrov", rating: 4, text: "Perfect for a Kennedy Center weekend.", date: "2026-03-22" }],
    avg_rating: 4.1, created_at: "2026-01-12T00:00:00Z" },
  { neighborhood_id: 9, title: "State Department District Flat", price_per_night: 189,
    amenities: ["wifi", "kitchen", "gym access"],
    reviews: [{ author: "H. Yamamoto", rating: 4, text: "Quiet, professional area, easy commute.", date: "2026-05-25" }],
    avg_rating: 4.3, created_at: "2026-02-17T00:00:00Z" },

  // 10 Penn Quarter / Chinatown
  { neighborhood_id: 10, title: "Capital One Arena View Loft", price_per_night: 240,
    amenities: ["wifi", "kitchen", "air conditioning"],
    reviews: [{ author: "Q. Ibrahim", rating: 5, text: "Walked to a Caps game, incredible location.", date: "2026-06-28" }],
    avg_rating: 4.5, created_at: "2026-01-30T00:00:00Z" },
  { neighborhood_id: 10, title: "Chinatown Arch Studio", price_per_night: 175,
    amenities: ["wifi", "workspace"],
    reviews: [{ author: "O. Bennett", rating: 4, text: "Right in the middle of everything downtown.", date: "2026-04-14" }],
    avg_rating: 4.2, created_at: "2026-02-06T00:00:00Z" },

  // 11 Mount Pleasant
  { neighborhood_id: 11, title: "Mount Pleasant Street Rowhouse", price_per_night: 168,
    amenities: ["wifi", "kitchen", "garden"],
    reviews: [{ author: "W. Larsen", rating: 4, text: "Loved the Latin American food nearby.", date: "2026-06-05" }],
    avg_rating: 4.4, created_at: "2026-01-22T00:00:00Z" },
  { neighborhood_id: 11, title: "Leafy Mount Pleasant Studio", price_per_night: 145,
    amenities: ["wifi", "shared kitchen"],
    reviews: [{ author: "T. Nguyen", rating: 4, text: "Quiet, tree-lined, felt like a real neighborhood.", date: "2026-05-01" }],
    avg_rating: 4.3, created_at: "2026-02-09T00:00:00Z" },

  // 12 Cleveland Park
  { neighborhood_id: 12, title: "Zoo-Adjacent Craftsman", price_per_night: 195,
    amenities: ["wifi", "kitchen", "pet friendly"],
    reviews: [{ author: "J. Rivera", rating: 5, text: "Woke up to the lions roaring, unforgettable.", date: "2026-03-15" }],
    avg_rating: 4.5, created_at: "2026-01-08T00:00:00Z" },
  { neighborhood_id: 12, title: "Cathedral View Studio", price_per_night: 178,
    amenities: ["wifi", "view", "workspace"],
    reviews: [{ author: "S. Okafor", rating: 4, text: "Stunning views of the National Cathedral.", date: "2026-04-22" }],
    avg_rating: 4.4, created_at: "2026-02-18T00:00:00Z" },

  // 13 Woodley Park
  { neighborhood_id: 13, title: "Rock Creek Park Retreat", price_per_night: 182,
    amenities: ["wifi", "kitchen", "balcony"],
    reviews: [{ author: "M. Alvarez", rating: 4, text: "Trails right outside the door.", date: "2026-05-11" }],
    avg_rating: 4.3, created_at: "2026-01-27T00:00:00Z" },
  { neighborhood_id: 13, title: "Woodley Park Metro Studio", price_per_night: 155,
    amenities: ["wifi", "workspace"],
    reviews: [{ author: "R. Kim", rating: 4, text: "So easy to get anywhere from here.", date: "2026-06-19" }],
    avg_rating: 4.1, created_at: "2026-02-03T00:00:00Z" },

  // 14 Petworth
  { neighborhood_id: 14, title: "Georgia Avenue Rowhouse", price_per_night: 158,
    amenities: ["wifi", "kitchen", "garden"],
    reviews: [{ author: "D. Costa", rating: 4, text: "Up and coming area, great coffee nearby.", date: "2026-03-30" }],
    avg_rating: 4.2, created_at: "2026-01-14T00:00:00Z" },
  { neighborhood_id: 14, title: "Petworth Family Flat", price_per_night: 172,
    amenities: ["wifi", "washer", "pet friendly"],
    reviews: [{ author: "P. Romano", rating: 4, text: "Spacious and quiet, loved the porch.", date: "2026-05-23" }],
    avg_rating: 4.3, created_at: "2026-02-12T00:00:00Z" },

  // 15 Brookland
  { neighborhood_id: 15, title: "Basilica View Studio", price_per_night: 149,
    amenities: ["wifi", "kitchen"],
    reviews: [{ author: "L. Fischer", rating: 4, text: "Peaceful, close to Catholic University.", date: "2026-04-06" }],
    avg_rating: 4.0, created_at: "2026-01-20T00:00:00Z" },
  { neighborhood_id: 15, title: "Brookland Arts Walk Loft", price_per_night: 165,
    amenities: ["wifi", "workspace", "air conditioning"],
    reviews: [{ author: "A. Haddad", rating: 4, text: "Great little arts scene nearby.", date: "2026-06-01" }],
    avg_rating: 4.2, created_at: "2026-02-24T00:00:00Z" },

  // 16 H Street NE / Atlas District
  { neighborhood_id: 16, title: "Atlas District Streetcar Loft", price_per_night: 175,
    amenities: ["wifi", "kitchen", "workspace"],
    reviews: [{ author: "K. Suarez", rating: 4, text: "H Street nightlife right outside.", date: "2026-03-19" }],
    avg_rating: 4.4, created_at: "2026-01-16T00:00:00Z" },
  { neighborhood_id: 16, title: "H Street Rowhouse Suite", price_per_night: 190,
    amenities: ["wifi", "washer", "air conditioning"],
    reviews: [{ author: "E. Park", rating: 4, text: "Loved the food hall down the block.", date: "2026-05-07" }],
    avg_rating: 4.3, created_at: "2026-02-21T00:00:00Z" },

  // 17 Anacostia
  { neighborhood_id: 17, title: "Riverside Anacostia Flat", price_per_night: 135,
    amenities: ["wifi", "kitchen"],
    reviews: [{ author: "N. Osei", rating: 4, text: "Great value, quiet, close to the river trail.", date: "2026-04-11" }],
    avg_rating: 4.0, created_at: "2026-01-24T00:00:00Z" },
  { neighborhood_id: 17, title: "Anacostia Community Studio", price_per_night: 128,
    amenities: ["wifi", "shared kitchen"],
    reviews: [{ author: "V. Marchetti", rating: 4, text: "Warm hosts, real neighborhood feel.", date: "2026-06-13" }],
    avg_rating: 4.1, created_at: "2026-02-08T00:00:00Z" },

  // 18 Southwest Waterfront / The Wharf
  { neighborhood_id: 18, title: "Wharf Pier View Condo", price_per_night: 260,
    amenities: ["wifi", "view", "gym access"],
    reviews: [{ author: "B. Tran", rating: 5, text: "Watched the boats come in every night.", date: "2026-05-17" }],
    avg_rating: 4.7, created_at: "2026-01-11T00:00:00Z" },
  { neighborhood_id: 18, title: "Waterfront Concert Venue Studio", price_per_night: 215,
    amenities: ["wifi", "kitchen", "workspace"],
    reviews: [{ author: "C. Delgado", rating: 5, text: "Steps from every concert at The Anthem.", date: "2026-06-24" }],
    avg_rating: 4.5, created_at: "2026-02-15T00:00:00Z" },

  // 19 NoMa
  { neighborhood_id: 19, title: "Union Market Loft", price_per_night: 205,
    amenities: ["wifi", "kitchen", "air conditioning"],
    reviews: [{ author: "I. Solberg", rating: 4, text: "Food hall right around the corner.", date: "2026-03-28" }],
    avg_rating: 4.4, created_at: "2026-01-18T00:00:00Z" },
  { neighborhood_id: 19, title: "NoMa Highrise Studio", price_per_night: 189,
    amenities: ["wifi", "gym access", "workspace"],
    reviews: [{ author: "F. Novak", rating: 4, text: "New building, super clean, easy metro.", date: "2026-05-04" }],
    avg_rating: 4.2, created_at: "2026-02-19T00:00:00Z" },

  // 20 Bloomingdale
  { neighborhood_id: 20, title: "Victorian Bloomingdale Rowhouse", price_per_night: 172,
    amenities: ["wifi", "kitchen", "garden"],
    reviews: [{ author: "G. Petrov", rating: 4, text: "Community garden made it feel like home.", date: "2026-04-25" }],
    avg_rating: 4.3, created_at: "2026-01-13T00:00:00Z" },
  { neighborhood_id: 20, title: "Bloomingdale Garden Suite", price_per_night: 158,
    amenities: ["wifi", "washer"],
    reviews: [{ author: "H. Yamamoto", rating: 4, text: "Quiet block, walkable to Big Bear Cafe.", date: "2026-06-09" }],
    avg_rating: 4.1, created_at: "2026-02-22T00:00:00Z" },

  // 21 LeDroit Park
  { neighborhood_id: 21, title: "Howard University Row Flat", price_per_night: 149,
    amenities: ["wifi", "kitchen", "workspace"],
    reviews: [{ author: "Q. Ibrahim", rating: 4, text: "Historic charm, close to campus.", date: "2026-03-08" }],
    avg_rating: 4.2, created_at: "2026-01-28T00:00:00Z" },
  { neighborhood_id: 21, title: "LeDroit Park Studio", price_per_night: 138,
    amenities: ["wifi", "shared kitchen"],
    reviews: [{ author: "O. Bennett", rating: 4, text: "Cozy, affordable, great host.", date: "2026-05-14" }],
    avg_rating: 4.0, created_at: "2026-02-04T00:00:00Z" },

  // 22 Glover Park
  { neighborhood_id: 22, title: "Glover-Archbold Trailhead Flat", price_per_night: 168,
    amenities: ["wifi", "kitchen", "pet friendly"],
    reviews: [{ author: "W. Larsen", rating: 4, text: "Loved the trail access right outside.", date: "2026-04-17" }],
    avg_rating: 4.3, created_at: "2026-01-21T00:00:00Z" },
  { neighborhood_id: 22, title: "Glover Park Rowhouse", price_per_night: 175,
    amenities: ["wifi", "washer", "air conditioning"],
    reviews: [{ author: "T. Nguyen", rating: 4, text: "Quiet residential feel, close to Georgetown.", date: "2026-06-11" }],
    avg_rating: 4.2, created_at: "2026-02-27T00:00:00Z" },

  // 23 Tenleytown
  { neighborhood_id: 23, title: "American University Studio", price_per_night: 155,
    amenities: ["wifi", "workspace", "air conditioning"],
    reviews: [{ author: "J. Rivera", rating: 4, text: "Easy metro, quiet campus vibe.", date: "2026-03-25" }],
    avg_rating: 4.1, created_at: "2026-01-17T00:00:00Z" },
  { neighborhood_id: 23, title: "Tenleytown Family Flat", price_per_night: 172,
    amenities: ["wifi", "kitchen", "washer"],
    reviews: [{ author: "S. Okafor", rating: 4, text: "Spacious, great for a longer stay.", date: "2026-05-20" }],
    avg_rating: 4.3, created_at: "2026-02-10T00:00:00Z" },

  // 24 Friendship Heights
  { neighborhood_id: 24, title: "Friendship Heights Shopping District Suite", price_per_night: 189,
    amenities: ["wifi", "gym access", "parking"],
    reviews: [{ author: "M. Alvarez", rating: 4, text: "Right by the mall, super convenient.", date: "2026-04-09" }],
    avg_rating: 4.2, created_at: "2026-01-26T00:00:00Z" },
  { neighborhood_id: 24, title: "Maryland Border Studio", price_per_night: 165,
    amenities: ["wifi", "kitchen"],
    reviews: [{ author: "R. Kim", rating: 4, text: "Quiet, upscale, easy access both directions.", date: "2026-06-15" }],
    avg_rating: 4.1, created_at: "2026-02-05T00:00:00Z" },

  // 25 Congress Heights
  { neighborhood_id: 25, title: "Southeast DC Community Flat", price_per_night: 118,
    amenities: ["wifi", "kitchen"],
    reviews: [{ author: "D. Costa", rating: 4, text: "Affordable, friendly neighbors, real DC.", date: "2026-03-13" }],
    avg_rating: 3.9, created_at: "2026-01-09T00:00:00Z" },
  { neighborhood_id: 25, title: "Congress Heights Studio", price_per_night: 108,
    amenities: ["wifi", "shared kitchen"],
    reviews: [{ author: "P. Romano", rating: 4, text: "Basic but clean and well-priced.", date: "2026-05-06" }],
    avg_rating: 3.8, created_at: "2026-02-16T00:00:00Z" },

  // 26 Deanwood
  { neighborhood_id: 26, title: "Far Northeast Quiet Retreat", price_per_night: 112,
    amenities: ["wifi", "kitchen"],
    reviews: [{ author: "L. Fischer", rating: 4, text: "Peaceful, off the beaten path.", date: "2026-04-19" }],
    avg_rating: 3.9, created_at: "2026-01-23T00:00:00Z" },
  { neighborhood_id: 26, title: "Deanwood Rowhouse Room", price_per_night: 99,
    amenities: ["wifi", "shared kitchen"],
    reviews: [{ author: "A. Haddad", rating: 4, text: "Great value for a quiet stay.", date: "2026-06-20" }],
    avg_rating: 3.8, created_at: "2026-02-13T00:00:00Z" },

  // 27 Barracks Row
  { neighborhood_id: 27, title: "8th Street Marine Barracks View", price_per_night: 195,
    amenities: ["wifi", "kitchen", "balcony"],
    reviews: [{ author: "K. Suarez", rating: 5, text: "Watched the Evening Parade from the porch.", date: "2026-03-17" }],
    avg_rating: 4.5, created_at: "2026-01-29T00:00:00Z" },
  { neighborhood_id: 27, title: "Barracks Row Historic Suite", price_per_night: 178,
    amenities: ["wifi", "workspace", "air conditioning"],
    reviews: [{ author: "E. Park", rating: 4, text: "Loved the restaurant row right outside.", date: "2026-05-27" }],
    avg_rating: 4.4, created_at: "2026-02-23T00:00:00Z" },

  // 28 West End
  { neighborhood_id: 28, title: "West End Hotel-Style Suite", price_per_night: 225,
    amenities: ["wifi", "gym access", "air conditioning"],
    reviews: [{ author: "N. Osei", rating: 4, text: "Felt like a boutique hotel, great location.", date: "2026-04-24" }],
    avg_rating: 4.4, created_at: "2026-01-31T00:00:00Z" },
  { neighborhood_id: 28, title: "Foggy Bottom Border Loft", price_per_night: 205,
    amenities: ["wifi", "kitchen", "workspace"],
    reviews: [{ author: "V. Marchetti", rating: 4, text: "Perfectly between Georgetown and downtown.", date: "2026-06-26" }],
    avg_rating: 4.3, created_at: "2026-02-07T00:00:00Z" }
]);

// ---------------------------------------------------------------------------
// mflix_movies — "currently popular" movies. Deliberately only reference the
// 8 neighborhoods that actually have a theater (see db/oracle/03_packages.sql
// theaters list), so "movies playing near this neighborhood" is a real,
// answerable question rather than a random assignment.
// ---------------------------------------------------------------------------
db.mflix_movies.deleteMany({});
db.mflix_movies.insertMany([
  { title: "Cherry Blossom Conspiracy", genres: ["Drama", "Thriller"], year: 2026, runtime: 124,
    cast: ["A. Reyes", "M. Chen"], neighborhood_ids: [10], popularity_score: 88 },
  { title: "The Georgetown Affair", genres: ["Romance", "Drama"], year: 2025, runtime: 108,
    cast: ["L. Whitfield"], neighborhood_ids: [1], popularity_score: 74 },
  { title: "Union Station Heist", genres: ["Action", "Crime"], year: 2026, runtime: 132,
    cast: ["D. Osei", "R. Park"], neighborhood_ids: [19], popularity_score: 91 },
  { title: "Howard Street Symphony", genres: ["Musical", "Drama"], year: 2025, runtime: 115,
    cast: ["J. Baptiste"], neighborhood_ids: [6], popularity_score: 79 },
  { title: "The Wharf", genres: ["Documentary"], year: 2026, runtime: 96,
    cast: [], neighborhood_ids: [18], popularity_score: 68 },
  { title: "Nationals Park Nights", genres: ["Sports", "Comedy"], year: 2025, runtime: 101,
    cast: ["K. Ibarra"], neighborhood_ids: [10, 19], popularity_score: 82 },
  { title: "Bryant Street Bytes", genres: ["Sci-Fi"], year: 2026, runtime: 119,
    cast: ["T. Nakamura"], neighborhood_ids: [19], popularity_score: 85 },
  { title: "Suns Over Mount Pleasant", genres: ["Drama"], year: 2024, runtime: 103,
    cast: ["C. Delgado"], neighborhood_ids: [11], popularity_score: 63 },
  { title: "Marine Barracks", genres: ["War", "Drama"], year: 2025, runtime: 128,
    cast: ["S. Alvarado"], neighborhood_ids: [27], popularity_score: 77 },
  { title: "Chevy Chase Circle", genres: ["Comedy"], year: 2026, runtime: 99,
    cast: ["F. Grant"], neighborhood_ids: [24], popularity_score: 66 },
  { title: "Chinatown Arch Mystery", genres: ["Mystery"], year: 2025, runtime: 111,
    cast: ["W. Zhou", "P. Adeyemi"], neighborhood_ids: [10], popularity_score: 89 },
  { title: "The Interconnect: District Line", genres: ["Sci-Fi", "Thriller"], year: 2026, runtime: 136,
    cast: ["N. Osei", "B. Tran"], neighborhood_ids: [10, 19], popularity_score: 94 },
  { title: "IMAX: Capital Skies", genres: ["Documentary"], year: 2026, runtime: 45,
    cast: [], neighborhood_ids: [18], popularity_score: 72 }
]);

// ---------------------------------------------------------------------------
// weather_snapshots — a "today" and a "yesterday" observation per
// neighborhood, plus three generated older days appended below (28 x 5 = 140),
// plus the current-city summary is derived by the proxy from the latest per
// neighborhood (see proxy/routes/weather.js). D.C. in August: hot, humid,
// prone to afternoon thunderstorms — varied here rather than uniform.
// ---------------------------------------------------------------------------
db.weather_snapshots.deleteMany({});
db.weather_snapshots.insertMany([
  { city: "Washington", neighborhood_id: 1,  observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 6.2 },
  { city: "Washington", neighborhood_id: 1,  observed_at: "2026-08-19T09:00:00Z", temp_f: 90, conditions: "Hot and humid", weather_score: 5.5 },
  { city: "Washington", neighborhood_id: 2,  observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.3 },
  { city: "Washington", neighborhood_id: 2,  observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Hot and humid", weather_score: 5.6 },
  { city: "Washington", neighborhood_id: 3,  observed_at: "2026-08-20T09:00:00Z", temp_f: 86, conditions: "Sunny", weather_score: 6.8 },
  { city: "Washington", neighborhood_id: 3,  observed_at: "2026-08-19T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 6.1 },
  { city: "Washington", neighborhood_id: 4,  observed_at: "2026-08-20T09:00:00Z", temp_f: 89, conditions: "Thunderstorms possible", weather_score: 5.3 },
  { city: "Washington", neighborhood_id: 4,  observed_at: "2026-08-19T09:00:00Z", temp_f: 91, conditions: "Hot and humid", weather_score: 5.0 },
  { city: "Washington", neighborhood_id: 5,  observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Humid with a breeze", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 5,  observed_at: "2026-08-19T09:00:00Z", temp_f: 90, conditions: "Hot and humid", weather_score: 5.4 },
  { city: "Washington", neighborhood_id: 6,  observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Overcast, muggy", weather_score: 6.1 },
  { city: "Washington", neighborhood_id: 6,  observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Hazy sunshine", weather_score: 5.8 },
  { city: "Washington", neighborhood_id: 7,  observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Sunny and steamy", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 7,  observed_at: "2026-08-19T09:00:00Z", temp_f: 90, conditions: "Hot and humid", weather_score: 5.4 },
  { city: "Washington", neighborhood_id: 8,  observed_at: "2026-08-20T09:00:00Z", temp_f: 86, conditions: "Breezy along the river", weather_score: 6.9 },
  { city: "Washington", neighborhood_id: 8,  observed_at: "2026-08-19T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.4 },
  { city: "Washington", neighborhood_id: 9,  observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Hazy sunshine", weather_score: 6.2 },
  { city: "Washington", neighborhood_id: 9,  observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Hot and humid", weather_score: 5.6 },
  { city: "Washington", neighborhood_id: 10, observed_at: "2026-08-20T09:00:00Z", temp_f: 89, conditions: "Urban heat, sunny", weather_score: 5.8 },
  { city: "Washington", neighborhood_id: 10, observed_at: "2026-08-19T09:00:00Z", temp_f: 91, conditions: "Hot and humid", weather_score: 5.1 },
  { city: "Washington", neighborhood_id: 11, observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.3 },
  { city: "Washington", neighborhood_id: 11, observed_at: "2026-08-19T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 12, observed_at: "2026-08-20T09:00:00Z", temp_f: 85, conditions: "Clear, warm evening", weather_score: 7.2 },
  { city: "Washington", neighborhood_id: 12, observed_at: "2026-08-19T09:00:00Z", temp_f: 86, conditions: "Partly cloudy, humid", weather_score: 6.6 },
  { city: "Washington", neighborhood_id: 13, observed_at: "2026-08-20T09:00:00Z", temp_f: 85, conditions: "Clear, warm evening", weather_score: 7.1 },
  { city: "Washington", neighborhood_id: 13, observed_at: "2026-08-19T09:00:00Z", temp_f: 87, conditions: "Hazy sunshine", weather_score: 6.4 },
  { city: "Washington", neighborhood_id: 14, observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Humid with a breeze", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 14, observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Hot and humid", weather_score: 5.5 },
  { city: "Washington", neighborhood_id: 15, observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.3 },
  { city: "Washington", neighborhood_id: 15, observed_at: "2026-08-19T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 6.1 },
  { city: "Washington", neighborhood_id: 16, observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Sunny and steamy", weather_score: 5.9 },
  { city: "Washington", neighborhood_id: 16, observed_at: "2026-08-19T09:00:00Z", temp_f: 90, conditions: "Hot and humid", weather_score: 5.3 },
  { city: "Washington", neighborhood_id: 17, observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Breezy along the river", weather_score: 6.5 },
  { city: "Washington", neighborhood_id: 17, observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Partly cloudy, humid", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 18, observed_at: "2026-08-20T09:00:00Z", temp_f: 85, conditions: "Breezy along the waterfront", weather_score: 7.4 },
  { city: "Washington", neighborhood_id: 18, observed_at: "2026-08-19T09:00:00Z", temp_f: 86, conditions: "Partly cloudy, humid", weather_score: 6.7 },
  { city: "Washington", neighborhood_id: 19, observed_at: "2026-08-20T09:00:00Z", temp_f: 89, conditions: "Urban heat, sunny", weather_score: 5.7 },
  { city: "Washington", neighborhood_id: 19, observed_at: "2026-08-19T09:00:00Z", temp_f: 90, conditions: "Hot and humid", weather_score: 5.2 },
  { city: "Washington", neighborhood_id: 20, observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.3 },
  { city: "Washington", neighborhood_id: 20, observed_at: "2026-08-19T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 21, observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Overcast, muggy", weather_score: 6.1 },
  { city: "Washington", neighborhood_id: 21, observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Hot and humid", weather_score: 5.5 },
  { city: "Washington", neighborhood_id: 22, observed_at: "2026-08-20T09:00:00Z", temp_f: 85, conditions: "Clear, warm evening", weather_score: 7.0 },
  { city: "Washington", neighborhood_id: 22, observed_at: "2026-08-19T09:00:00Z", temp_f: 86, conditions: "Partly cloudy, humid", weather_score: 6.5 },
  { city: "Washington", neighborhood_id: 23, observed_at: "2026-08-20T09:00:00Z", temp_f: 85, conditions: "Clear, warm evening", weather_score: 7.1 },
  { city: "Washington", neighborhood_id: 23, observed_at: "2026-08-19T09:00:00Z", temp_f: 87, conditions: "Hazy sunshine", weather_score: 6.4 },
  { city: "Washington", neighborhood_id: 24, observed_at: "2026-08-20T09:00:00Z", temp_f: 84, conditions: "Clear, warm evening", weather_score: 7.3 },
  { city: "Washington", neighborhood_id: 24, observed_at: "2026-08-19T09:00:00Z", temp_f: 86, conditions: "Partly cloudy, humid", weather_score: 6.6 },
  { city: "Washington", neighborhood_id: 25, observed_at: "2026-08-20T09:00:00Z", temp_f: 89, conditions: "Hot and humid", weather_score: 5.4 },
  { city: "Washington", neighborhood_id: 25, observed_at: "2026-08-19T09:00:00Z", temp_f: 91, conditions: "Thunderstorms possible", weather_score: 5.0 },
  { city: "Washington", neighborhood_id: 26, observed_at: "2026-08-20T09:00:00Z", temp_f: 88, conditions: "Humid with a breeze", weather_score: 5.9 },
  { city: "Washington", neighborhood_id: 26, observed_at: "2026-08-19T09:00:00Z", temp_f: 89, conditions: "Hot and humid", weather_score: 5.5 },
  { city: "Washington", neighborhood_id: 27, observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.3 },
  { city: "Washington", neighborhood_id: 27, observed_at: "2026-08-19T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 6.0 },
  { city: "Washington", neighborhood_id: 28, observed_at: "2026-08-20T09:00:00Z", temp_f: 87, conditions: "Partly cloudy, humid", weather_score: 6.2 },
  { city: "Washington", neighborhood_id: 28, observed_at: "2026-08-19T09:00:00Z", temp_f: 88, conditions: "Hazy sunshine", weather_score: 5.9 }
]);

// Three older observations per neighborhood (Aug 16-18), bringing each
// neighborhood to five. The proxy's /api/weather/neighborhood/:id already does
// .limit(5); with only the two hand-written days above, the Weather Context
// trend chart had two points, which reads as broken rather than sparse.
//
// Generated rather than hand-authored: 84 near-identical weather readings is
// not something to write out by hand, and for a trend chart the *shape* is what
// matters, not whether any individual reading is meteorologically defensible.
// The two most recent days (above) stay hand-written because those are the ones
// surfaced as "current" on the Dashboard and Neighborhood Detail, where the
// exact wording of `conditions` is visible on screen.
//
// Deterministic — same values on every reload, so a demo looks identical each
// time and the Admin reload button stays idempotent.
const wxConditions = ["Hot and humid", "Hazy sunshine", "Partly cloudy, humid",
                      "Thunderstorms possible", "Humid with a breeze"];
const wxOlder = [];
for (let n = 1; n <= 28; n++) {
    for (let d = 0; d < 3; d++) {
        const day   = 18 - d;            // Aug 18, 17, 16
        const drift = [1, 2, 0][d];      // midweek ran slightly hotter
        wxOlder.push({
            city:            "Washington",
            neighborhood_id: n,
            observed_at:     `2026-08-${day}T09:00:00Z`,
            temp_f:          84 + ((n + d) % 6) + drift,
            conditions:      wxConditions[(n + d) % wxConditions.length],
            weather_score:   Math.round((7.2 - ((n + d) % 5) * 0.3 - drift * 0.2) * 10) / 10
        });
    }
}
db.weather_snapshots.insertMany(wxOlder);

// ---------------------------------------------------------------------------
// venues — bars, lounges, live music, comedy, breweries, rooftops
//
// This collection is the clearest justification for MongoDB in the whole app:
// every venue shares a small common core (name, neighborhood_id, venue_type,
// description) and then carries attributes that only make sense for its own
// type. A live music room has music_genres and a cover charge; a brewery has a
// tap count and whether it brews on site; a rooftop has a view and whether it's
// seasonal. Modelling that relationally means either a wide sparse table of
// mostly-NULL columns or an EAV side table — neither of which is better than
// just storing the fields each document actually needs.
//
// Weighted toward D.C.'s real nightlife corridors (Adams Morgan, U Street/Shaw,
// H Street, Dupont) rather than spread evenly, so filtering by neighborhood
// produces realistic variation — some neighborhoods have several venues, some
// have none. That is honest seed data, not a gap.
// ---------------------------------------------------------------------------
db.venues.deleteMany({});
db.venues.insertMany([
  // 3 Dupont Circle
  { neighborhood_id: 3, name: "Eighteenth Street Lounge", venue_type: "lounge",
    description: "Multi-room lounge in a converted mansion, long-running DJ nights.",
    cover_charge: 15, dress_code: "smart casual", outdoor_seating: true },
  { neighborhood_id: 3, name: "Bar Charley", venue_type: "bar",
    description: "Neighborhood cocktail bar known for tiki mugs and a deep punch list.",
    happy_hour: "4-7pm weekdays", outdoor_seating: false, food_served: true },

  // 4 Adams Morgan
  { neighborhood_id: 4, name: "Madam's Organ", venue_type: "live_music",
    description: "Four floors of blues, a rooftop deck, and a mural you can see from blocks away.",
    cover_charge: 10, music_genres: ["blues", "soul", "bluegrass"], live_nights: ["Wed","Thu","Fri","Sat"] },
  { neighborhood_id: 4, name: "Songbyrd Music House", venue_type: "live_music",
    description: "Basement venue and record shop upstairs.",
    cover_charge: 18, music_genres: ["indie", "hip hop", "electronic"], live_nights: ["Thu","Fri","Sat"], all_ages_shows: true },
  { neighborhood_id: 4, name: "Jack Rose Dining Saloon", venue_type: "bar",
    description: "Whisky library with over 2,000 bottles and a terraced patio.",
    happy_hour: "5-7pm", outdoor_seating: true, food_served: true, specialty: "whisky" },

  // 6 U Street / Shaw
  { neighborhood_id: 6, name: "Nine:Thirty Club", venue_type: "live_music",
    description: "The city's defining mid-size music venue since 1980.",
    cover_charge: 35, music_genres: ["rock", "indie", "hip hop", "electronic"], live_nights: ["Tue","Wed","Thu","Fri","Sat","Sun"], capacity: 1200 },
  { neighborhood_id: 6, name: "Right Proper Brewing", venue_type: "brewery",
    description: "Brewpub in a former pool hall where Duke Ellington played.",
    on_site_brewing: true, taps_count: 14, food_served: true, outdoor_seating: true },
  { neighborhood_id: 6, name: "Marvin", venue_type: "rooftop",
    description: "Rooftop beer garden above a Belgian-Southern kitchen.",
    view: "U Street corridor", seasonal: false, heated: true, cover_charge: 0 },

  // 7 Logan Circle
  { neighborhood_id: 7, name: "Churchkey", venue_type: "bar",
    description: "Fifty-five taps and five cask ales up a flight of stairs.",
    happy_hour: "4-7pm weekdays", taps_count: 55, food_served: true, outdoor_seating: false },

  // 8 Navy Yard / Capitol Riverfront
  { neighborhood_id: 8, name: "Bluejacket", venue_type: "brewery",
    description: "Production brewery and tasting hall in a former shipyard building.",
    on_site_brewing: true, taps_count: 20, food_served: true, tours_offered: true },

  // 10 Penn Quarter / Chinatown
  { neighborhood_id: 10, name: "Capitol Comedy Cellar", venue_type: "comedy",
    description: "Basement room with two shows most nights and a two-drink minimum.",
    cover_charge: 25, show_nights: ["Thu","Fri","Sat"], minimum_purchase: "2 drinks", age_policy: "21+" },
  { neighborhood_id: 10, name: "Quill", venue_type: "lounge",
    description: "Quiet hotel bar with a pianist and a long list of rye cocktails.",
    cover_charge: 0, dress_code: "business casual", live_nights: ["Thu","Fri","Sat"] },

  // 16 H Street NE / Atlas District
  { neighborhood_id: 16, name: "Rock & Roll Hotel", venue_type: "live_music",
    description: "Two floors — bands downstairs, rooftop bar upstairs.",
    cover_charge: 20, music_genres: ["punk", "indie", "metal"], live_nights: ["Wed","Thu","Fri","Sat"] },
  { neighborhood_id: 16, name: "Little Miss Whiskey's", venue_type: "bar",
    description: "Dark, loud, and famous for a back patio that stays open late.",
    happy_hour: "5-8pm", outdoor_seating: true, food_served: false, age_policy: "21+" },
  { neighborhood_id: 16, name: "Atlas Comedy Room", venue_type: "comedy",
    description: "Open mics midweek, touring headliners on weekends.",
    cover_charge: 15, show_nights: ["Tue","Fri","Sat"], open_mic: true, age_policy: "18+" },

  // 18 Southwest Waterfront / The Wharf
  { neighborhood_id: 18, name: "The Anthem", venue_type: "live_music",
    description: "Waterfront hall with a movable floor and a 6,000-person capacity.",
    cover_charge: 55, music_genres: ["rock", "pop", "hip hop"], live_nights: ["Thu","Fri","Sat"], capacity: 6000 },
  { neighborhood_id: 18, name: "Pearl Street Warehouse", venue_type: "live_music",
    description: "Small room with a diner attached and a strong Americana booking.",
    cover_charge: 22, music_genres: ["americana", "folk", "country"], live_nights: ["Wed","Thu","Fri","Sat"], food_served: true },
  { neighborhood_id: 18, name: "Whiskey Charlie", venue_type: "rooftop",
    description: "Top-floor bar looking straight down the Washington Channel.",
    view: "Washington Channel", seasonal: false, heated: true, dress_code: "smart casual" },

  // 19 NoMa
  { neighborhood_id: 19, name: "Wunder Garten", venue_type: "bar",
    description: "Open-air beer garden with rotating food trucks and a big screen for matches.",
    outdoor_seating: true, seasonal: true, food_trucks: true, dog_friendly: true },

  // 1 Georgetown
  { neighborhood_id: 1, name: "Blues Alley", venue_type: "live_music",
    description: "The country's oldest continuously operating jazz supper club.",
    cover_charge: 40, music_genres: ["jazz"], live_nights: ["Tue","Wed","Thu","Fri","Sat","Sun"], food_served: true, seated_show: true },
  { neighborhood_id: 1, name: "Tombs", venue_type: "bar",
    description: "Below-street tavern that has served students since 1962.",
    happy_hour: "4-7pm weekdays", food_served: true, outdoor_seating: false },

  // 27 Barracks Row
  { neighborhood_id: 27, name: "Eighth Street Tavern", venue_type: "bar",
    description: "Corner tavern with a jukebox and a short, well-kept beer list.",
    happy_hour: "4-6pm", outdoor_seating: true, food_served: true },

  // 5 Columbia Heights
  { neighborhood_id: 5, name: "Wonderland Ballroom", venue_type: "bar",
    description: "Two floors, a patio, and DJ nights upstairs on weekends.",
    happy_hour: "5-8pm", outdoor_seating: true, live_nights: ["Fri","Sat"], food_served: true },

  // 11 Mount Pleasant
  { neighborhood_id: 11, name: "Raven Grill", venue_type: "bar",
    description: "Cash-only dive that has not changed in decades, and that is the point.",
    cash_only: true, food_served: false, outdoor_seating: false, age_policy: "21+" },

  // 13 Woodley Park
  { neighborhood_id: 13, name: "Open City Rooftop", venue_type: "rooftop",
    description: "Casual terrace above a diner, best in shoulder season.",
    view: "Connecticut Avenue", seasonal: true, heated: false, food_served: true },

  // 20 Bloomingdale
  { neighborhood_id: 20, name: "Boundary Stone", venue_type: "bar",
    description: "Corner pub with a strong whiskey list and a quiz night.",
    happy_hour: "5-7pm weekdays", food_served: true, quiz_night: "Tue" },

  // 22 Glover Park
  { neighborhood_id: 22, name: "Breadsoda", venue_type: "bar",
    description: "Sandwiches, shuffleboard, and a bottle list longer than the menu.",
    food_served: true, games: ["shuffleboard", "pool"], outdoor_seating: false },

  // 9 Foggy Bottom
  { neighborhood_id: 9, name: "Founding Farmers Distillery Bar", venue_type: "lounge",
    description: "Cocktail bar attached to the restaurant, house spirits behind the bar.",
    cover_charge: 0, dress_code: "casual", food_served: true, specialty: "house-distilled spirits" }
]);

print("NestWise MongoDB seed data loaded: " +
      db.listings.countDocuments({}) + " listings, " +
      db.mflix_movies.countDocuments({}) + " movies, " +
      db.weather_snapshots.countDocuments({}) + " weather snapshots, " +
      db.venues.countDocuments({}) + " venues.");
