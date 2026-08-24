// =============================================================================
// NestWise Mongo proxy — db.js
// Single shared MongoDB connection. Kept deliberately boring: one client,
// one database handle, exported for the route modules to reuse.
// =============================================================================
const { MongoClient } = require('mongodb');

const MONGO_URL = process.env.NESTWISE_MONGO_URL || 'mongodb://localhost:27017';
const DB_NAME   = process.env.NESTWISE_MONGO_DB  || 'nestwise';

let client;
let db;

async function connect() {
    if (db) return db;
    client = new MongoClient(MONGO_URL);
    await client.connect();
    db = client.db(DB_NAME);
    // Never log MONGO_URL directly — it carries the credential inline
    // (mongodb://user:pass@host/...). Redact the password before printing.
    const redactedUrl = MONGO_URL.replace(/\/\/([^:]+):([^@]+)@/, '//$1:***@');
    console.log(`[nestwise-proxy] connected to MongoDB at ${redactedUrl}, db "${DB_NAME}"`);
    return db;
}

module.exports = { connect };
