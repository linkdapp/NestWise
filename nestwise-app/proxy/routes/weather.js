// =============================================================================
// NestWise Mongo proxy — routes/weather.js
// Backs the Weather Context feature and the Dashboard's current-weather tile.
// =============================================================================
const express = require('express');
const router = express.Router();
const { connect } = require('../db');

// GET /api/weather/current?city=San%20Francisco
// Dashboard tile: latest snapshot per neighborhood in the city, averaged
// into one summary the tile can show at a glance.
router.get('/current', async (req, res) => {
    const db = await connect();
    const city = req.query.city || 'San Francisco';

    const latestPerNeighborhood = await db.collection('weather_snapshots')
        .aggregate([
            { $match: { city } },
            { $sort: { observed_at: -1 } },
            { $group: {
                _id: '$neighborhood_id',
                temp_f: { $first: '$temp_f' },
                conditions: { $first: '$conditions' },
                weather_score: { $first: '$weather_score' },
                observed_at: { $first: '$observed_at' }
            } }
        ]).toArray();

    if (latestPerNeighborhood.length === 0) {
        return res.json({ city, avg_temp_f: null, avg_weather_score: null, conditions: 'no data', sample_size: 0 });
    }

    const avgTemp  = latestPerNeighborhood.reduce((s, r) => s + r.temp_f, 0) / latestPerNeighborhood.length;
    const avgScore = latestPerNeighborhood.reduce((s, r) => s + r.weather_score, 0) / latestPerNeighborhood.length;

    res.json({
        city,
        avg_temp_f: Math.round(avgTemp * 10) / 10,
        avg_weather_score: Math.round(avgScore * 10) / 10,
        conditions: latestPerNeighborhood[0].conditions, // representative sample for the tile
        sample_size: latestPerNeighborhood.length,
        observed_at: latestPerNeighborhood[0].observed_at
    });
});

// GET /api/weather/neighborhood/:id
// Weather Context page and Neighborhood Detail: recent snapshots for one
// neighborhood, newest first, so the page can show current + a short trend.
router.get('/neighborhood/:id', async (req, res) => {
    const db = await connect();
    const neighborhoodId = Number(req.params.id);
    const snapshots = await db.collection('weather_snapshots')
        .find({ neighborhood_id: neighborhoodId })
        .sort({ observed_at: -1 })
        .limit(5)
        .toArray();
    res.json(snapshots);
});

module.exports = router;
