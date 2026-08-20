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
const MONGO_DB_NAME = process.env.NESTWISE_MONGO_DB || 'nestwise';
const SEED_FILE = path.join(__dirname, '..', '..', 'db', 'mongodb', 'seed_data.js');

router.post('/reload', (req, res) => {
    const token = req.header('X-Nestwise-Admin-Token');
    if (token !== ADMIN_TOKEN) {
        return res.status(401).json({ error: 'unauthorized' });
    }

    exec(`mongosh ${MONGO_DB_NAME} "${SEED_FILE}"`, (err, stdout, stderr) => {
        if (err) {
            console.error('[nestwise-proxy] mongo reload failed:', stderr);
            return res.status(500).json({ error: 'mongo reload failed', detail: stderr });
        }
        res.json({ status: 'ok', message: 'MongoDB seed data reloaded', output: stdout.trim() });
    });
});

module.exports = router;
