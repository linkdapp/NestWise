// =============================================================================
// NestWise Mongo proxy — routes/movies.js
// Backs the Entertainment feature's MongoDB half (paired with Oracle's
// theaters table via theater_pkg.list_by_neighborhood).
// =============================================================================
const express = require('express');
const router = express.Router();
const { connect } = require('../db');

// GET /api/movies/popular?neighborhood_id=42
// If neighborhood_id is supplied, only movies whose neighborhood_ids array
// includes it; otherwise the top popular movies city-wide.
router.get('/popular', async (req, res) => {
    const db = await connect();
    const filter = {};
    if (req.query.neighborhood_id) {
        filter.neighborhood_ids = Number(req.query.neighborhood_id);
    }
    const movies = await db.collection('mflix_movies')
        .find(filter)
        .sort({ popularity_score: -1 })
        .limit(10)
        .toArray();
    res.json(movies);
});

module.exports = router;
