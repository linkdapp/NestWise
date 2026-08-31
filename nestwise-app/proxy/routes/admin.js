// =============================================================================
// NestWise Mongo proxy — routes/admin.js
// The one write endpoint in the proxy, used only by the Admin/Seed Data page.
// Guarded with a shared-secret header (NESTWISE_ADMIN_TOKEN) — the proxy has
// no user login of its own, so this is the minimal guard consistent with
// "admin-only" rather than standing up separate proxy authentication.
//
// Reloads by shelling out to `mongosh` against db/mongodb/seed_data.js —
// the same file used for the initial install — so there is exactly one
// source of truth for what "seed data" means (see db/oracle/99_seed_data.sql
// for the same idea applied to admin_pkg.reload_oracle_seed_data on the
// Oracle side).
// =============================================================================
const express = require('express');
const path = require('path');
const { exec } = require('child_process');
const router = express.Router();

const ADMIN_TOKEN  = process.env.NESTWISE_ADMIN_TOKEN || 'change-me';
// Reuse the same authenticated connection string db.js uses for the app's
// own driver connection -- shelling out to a bare `mongosh <db-name>` (the
// original version of this file) carries no credentials, so it silently
// worked when MongoDB had auth disabled and broke the moment auth was
// enabled ("command delete requires authentication"). NESTWISE_MONGO_URL
// already has the right user/password/authSource baked in (see
// /etc/nestwise-proxy.env), so mongosh just needs to be pointed at it
// directly instead of a bare database name.
const MONGO_URL = process.env.NESTWISE_MONGO_URL || 'mongodb://localhost:27017/nestwise';
const SEED_FILE = path.join(__dirname, '..', '..', 'db', 'mongodb', 'seed_data.js');

router.post('/reload', (req, res) => {
    const token = req.header('X-Nestwise-Admin-Token');
    if (token !== ADMIN_TOKEN) {
        return res.status(401).json({ error: 'unauthorized' });
    }

    exec(`mongosh "${MONGO_URL}" "${SEED_FILE}"`, (err, stdout, stderr) => {
        if (err) {
            console.error('[nestwise-proxy] mongo reload failed:', stderr);
            return res.status(500).json({ error: 'mongo reload failed', detail: stderr });
        }
        res.json({ status: 'ok', message: 'MongoDB seed data reloaded', output: stdout.trim() });
    });
});

module.exports = router;
