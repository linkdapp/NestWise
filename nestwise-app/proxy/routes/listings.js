// =============================================================================
// NestWise Mongo proxy — routes/listings.js
// Backs the Stay/Listings feature. Three endpoints, each matching one page
// region exactly (see db/mongodb/schema_notes.md "Access from APEX").
// =============================================================================
const express = require('express');
const router = express.Router();
const { connect } = require('../db');

// GET /api/listings?neighborhood_id=42
// Backs the Stay/Listings browse Cards region and the Neighborhood Detail
// page's "listings in this neighborhood" region.
router.get('/', async (req, res) => {
    const db = await connect();
    const filter = {};
    if (req.query.neighborhood_id) {
        filter.neighborhood_id = Number(req.query.neighborhood_id);
    }
    const listings = await db.collection('listings')
        .find(filter)
        .project({ reviews: 0 })          // list view doesn't need full review text
        .sort({ avg_rating: -1 })
        .toArray();
    res.json(listings);
});

// GET /api/listings/:id
// Backs the Stay/Listings detail page — full document incl. embedded reviews.
router.get('/:id', async (req, res) => {
    const db = await connect();
    const { ObjectId } = require('mongodb');
    try {
        const listing = await db.collection('listings').findOne({ _id: new ObjectId(req.params.id) });
        if (!listing) return res.status(404).json({ error: 'listing not found' });
        res.json(listing);
    } catch (e) {
        res.status(400).json({ error: 'invalid listing id' });
    }
});

// GET /api/listings/recommend/for-user?budget=$$&weather=mild
// Backs "Recommend for me" on the Stay/Listings page. Deliberately a simple,
// explainable weighted-sum heuristic — same spirit as restaurant_pkg's
// recommend_for_user in Oracle, not a trained model (see apex/page_plan.md).
//
// Score = avg_rating (0-5) + 3 if price_per_night fits the budget bucket
//                           + 2 if the listing's neighborhood weather_score
//                             matches the weather preference band.
router.get('/recommend/for-user', async (req, res) => {
    const db = await connect();
    const budget = req.query.budget || '$$';
    const weatherPref = req.query.weather || 'any';

    const budgetCeiling = { '$': 120, '$$': 190, '$$$': 260, '$$$$': 100000 }[budget] || 190;

    // Latest weather score per neighborhood, for the weather-fit bonus.
    const weatherByNeighborhood = {};
    const snapshots = await db.collection('weather_snapshots')
        .aggregate([
            { $sort: { observed_at: -1 } },
            { $group: { _id: '$neighborhood_id', weather_score: { $first: '$weather_score' } } }
        ]).toArray();
    snapshots.forEach(s => { weatherByNeighborhood[s._id] = s.weather_score; });

    const weatherBand = (score) => {
        if (score === undefined) return 'any';
        if (score < 5) return 'cold';
        if (score < 7) return 'mild';
        if (score < 8.5) return 'warm';
        return 'hot';
    };

    const listings = await db.collection('listings')
        .find({})
        .project({ reviews: 0 })
        .toArray();

    const scored = listings.map(l => {
        const score = weatherByNeighborhood[l.neighborhood_id];
        const fitsBudget  = l.price_per_night <= budgetCeiling;
        const fitsWeather = weatherPref === 'any' || weatherBand(score) === weatherPref;
        return {
            ...l,
            recommend_score: (l.avg_rating || 0) + (fitsBudget ? 3 : 0) + (fitsWeather ? 2 : 0)
        };
    });

    scored.sort((a, b) => b.recommend_score - a.recommend_score);
    res.json(scored.slice(0, 10));
});

module.exports = router;
