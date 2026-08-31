// =============================================================================
// NestWise Mongo proxy — routes/venues.js
// Backs the Entertainment page's nightlife region. Paired with Oracle's
// theaters table and the mflix_movies collection on the same page: Oracle owns
// the fixed-shape venues (a cinema has a name, a screen count, an address),
// MongoDB owns the ones whose attributes vary by what kind of place they are.
// =============================================================================
const express = require('express');
const router = express.Router();
const { connect } = require('../db');

// GET /api/venues?neighborhood_id=4&type=live_music
// neighborhood_id filters to one neighborhood; type optionally narrows to a
// single venue_type. Both optional — with neither, returns everything, which
// is what the Data Profile discovery call in APEX relies on.
router.get('/', async (req, res) => {
    const db = await connect();
    const filter = {};
    if (req.query.neighborhood_id) {
        filter.neighborhood_id = Number(req.query.neighborhood_id);
    }
    if (req.query.type) {
        filter.venue_type = req.query.type;
    }

    // Sorted by venue_type then name so a neighborhood's list groups naturally
    // (all the bars together, all the live music together) without the page
    // needing to do any grouping of its own.
    const venues = await db.collection('venues')
        .find(filter)
        .sort({ venue_type: 1, name: 1 })
        .toArray();

    res.json(venues);
});

// GET /api/venues/types
// Distinct venue_type values, for populating a filter list without hardcoding
// the vocabulary in the page. Deliberately a separate endpoint rather than
// deriving it client-side from a full fetch.
router.get('/types', async (req, res) => {
    const db = await connect();
    const types = await db.collection('venues').distinct('venue_type');
    res.json(types.sort().map(t => ({ venue_type: t })));
});

module.exports = router;
